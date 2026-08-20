-- ============================================
-- 二游情报铺 · 用户拼团功能
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- ===== 1. 用户查看可加入的公开拼团 =====
CREATE OR REPLACE FUNCTION shop_public_groups(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'id', g.id, 'name', g.name,
    'order_count', (SELECT count(*) FROM orders o WHERE o.group_id = g.id),
    'device_count', (SELECT count(DISTINCT o.device_code) FROM orders o WHERE o.group_id = g.id),
    'total_price', (SELECT COALESCE(SUM(o.total_price), 0) FROM orders o WHERE o.group_id = g.id),
    'created_at', g.created_at
  ) ORDER BY g.created_at DESC) INTO rows
  FROM order_groups g
  WHERE g.is_public = true AND g.status = 'pending';
  RETURN jsonb_build_object('ok', true, 'groups', COALESCE(rows, '[]'::jsonb));
END; $function$;

-- ===== 2. 用户发起拼团 =====
CREATE OR REPLACE FUNCTION shop_create_group(p_device TEXT, p_name TEXT DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE v_gid INTEGER;
BEGIN
  INSERT INTO order_groups (name, is_public, status) VALUES (COALESCE(p_name, ''), true, 'pending') RETURNING id INTO v_gid;
  RETURN jsonb_build_object('ok', true, 'group_id', v_gid);
END; $function$;

-- ===== 3. 更新 shop_submit_order 支持拼团 =====
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
  v_status TEXT;
  v_group_count INTEGER;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;
  -- 有拼团则等拼团满3单，无拼团则直接pending
  IF p_group_id IS NOT NULL THEN
    v_status := 'waiting';
  ELSE
    v_status := 'pending';
  END IF;
  INSERT INTO orders (device_code, status, total_price, group_id, is_group_buy)
  VALUES (p_device, v_status, 0, p_group_id, p_group_id IS NOT NULL) RETURNING id INTO v_oid;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_prod FROM products WHERE code = (v_item->>'product_code');
    IF NOT FOUND THEN CONTINUE; END IF;
    v_qty := COALESCE((v_item->>'quantity')::int, 1);
    IF v_qty < 1 THEN v_qty := 1; END IF;
    -- 拼团用 group_price，非拼团用 price
    IF p_group_id IS NOT NULL THEN
      v_lt := v_prod.group_price * v_qty;
    ELSE
      v_lt := v_prod.price * v_qty;
    END IF;
    INSERT INTO order_items (order_id, product_code, product_name, quantity, unit_price, line_total)
    VALUES (v_oid, v_prod.code, v_prod.name, v_qty, v_prod.price, v_lt);
    v_total := v_total + v_lt;
  END LOOP;
  -- 同版本角色+武器捆绑：武器免费
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
  -- 拼团：检查是否满3单，满则改为pending通知店主
  IF p_group_id IS NOT NULL THEN
    SELECT count(*) INTO v_group_count FROM orders WHERE group_id = p_group_id;
    IF v_group_count >= 3 THEN
      UPDATE order_groups SET status = 'ready' WHERE id = p_group_id AND status = 'pending';
      UPDATE orders SET status = 'pending' WHERE group_id = p_group_id AND status = 'waiting';
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'order_id', v_oid, 'total', v_total, 'status', v_status);
END; $function$;

-- ===== 4. 更新 admin_orders 显示 waiting 状态 =====
CREATE OR REPLACE FUNCTION admin_orders(p_secret TEXT)
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
  ) ORDER BY o.created_at DESC) INTO rows FROM orders o;
  RETURN jsonb_build_object('ok', true, 'orders', COALESCE(rows, '[]'::jsonb));
END; $function$;

-- ===== 5. 授权 =====
GRANT EXECUTE ON FUNCTION shop_public_groups(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION shop_create_group(TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;
