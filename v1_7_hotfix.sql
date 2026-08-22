-- ============================================
-- 二游情报铺 v1.7.1 热修复
-- 修复自动解锁 GID 不匹配问题（中文冒号未去掉）
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- ===== 1. 修复已有错误 unlocks 记录 =====
UPDATE unlocks SET gid = REPLACE(gid, '：', '') WHERE gid LIKE '%：%';

-- ===== 2. 修复 product_to_gid 函数（确保去掉冒号） =====
CREATE OR REPLACE FUNCTION product_to_gid(p_product_code TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_prod RECORD; v_gid TEXT;
BEGIN
  SELECT * INTO v_prod FROM products WHERE code = p_product_code;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_gid := REPLACE(v_prod.game_name, '：', '') || '-' || v_prod.ver || '-' ||
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

-- ===== 3. 重写 shop_submit_order：使用 product_to_gid 统一格式 =====
DROP FUNCTION IF EXISTS shop_submit_order(TEXT, JSONB, INTEGER);

CREATE OR REPLACE FUNCTION shop_submit_order(p_device TEXT, p_items JSONB, p_group_id INTEGER DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
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
  v_avail RECORD;
  v_gid TEXT;
  v_pwd TEXT;
  v_unlocked_gids TEXT[] := '{}';
  v_existing_unlock RECORD;
  v_my_item_count INTEGER := 0;
  v_is_personal_group BOOLEAN := false;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;

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

  INSERT INTO orders (device_code, status, total_price, group_id, is_group_buy)
  VALUES (p_device, 'pending', 0, p_group_id, p_group_id IS NOT NULL)
  RETURNING id INTO v_oid;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_prod FROM products WHERE code = (v_item->>'product_code');
    IF NOT FOUND THEN CONTINUE; END IF;
    v_lt := v_prod.price;
    v_my_item_count := v_my_item_count + 1;
    IF EXISTS (SELECT 1 FROM order_items oi JOIN orders o ON o.id = oi.order_id WHERE o.device_code = p_device AND oi.product_code = v_prod.code) THEN
      v_lt := 0;
    END IF;
    INSERT INTO order_items (order_id, product_code, product_name, quantity, unit_price, line_total)
    VALUES (v_oid, v_prod.code, v_prod.name, 1, v_prod.price, v_lt);
    v_total := v_total + v_lt;

    IF v_lt > 0 THEN
      SELECT * INTO v_avail FROM redemption_codes WHERE used = false AND pool = v_prod.category ORDER BY RANDOM() LIMIT 1;
      IF NOT FOUND THEN CONTINUE; END IF;
      v_pwd := derive_password(p_device, v_prod.code);
      INSERT INTO order_codes (order_id, redemption_code, product_code, password)
      VALUES (v_oid, v_avail.code, v_prod.code, COALESCE(v_pwd, ''));
      UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = p_device
      WHERE code = v_avail.code AND used = false;

      -- 使用 product_to_gid 统一生成 GID（自动去掉中文冒号）
      v_gid := product_to_gid(v_prod.code);

      SELECT * INTO v_existing_unlock FROM unlocks WHERE device_code = p_device AND gid = v_gid;
      IF NOT FOUND AND v_gid IS NOT NULL THEN
        INSERT INTO unlocks (device_code, gid, pool, redemption_code)
        VALUES (p_device, v_gid, v_prod.category, v_avail.code)
        ON CONFLICT (device_code, gid) DO NOTHING;

        INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool)
        VALUES (p_device, v_prod.code, v_avail.code, v_gid, v_prod.category)
        ON CONFLICT DO NOTHING;

        v_unlocked_gids := array_append(v_unlocked_gids, v_gid);
      END IF;
    END IF;
  END LOOP;

  -- 捆绑优惠
  UPDATE order_items SET line_total = 0, unit_price = 0
  WHERE order_id = v_oid
  AND product_code IN (
    SELECT code FROM products p2 WHERE p2.category = 'weapon'
    AND EXISTS (
      SELECT 1 FROM order_items oi2 JOIN products p3 ON oi2.product_code = p3.code
      WHERE oi2.order_id = v_oid AND p3.category = 'character' AND p3.game_group = p2.game_group AND oi2.line_total > 0
    )
  ) AND line_total > 0;

  SELECT COALESCE(SUM(line_total), 0) INTO v_total FROM order_items WHERE order_id = v_oid;
  UPDATE orders SET total_price = v_total WHERE id = v_oid;

  IF p_group_id IS NULL AND v_my_item_count >= 3 THEN
    v_is_personal_group := true;
    UPDATE orders SET is_group_buy = true WHERE id = v_oid;
  END IF;

  IF p_group_id IS NOT NULL THEN
    SELECT count(*) INTO v_order_count FROM orders WHERE group_id = p_group_id;
    SELECT count(DISTINCT p.game_name || '|' || p.ver) INTO v_group_item_count
    FROM order_items oi JOIN products p ON oi.product_code = p.code JOIN orders o ON oi.order_id = o.id
    WHERE o.group_id = p_group_id AND oi.line_total > 0;
    RETURN jsonb_build_object('ok', true, 'order_id', v_oid, 'total', v_total,
      'group_ready', v_group_item_count >= 3, 'order_count', v_order_count,
      'item_count', v_group_item_count, 'auto_assigned', true,
      'unlocked_gids', to_jsonb(v_unlocked_gids), 'personal_group', v_is_personal_group);
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_oid, 'total', v_total,
    'auto_assigned', true, 'unlocked_gids', to_jsonb(v_unlocked_gids),
    'personal_group', v_is_personal_group);
END; $$;
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;

-- ===== 4. 同步修复 admin_auto_assign_and_complete 也使用 product_to_gid =====
CREATE OR REPLACE FUNCTION admin_auto_assign_and_complete(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
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
  v_gg TEXT;
  v_has_char BOOLEAN;
  v_has_wpn BOOLEAN;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;
  IF v_order.status = 'completed' THEN RETURN jsonb_build_object('ok', false, 'error', 'already_completed'); END IF;

  -- 捆绑优惠
  FOR v_gg IN SELECT DISTINCT p.game_group FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = p_order_id LOOP
    SELECT EXISTS(SELECT 1 FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = p_order_id AND p.game_group = v_gg AND p.category = 'character') INTO v_has_char;
    SELECT EXISTS(SELECT 1 FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = p_order_id AND p.game_group = v_gg AND p.category = 'weapon') INTO v_has_wpn;
    IF v_has_char AND v_has_wpn THEN
      UPDATE order_items SET line_total = 0, unit_price = 0
      WHERE order_id = p_order_id AND product_code IN (SELECT code FROM products WHERE game_group = v_gg AND category = 'weapon');
    END IF;
  END LOOP;
  UPDATE orders SET total_price = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id) WHERE id = p_order_id;
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;

  SELECT count(*) INTO v_item_count FROM order_items WHERE order_id = p_order_id AND line_total > 0;
  SELECT count(*) INTO v_code_count FROM order_codes WHERE order_id = p_order_id;

  FOR v_item IN
    SELECT oi.product_code, oi.product_name FROM order_items oi
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

  SELECT count(*) INTO v_code_count FROM order_codes WHERE order_id = p_order_id;
  IF v_code_count < v_item_count THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_all_codes_assigned', 'needed', v_item_count, 'assigned', v_code_count);
  END IF;

  UPDATE orders SET status = 'completed', completed_at = now() WHERE id = p_order_id;

  FOR v_oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = v_order.device_code, product_code = v_oc.product_code
    WHERE code = v_oc.redemption_code AND used = false;

    v_gid := product_to_gid(v_oc.product_code);

    INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool)
    VALUES (v_order.device_code, v_oc.product_code, v_oc.redemption_code, COALESCE(v_gid, ''),
      (SELECT category FROM products WHERE code = v_oc.product_code))
    ON CONFLICT DO NOTHING;

    IF v_gid IS NOT NULL THEN
      INSERT INTO unlocks (device_code, gid, pool, redemption_code)
      VALUES (v_order.device_code, v_gid,
        (SELECT category FROM products WHERE code = v_oc.product_code),
        v_oc.redemption_code)
      ON CONFLICT (device_code, gid) DO NOTHING;
    END IF;
  END LOOP;

  -- 发票
  v_invoice := '【二游情报铺 · 电子发票】' || E'\n';
  v_invoice := v_invoice || '订单号: #' || p_order_id || E'\n';
  v_invoice := v_invoice || '设备码: ' || v_order.device_code || E'\n';
  v_invoice := v_invoice || '支付方式: ' || COALESCE(v_order.payment_method, '现金') || E'\n';
  IF v_order.is_group_buy THEN v_invoice := v_invoice || '拼团订单: 是' || E'\n'; END IF;
  v_invoice := v_invoice || E'\n--- 商品明细 ---' || E'\n';
  FOR v_oc IN SELECT oi.product_name, oi.quantity, oi.unit_price, oi.line_total FROM order_items oi WHERE oi.order_id = p_order_id LOOP
    v_invoice := v_invoice || v_oc.product_name || ' ×' || v_oc.quantity;
    IF v_oc.line_total = 0 THEN v_invoice := v_invoice || ' (赠品)' || E'\n';
    ELSE v_invoice := v_invoice || ' = ' || v_oc.line_total || '元' || E'\n'; END IF;
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
END; $$;
GRANT EXECUTE ON FUNCTION admin_auto_assign_and_complete(TEXT, INTEGER) TO anon;
