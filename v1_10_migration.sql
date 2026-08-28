-- ============================================
-- 二游情报铺 v1.10 迁移
-- 自动解锁机制完善：
--   1. 订单提交时不再自动解锁，兑换码也不立即分配
--   2. 管理员确认订单时自动解锁 + 通过邮箱发送兑换码
--   3. 修复崩坏：星穹铁道角色/武器库GID匹配
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- ===== 1. 重写 shop_submit_order：移除自动解锁和兑换码分配 =====
CREATE OR REPLACE FUNCTION shop_submit_order(p_device TEXT, p_items JSONB, p_group_id INTEGER DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  dc RECORD;
  v_oid INTEGER;
  v_item JSONB;
  v_prod RECORD;
  v_total INTEGER := 0;
  v_lt INTEGER;
  v_dev_count INTEGER;
  v_order_count INTEGER;
  v_group_item_count INTEGER;
  v_gid TEXT;
  v_my_item_count INTEGER := 0;
  v_is_personal_group BOOLEAN := false;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;

  -- 检查拼团组是否已过期或已结束
  IF p_group_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM order_groups
      WHERE id = p_group_id AND (status IN ('ended', 'expired') OR (expires_at IS NOT NULL AND expires_at < now()))
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_ended');
    END IF;

    SELECT count(DISTINCT o.device_code) INTO v_dev_count FROM orders o WHERE o.group_id = p_group_id;
    IF v_dev_count >= 5 THEN
      IF NOT EXISTS (SELECT 1 FROM orders WHERE device_code = p_device AND group_id = p_group_id) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'group_device_limit');
      END IF;
    END IF;
  END IF;

  -- 创建订单（不分配兑换码，不自动解锁）
  INSERT INTO orders (device_code, status, total_price, group_id, is_group_buy)
  VALUES (p_device, 'pending', 0, p_group_id, p_group_id IS NOT NULL)
  RETURNING id INTO v_oid;

  -- 插入订单项（限购检查 + 捆绑优惠）
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_prod FROM products WHERE code = (v_item->>'product_code');
    IF NOT FOUND THEN CONTINUE; END IF;

    v_lt := v_prod.price;
    v_my_item_count := v_my_item_count + 1;

    -- 限购检查
    IF EXISTS (
      SELECT 1 FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      WHERE o.device_code = p_device AND oi.product_code = v_prod.code
    ) THEN
      v_lt := 0;
    END IF;

    INSERT INTO order_items (order_id, product_code, product_name, quantity, unit_price, line_total)
    VALUES (v_oid, v_prod.code, v_prod.name, 1, v_prod.price, v_lt);
    v_total := v_total + v_lt;
  END LOOP;

  -- 重算总价（无捆绑优惠，直接累加）
  SELECT COALESCE(SUM(line_total), 0) INTO v_total FROM order_items WHERE order_id = v_oid;
  UPDATE orders SET total_price = v_total WHERE id = v_oid;

  -- 个人拼团判断
  IF p_group_id IS NULL AND v_my_item_count >= 3 THEN
    v_is_personal_group := true;
    UPDATE orders SET is_group_buy = true WHERE id = v_oid;
  END IF;

  -- 拼团组统计
  IF p_group_id IS NOT NULL THEN
    SELECT count(*) INTO v_order_count FROM orders WHERE group_id = p_group_id;
    SELECT count(DISTINCT p.game_name || '|' || p.ver) INTO v_group_item_count
    FROM order_items oi
    JOIN products p ON oi.product_code = p.code
    JOIN orders o ON oi.order_id = o.id
    WHERE o.group_id = p_group_id AND oi.line_total > 0;

    RETURN jsonb_build_object(
      'ok', true, 'order_id', v_oid, 'total', v_total,
      'group_ready', v_group_item_count >= 3,
      'order_count', v_order_count, 'item_count', v_group_item_count,
      'auto_assigned', false,
      'personal_group', v_is_personal_group
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'order_id', v_oid, 'total', v_total,
    'auto_assigned', false,
    'personal_group', v_is_personal_group
  );
END; $function$;
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;

-- ===== 2. 重写 admin_complete_order：确认时自动分配兑换码 + 解锁 + 发送邮箱 =====
CREATE OR REPLACE FUNCTION admin_complete_order(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_order RECORD;
  v_oi RECORD;
  v_prod RECORD;
  v_avail RECORD;
  v_pwd TEXT;
  v_invoice TEXT := '';
  v_code_text TEXT := '';
  v_code_count INTEGER := 0;
  v_unlocked_gids TEXT[] := '{}';
  v_gid TEXT;
  v_existing_unlock RECORD;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;

  -- 标记订单完成
  UPDATE orders SET status = 'completed', completed_at = now() WHERE id = p_order_id;

  -- 为每个付费商品分配兑换码 + 自动解锁
  FOR v_oi IN SELECT * FROM order_items WHERE order_id = p_order_id AND line_total > 0 LOOP
    SELECT * INTO v_prod FROM products WHERE code = v_oi.product_code;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- 分配兑换码
    SELECT * INTO v_avail FROM redemption_codes
    WHERE used = false AND pool = v_prod.category
    ORDER BY RANDOM() LIMIT 1;

    IF NOT FOUND THEN CONTINUE; END IF;

    v_pwd := derive_password(v_order.device_code, v_prod.code);

    INSERT INTO order_codes (order_id, redemption_code, product_code, password)
    VALUES (p_order_id, v_avail.code, v_prod.code, COALESCE(v_pwd, ''));

    UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = v_order.device_code
    WHERE code = v_avail.code AND used = false;

    -- 记录到 redemptions 表
    INSERT INTO redemptions (device_code, product_code, redemption_code, password)
    VALUES (v_order.device_code, v_prod.code, v_avail.code, COALESCE(v_pwd, ''))
    ON CONFLICT (device_code, product_code) DO NOTHING;

    -- 计算 GID 并自动解锁
    v_gid := v_prod.game_name || '-' || v_prod.ver || '-' ||
      CASE
        WHEN v_prod.category = 'character' THEN
          CASE WHEN v_prod.game_group LIKE 'zzz%' THEN '代理人' ELSE '角色' END
        WHEN v_prod.game_group LIKE 'hsr%' THEN '光锥'
        WHEN v_prod.game_group LIKE 'zzz%' THEN '音擎'
        ELSE '武器'
      END;

    -- 检查是否已解锁
    SELECT * INTO v_existing_unlock FROM unlocks WHERE device_code = v_order.device_code AND gid = v_gid;
    IF NOT FOUND THEN
      INSERT INTO unlocks (device_code, gid, pool, redemption_code)
      VALUES (v_order.device_code, v_gid, v_prod.category, v_avail.code)
      ON CONFLICT (device_code, gid) DO NOTHING;

      INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool)
      VALUES (v_order.device_code, v_prod.code, v_avail.code, v_gid, v_prod.category)
      ON CONFLICT DO NOTHING;

      v_unlocked_gids := array_append(v_unlocked_gids, v_gid);
    END IF;

    v_code_count := v_code_count + 1;
  END LOOP;

  -- 生成发票
  v_invoice := '【二游情报铺 · 电子发票】' || E'\n';
  v_invoice := v_invoice || '订单号: #' || p_order_id || E'\n';
  v_invoice := v_invoice || '设备码: ' || v_order.device_code || E'\n';
  v_invoice := v_invoice || '支付方式: ' || COALESCE(v_order.payment_method, '现金') || E'\n';
  IF v_order.is_group_buy THEN v_invoice := v_invoice || '拼团订单: 是' || E'\n'; END IF;
  v_invoice := v_invoice || E'\n--- 商品明细 ---' || E'\n';

  FOR v_oi IN SELECT oi.product_name, oi.quantity, oi.unit_price, oi.line_total FROM order_items oi WHERE oi.order_id = p_order_id LOOP
    v_invoice := v_invoice || v_oi.product_name || ' ×' || v_oi.quantity;
    IF v_oi.line_total = 0 THEN
      v_invoice := v_invoice || ' (优惠)' || E'\n';
    ELSE
      v_invoice := v_invoice || ' = ' || v_oi.line_total || '元' || E'\n';
    END IF;
  END LOOP;

  v_invoice := v_invoice || E'\n合计: ' || v_order.total_price || '元' || E'\n';
  v_invoice := v_invoice || '完成时间: ' || to_char(now(), 'YYYY-MM-DD HH24:MI') || E'\n';
  v_invoice := v_invoice || E'\n感谢惠顾！';

  -- 发送发票到邮箱
  INSERT INTO inbox (device_code, order_id, type, title, content)
  VALUES (v_order.device_code, p_order_id, 'invoice', '订单 #' || p_order_id || ' 电子发票', v_invoice);

  -- 发送每个兑换码到邮箱（含密码信息）
  FOR v_oi IN SELECT oc.*, p.name as product_name FROM order_codes oc JOIN products p ON p.code = oc.product_code WHERE oc.order_id = p_order_id LOOP
    v_code_text := '商品: ' || v_oi.product_name || E'\n';
    v_code_text := v_code_text || '兑换码: ' || v_oi.redemption_code || E'\n';
    IF v_oi.password IS NOT NULL AND v_oi.password != '' THEN
      v_code_text := v_code_text || '密码: ' || v_oi.password || E'\n';
    END IF;
    v_code_text := v_code_text || E'\n请在「兑换」页面输入兑换码解锁资料库。';
    INSERT INTO inbox (device_code, order_id, type, title, content)
    VALUES (v_order.device_code, p_order_id, 'code', v_oi.product_code || ' 兑换码', v_code_text);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'invoice', v_invoice, 'unlocked_gids', to_jsonb(v_unlocked_gids), 'code_count', v_code_count);
END; $function$;
GRANT EXECUTE ON FUNCTION admin_complete_order(TEXT, INTEGER) TO anon;

-- ===== 3. 修复 check_unlocks 确保 GID 格式一致 =====
CREATE OR REPLACE FUNCTION check_unlocks(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(gid) INTO rows FROM unlocks WHERE device_code = p_device;
  RETURN jsonb_build_object('ok', true, 'unlocked', COALESCE(rows, '[]'::jsonb));
END; $function$;
GRANT EXECUTE ON FUNCTION check_unlocks(TEXT) TO anon;

-- ===== 4. 校准产品价格（角色5/拼团4，武器2/拼团1）=====
UPDATE products SET price = 5, group_price = 4 WHERE category = 'character';
UPDATE products SET price = 2, group_price = 1 WHERE category = 'weapon';
