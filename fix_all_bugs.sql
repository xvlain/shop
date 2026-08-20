-- ============================================
-- 全面修复：订单提交 + 管理员显示 + 错误订单清理
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- 0. 先删除旧版函数（避免参数歧义）
DROP FUNCTION IF EXISTS shop_submit_order(TEXT, JSONB);

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
  -- 验证设备码
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;

  -- 如果加入拼团组，检查设备上限（最多 5 个不同设备）
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

  -- 插入订单项
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

  -- 更新订单总价
  UPDATE orders SET total_price = v_total WHERE id = v_oid;

  -- 检查拼团是否满 3 单
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

-- 2. 修正 admin_orders（返回 total_price 字段名，与前端一致）
CREATE OR REPLACE FUNCTION admin_orders(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT jsonb_agg(jsonb_build_object(
    'id', o.id, 'device_code', o.device_code, 'status', o.status,
    'total_price', o.total_price, 'total', o.total_price,
    'payment_method', o.payment_method,
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
END; $$;

-- 3. 修正 shop_public_groups（返回 total_price 字段名）
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

-- 4. 修正 shop_create_group
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

-- 5. 清理错误订单（之前因 bug 创建的异常订单）
DELETE FROM orders WHERE device_code IS NULL OR device_code = '' OR device_code = 'undefined';

-- 6. 授权
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;
GRANT EXECUTE ON FUNCTION shop_public_groups() TO anon;
GRANT EXECUTE ON FUNCTION shop_create_group(TEXT, TEXT) TO anon;
