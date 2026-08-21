-- ============================================
-- 二游情报铺 v1.3 迁移
-- 1. 订单提交自动分配兑换码 + 自动解锁
-- 2. 限购一次（每个商品数量强制为1）
-- 3. 兑换码清理（删除pool为空的已用旧码）
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- ===== 0. 清理兑换码库：删除 pool 为空的已用旧码 =====
DELETE FROM redemption_codes WHERE used = true AND (pool IS NULL OR pool = '');

-- ===== 1. 重写 shop_submit_order：限购1 + 自动分配兑换码 + 自动解锁 =====
DROP FUNCTION IF EXISTS shop_submit_order(TEXT, JSONB, INTEGER);

CREATE OR REPLACE FUNCTION shop_submit_order(p_device TEXT, p_items JSONB, p_group_id INTEGER DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  dc RECORD;
  v_oid INTEGER;
  v_item JSONB;
  v_prod RECORD;
  v_qty INTEGER;
  v_total INTEGER := 0;
  v_lt INTEGER;
  v_dev_count INTEGER;
  v_order_count INTEGER;
  v_avail RECORD;
  v_gid TEXT;
  v_pwd TEXT;
  v_unlocked_gids TEXT[] := '{}';
  v_existing_unlock RECORD;
BEGIN
  -- 验证设备码
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;

  -- 如果加入拼团组，检查设备上限（最多5个不同设备）
  IF p_group_id IS NOT NULL THEN
    SELECT count(DISTINCT o.device_code) INTO v_dev_count FROM orders o WHERE o.group_id = p_group_id;
    IF v_dev_count >= 5 THEN
      IF NOT EXISTS (SELECT 1 FROM orders WHERE device_code = p_device AND group_id = p_group_id) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'group_device_limit');
      END IF;
    END IF;
  END IF;

  -- 创建订单
  INSERT INTO orders (device_code, status, total_price, group_id, is_group_buy)
  VALUES (p_device, 'pending', 0, p_group_id, p_group_id IS NOT NULL)
  RETURNING id INTO v_oid;

  -- 插入订单项（限购：每个商品数量强制为1）
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_prod FROM products WHERE code = (v_item->>'product_code');
    IF NOT FOUND THEN CONTINUE; END IF;

    -- 强制限购1个
    v_qty := 1;
    v_lt := v_prod.price;

    -- 检查是否已购买过该商品
    IF EXISTS (
      SELECT 1 FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      WHERE o.device_code = p_device AND oi.product_code = v_prod.code
    ) THEN
      -- 已购买过，跳过（但仍插入订单，只是不计费）
      v_lt := 0;
    END IF;

    INSERT INTO order_items (order_id, product_code, product_name, quantity, unit_price, line_total)
    VALUES (v_oid, v_prod.code, v_prod.name, 1, v_prod.price, v_lt);
    v_total := v_total + v_lt;

    -- 自动分配兑换码（仅对付费商品）
    IF v_lt > 0 THEN
      SELECT * INTO v_avail FROM redemption_codes
      WHERE used = false AND pool = v_prod.category
      ORDER BY RANDOM() LIMIT 1;

      IF NOT FOUND THEN
        -- 没有可用兑换码，订单仍可提交但标记
        CONTINUE;
      END IF;

      -- 计算密码
      v_pwd := derive_password(p_device, v_prod.code);

      -- 写入分配记录
      INSERT INTO order_codes (order_id, redemption_code, product_code, password)
      VALUES (v_oid, v_avail.code, v_prod.code, COALESCE(v_pwd, ''));

      -- 标记兑换码已用
      UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = p_device
      WHERE code = v_avail.code AND used = false;

      -- 自动解锁对应库
      SELECT * INTO v_existing_unlock FROM unlocks WHERE device_code = p_device AND gid = (
        SELECT game_name || '-' || ver || '-' ||
          CASE
            WHEN category = 'character' THEN '角色'
            WHEN game_group LIKE 'hsr%' THEN '光锥'
            WHEN game_group LIKE 'zzz%' THEN '音擎'
            ELSE '武器'
          END
        FROM products WHERE code = v_prod.code
      );

      IF NOT FOUND THEN
        -- 插入解锁记录
        INSERT INTO unlocks (device_code, gid, pool, redemption_code)
        VALUES (
          p_device,
          (SELECT game_name || '-' || ver || '-' ||
            CASE
              WHEN category = 'character' THEN '角色'
              WHEN game_group LIKE 'hsr%' THEN '光锥'
              WHEN game_group LIKE 'zzz%' THEN '音擎'
              ELSE '武器'
            END
          FROM products WHERE code = v_prod.code),
          v_prod.category,
          v_avail.code
        ) ON CONFLICT (device_code, gid) DO NOTHING;

        -- 插入兑换记录
        INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool)
        VALUES (
          p_device,
          v_prod.code,
          v_avail.code,
          (SELECT game_name || '-' || ver || '-' ||
            CASE
              WHEN category = 'character' THEN '角色'
              WHEN game_group LIKE 'hsr%' THEN '光锥'
              WHEN game_group LIKE 'zzz%' THEN '音擎'
              ELSE '武器'
            END
          FROM products WHERE code = v_prod.code),
          v_prod.category
        ) ON CONFLICT DO NOTHING;

        v_unlocked_gids := array_append(v_unlocked_gids,
          (SELECT game_name || '-' || ver || '-' ||
            CASE
              WHEN category = 'character' THEN '角色'
              WHEN game_group LIKE 'hsr%' THEN '光锥'
              WHEN game_group LIKE 'zzz%' THEN '音擎'
              ELSE '武器'
            END
          FROM products WHERE code = v_prod.code)
        );
      END IF;
    END IF;
  END LOOP;

  -- 更新订单总价
  UPDATE orders SET total_price = v_total WHERE id = v_oid;

  -- 返回结果（包含已解锁的库列表）
  IF p_group_id IS NOT NULL THEN
    SELECT count(*) INTO v_order_count FROM orders WHERE group_id = p_group_id;
    RETURN jsonb_build_object(
      'ok', true, 'order_id', v_oid, 'total', v_total,
      'group_ready', v_order_count >= 3, 'order_count', v_order_count,
      'auto_assigned', true, 'unlocked_gids', to_jsonb(v_unlocked_gids)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'order_id', v_oid, 'total', v_total,
    'auto_assigned', true, 'unlocked_gids', to_jsonb(v_unlocked_gids)
  );
END; $function$;

GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;

-- ===== 2. 修复 admin_auto_assign_and_complete 中的 gid 拼接逻辑 =====
-- 使用 products 表的 game_name, ver, category 来生成 gid，与实际 gid 格式保持一致
CREATE OR REPLACE FUNCTION product_to_gid(p_product_code TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_prod RECORD; v_gid TEXT;
BEGIN
  SELECT * INTO v_prod FROM products WHERE code = p_product_code;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_gid := v_prod.game_name || '-' || v_prod.ver || '-' ||
    CASE
      WHEN v_prod.category = 'character' THEN
        CASE
          WHEN v_prod.game_group LIKE 'zzz%' THEN '代理人'
          ELSE '角色'
        END
      WHEN v_prod.game_group LIKE 'hsr%' THEN '光锥'
      WHEN v_prod.game_group LIKE 'zzz%' THEN '音擎'
      ELSE '武器'
    END;
  RETURN v_gid;
END; $$;
GRANT EXECUTE ON FUNCTION product_to_gid(TEXT) TO anon;

-- ===== 3. 更新 admin_auto_assign_and_complete 使用 product_to_gid =====
CREATE OR REPLACE FUNCTION admin_auto_assign_and_complete(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_order RECORD;
  v_item RECORD;
  v_oc RECORD;
  v_prod RECORD;
  v_invoice TEXT := '';
  v_code_text TEXT := '';
  v_code_count INTEGER;
  v_item_count INTEGER;
  v_gid TEXT;
  v_pool TEXT;
  v_avail RECORD;
  v_pwd TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;
  IF v_order.status = 'completed' THEN RETURN jsonb_build_object('ok', false, 'error', 'already_completed'); END IF;

  -- 检查已分配数量
  SELECT count(*) INTO v_item_count FROM order_items WHERE order_id = p_order_id AND line_total > 0;
  SELECT count(*) INTO v_code_count FROM order_codes WHERE order_id = p_order_id;

  -- 自动为未分配的商品选取可用兑换码
  FOR v_item IN
    SELECT oi.product_code, oi.product_name
    FROM order_items oi
    WHERE oi.order_id = p_order_id AND oi.line_total > 0
    AND NOT EXISTS (SELECT 1 FROM order_codes oc WHERE oc.order_id = p_order_id AND oc.product_code = oi.product_code)
  LOOP
    SELECT category INTO v_pool FROM products WHERE code = v_item.product_code;
    IF v_pool IS NULL THEN v_pool := 'weapon'; END IF;

    SELECT * INTO v_avail FROM redemption_codes WHERE used = false AND pool = v_pool ORDER BY RANDOM() LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'no_available_codes', 'product', v_item.product_name, 'pool', v_pool);
    END IF;

    v_pwd := derive_password(v_order.device_code, v_item.product_code);
    DELETE FROM order_codes WHERE order_id = p_order_id AND product_code = v_item.product_code;
    INSERT INTO order_codes (order_id, redemption_code, product_code, password)
    VALUES (p_order_id, v_avail.code, v_item.product_code, COALESCE(v_pwd, ''));
  END LOOP;

  -- 重新检查
  SELECT count(*) INTO v_code_count FROM order_codes WHERE order_id = p_order_id;
  IF v_code_count < v_item_count THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_all_codes_assigned', 'needed', v_item_count, 'assigned', v_code_count);
  END IF;

  -- 标记订单完成
  UPDATE orders SET status = 'completed', completed_at = now() WHERE id = p_order_id;

  -- 处理兑换码和解锁
  FOR v_oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    -- 标记兑换码已用（如果尚未标记）
    UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = v_order.device_code, product_code = v_oc.product_code
    WHERE code = v_oc.redemption_code AND used = false;

    -- 获取 gid
    v_gid := product_to_gid(v_oc.product_code);

    -- 插入兑换记录
    INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool)
    VALUES (v_order.device_code, v_oc.product_code, v_oc.redemption_code, COALESCE(v_gid, ''),
      (SELECT category FROM products WHERE code = v_oc.product_code))
    ON CONFLICT DO NOTHING;

    -- 自动解锁
    IF v_gid IS NOT NULL THEN
      INSERT INTO unlocks (device_code, gid, pool, redemption_code)
      VALUES (v_order.device_code, v_gid,
        (SELECT category FROM products WHERE code = v_oc.product_code),
        v_oc.redemption_code)
      ON CONFLICT (device_code, gid) DO NOTHING;
    END IF;
  END LOOP;

  -- 生成发票
  v_invoice := '【二游情报铺 · 电子发票】' || E'\n';
  v_invoice := v_invoice || '订单号: #' || p_order_id || E'\n';
  v_invoice := v_invoice || '设备码: ' || v_order.device_code || E'\n';
  v_invoice := v_invoice || '支付方式: ' || COALESCE(v_order.payment_method, '现金') || E'\n';
  IF v_order.is_group_buy THEN v_invoice := v_invoice || '拼团订单: 是' || E'\n'; END IF;
  v_invoice := v_invoice || E'\n--- 商品明细 ---' || E'\n';

  FOR v_oc IN SELECT oi.product_name, oi.quantity, oi.unit_price, oi.line_total FROM order_items oi WHERE oi.order_id = p_order_id LOOP
    v_invoice := v_invoice || v_oc.product_name || ' ×' || v_oc.quantity;
    IF v_oc.line_total = 0 THEN
      v_invoice := v_invoice || ' (已购/免费)' || E'\n';
    ELSE
      v_invoice := v_invoice || ' = ' || v_oc.line_total || '元' || E'\n';
    END IF;
  END LOOP;

  v_invoice := v_invoice || E'\n合计: ' || v_order.total_price || '元' || E'\n';
  v_invoice := v_invoice || '完成时间: ' || to_char(now(), 'YYYY-MM-DD HH24:MI') || E'\n';
  v_invoice := v_invoice || E'\n感谢惠顾！';

  INSERT INTO inbox (device_code, order_id, type, title, content)
  VALUES (v_order.device_code, p_order_id, 'invoice', '订单 #' || p_order_id || ' 电子发票', v_invoice);

  FOR v_oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    v_code_text := '商品: ' || (SELECT name FROM products WHERE code = v_oc.product_code) || E'\n';
    v_code_text := v_code_text || '兑换码: ' || v_oc.redemption_code || E'\n';
    IF v_oc.password IS NOT NULL AND v_oc.password != '' THEN
      v_code_text := v_code_text || '密码: ' || v_oc.password || E'\n';
    END IF;
    INSERT INTO inbox (device_code, order_id, type, title, content)
    VALUES (v_order.device_code, p_order_id, 'code', v_oc.product_code || ' 兑换码', v_code_text)
    ON CONFLICT DO NOTHING;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'invoice', v_invoice, 'auto_assigned', true);
END; $function$;
GRANT EXECUTE ON FUNCTION admin_auto_assign_and_complete(TEXT, INTEGER) TO anon;
