-- 拼团相关 RPC 函数
-- 在 Supabase SQL Editor 中执行

-- 1. 查看公开拼团组
CREATE OR REPLACE FUNCTION shop_public_groups()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'id', g.id, 'name', g.name,
    'order_count', (SELECT count(*) FROM orders o WHERE o.group_id = g.id),
    'device_count', (SELECT count(DISTINCT o.device_code) FROM orders o WHERE o.group_id = g.id),
    'total_price', (SELECT COALESCE(SUM(o.total_price), 0) FROM orders o WHERE o.group_id = g.id)
  ) ORDER BY g.created_at DESC) INTO rows FROM order_groups g WHERE g.is_public = true;
  RETURN jsonb_build_object('ok', true, 'groups', COALESCE(rows, '[]'::jsonb));
END; $function$;

-- 2. 用户发起拼团
CREATE OR REPLACE FUNCTION shop_create_group(p_device TEXT, p_name TEXT DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  dc RECORD;
  v_gid INTEGER;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;
  INSERT INTO order_groups (name, is_public) VALUES (COALESCE(p_name, ''), true) RETURNING id INTO v_gid;
  RETURN jsonb_build_object('ok', true, 'group_id', v_gid);
END; $function$;

-- 3. 提交订单（支持拼团）
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
  v_has_char BOOLEAN;
  v_has_wpn BOOLEAN;
  v_gg TEXT;
  v_dev_count INTEGER;
  v_order_count INTEGER;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;
  -- If joining a group, check device limit (max 5)
  IF p_group_id IS NOT NULL THEN
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
    v_qty := COALESCE((v_item->>'quantity')::int, 1);
    IF v_qty < 1 THEN v_qty := 1; END IF;
    v_lt := v_prod.price * v_qty;
    INSERT INTO order_items (order_id, product_code, product_name, quantity, unit_price, line_total)
    VALUES (v_oid, v_prod.code, v_prod.name, v_qty, v_prod.price, v_lt);
    v_total := v_total + v_lt;
  END LOOP;
  -- bundle: same game_group char+weapon -> weapon free
  FOR v_gg IN SELECT DISTINCT p.game_group FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = v_oid LOOP
    SELECT EXISTS(SELECT 1 FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = v_oid AND p.game_group = v_gg AND p.category = 'character') INTO v_has_char;
    SELECT EXISTS(SELECT 1 FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = v_oid AND p.game_group = v_gg AND p.category = 'weapon') INTO v_has_wpn;
    IF v_has_char AND v_has_wpn THEN
      UPDATE order_items SET line_total = 0, unit_price = 0
      WHERE order_items.order_id = v_oid AND product_code IN (
        SELECT code FROM products WHERE game_group = v_gg AND category = 'weapon'
      );
    END IF;
  END LOOP;
  SELECT COALESCE(SUM(order_items.line_total), 0) INTO v_total FROM order_items WHERE order_items.order_id = v_oid;
  UPDATE orders SET total_price = v_total WHERE id = v_oid;
  -- Check if group reached 3 orders -> notify
  IF p_group_id IS NOT NULL THEN
    SELECT count(*) INTO v_order_count FROM orders WHERE group_id = p_group_id;
    IF v_order_count >= 3 THEN
      RETURN jsonb_build_object('ok', true, 'order_id', v_oid, 'total', v_total, 'group_ready', true, 'order_count', v_order_count);
    ELSE
      RETURN jsonb_build_object('ok', true, 'order_id', v_oid, 'total', v_total, 'group_ready', false, 'order_count', v_order_count);
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'order_id', v_oid, 'total', v_total);
END; $function$;

-- 4. 管理员查看待处理订单（含拼团满3单的）
CREATE OR REPLACE FUNCTION admin_orders_ready(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT jsonb_agg(jsonb_build_object(
    'id', o.id, 'device_code', o.device_code, 'status', o.status,
    'total', o.total_price, 'payment_method', o.payment_method,
    'is_group_buy', o.is_group_buy, 'group_id', o.group_id,
    'notes', o.notes, 'created_at', o.created_at, 'completed_at', o.completed_at,
    'items', (SELECT jsonb_agg(jsonb_build_object(
      'product_code', oi.product_code, 'product_name', oi.product_name,
      'quantity', oi.quantity, 'unit_price', oi.unit_price, 'line_total', oi.line_total
    )) FROM order_items oi WHERE oi.order_id = o.id),
    'codes', (SELECT jsonb_agg(jsonb_build_object(
      'redemption_code', oc.redemption_code, 'product_code', oc.product_code, 'password', oc.password
    )) FROM order_codes oc WHERE oc.order_id = o.id)
  ) ORDER BY o.created_at DESC) INTO rows FROM orders o
  WHERE o.status = 'pending' AND (
    o.is_group_buy = false
    OR (o.group_id IS NOT NULL AND (SELECT count(*) FROM orders o2 WHERE o2.group_id = o.group_id) >= 3)
  );
  RETURN jsonb_build_object('ok', true, 'orders', COALESCE(rows, '[]'::jsonb));
END; $function$;

-- 5. 授权
GRANT EXECUTE ON FUNCTION shop_public_groups() TO anon;
GRANT EXECUTE ON FUNCTION shop_create_group(TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;
