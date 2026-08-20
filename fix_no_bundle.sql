-- 修正版 shop_submit_order（无捆绑免费）+ 拼团支持
-- 在 Supabase SQL Editor 中执行

-- 1. 修正 shop_submit_order（去掉捆绑免费，支持拼团参数）
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
  UPDATE orders SET total_price = v_total WHERE id = v_oid;
  -- Check if group reached 3 orders -> return group_ready
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

-- 2. 用户查看公开拼团组
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

-- 3. 用户发起拼团
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

-- 4. 授权
GRANT EXECUTE ON FUNCTION shop_public_groups() TO anon;
GRANT EXECUTE ON FUNCTION shop_create_group(TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;
