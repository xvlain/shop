-- 管理员订单函数 Part 2
-- 从 https://raw.githubusercontent.com/xvlain/shop/main/shop_rpc_admin.sql 复制全部内容到 Supabase SQL Editor 执行

CREATE OR REPLACE FUNCTION admin_orders(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
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
END; $$;

CREATE OR REPLACE FUNCTION admin_edit_order(p_secret TEXT, p_order_id INTEGER, p_notes TEXT DEFAULT NULL, p_payment_method TEXT DEFAULT NULL, p_is_group_buy BOOLEAN DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE o RECORD;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT * INTO o FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;
  IF o.status = 'completed' THEN RETURN jsonb_build_object('ok', false, 'error', 'order_already_completed'); END IF;
  IF p_notes IS NOT NULL THEN UPDATE orders SET notes = p_notes WHERE id = p_order_id; END IF;
  IF p_payment_method IS NOT NULL THEN UPDATE orders SET payment_method = p_payment_method WHERE id = p_order_id; END IF;
  IF p_is_group_buy IS NOT NULL THEN UPDATE orders SET is_group_buy = p_is_group_buy WHERE id = p_order_id; END IF;
  RETURN jsonb_build_object('ok', true);
END; $$;

CREATE OR REPLACE FUNCTION admin_assign_codes(p_secret TEXT, p_order_id INTEGER, p_codes JSONB)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  o RECORD;
  item JSONB;
  rc RECORD;
  pwd TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT * INTO o FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;
  FOR item IN SELECT * FROM jsonb_array_elements(p_codes) LOOP
    SELECT * INTO rc FROM redemption_codes WHERE code = (item->>'redemption_code') AND used = false;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'code_not_available', 'code', item->>'redemption_code');
    END IF;
    pwd := derive_password(o.device_code, item->>'product_code');
    DELETE FROM order_codes WHERE order_id = p_order_id AND product_code = (item->>'product_code');
    INSERT INTO order_codes (order_id, redemption_code, product_code, password)
    VALUES (p_order_id, item->>'redemption_code', item->>'product_code', pwd);
  END LOOP;
  RETURN jsonb_build_object('ok', true);
END; $$;

CREATE OR REPLACE FUNCTION admin_complete_order(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  o RECORD;
  oc RECORD;
  invoice_text TEXT := '';
  code_text TEXT := '';
  total INTEGER;
  item_count INTEGER;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT * INTO o FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;
  SELECT count(*) INTO item_count FROM order_items WHERE order_id = p_order_id AND line_total > 0;
  SELECT count(*) INTO total FROM order_codes WHERE order_id = p_order_id;
  IF total < item_count THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_all_codes_assigned', 'needed', item_count, 'assigned', total);
  END IF;
  UPDATE orders SET status = 'completed', completed_at = now() WHERE id = p_order_id;
  FOR oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = o.device_code, product_code = oc.product_code
    WHERE code = oc.redemption_code AND used = false;
    INSERT INTO redemptions (device_code, product_code, redemption_code, password)
    VALUES (o.device_code, oc.product_code, oc.redemption_code, oc.password)
    ON CONFLICT (device_code, product_code) DO NOTHING;
  END LOOP;
  invoice_text := '【二游情报铺 · 电子发票】' || E'\n';
  invoice_text := invoice_text || '订单号: #' || p_order_id || E'\n';
  invoice_text := invoice_text || '设备码: ' || o.device_code || E'\n';
  invoice_text := invoice_text || '支付方式: ' || COALESCE(o.payment_method, '现金') || E'\n';
  IF o.is_group_buy THEN invoice_text := invoice_text || '拼团订单: 是' || E'\n'; END IF;
  invoice_text := invoice_text || E'\n--- 商品明细 ---' || E'\n';
  FOR oc IN SELECT oi.product_name, oi.quantity, oi.unit_price, oi.line_total FROM order_items oi WHERE oi.order_id = p_order_id LOOP
    invoice_text := invoice_text || oc.product_name || ' ×' || oc.quantity;
    IF oc.line_total = 0 THEN
      invoice_text := invoice_text || ' (赠品)' || E'\n';
    ELSE
      invoice_text := invoice_text || ' = ' || oc.line_total || '元' || E'\n';
    END IF;
  END LOOP;
  invoice_text := invoice_text || E'\n合计: ' || o.total_price || '元' || E'\n';
  invoice_text := invoice_text || '完成时间: ' || to_char(now(), 'YYYY-MM-DD HH24:MI') || E'\n';
  invoice_text := invoice_text || E'\n感谢惠顾！';
  INSERT INTO inbox (device_code, order_id, type, title, content)
  VALUES (o.device_code, p_order_id, 'invoice', '订单 #' || p_order_id || ' 电子发票', invoice_text);
  FOR oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    code_text := '商品: ' || (SELECT name FROM products WHERE code = oc.product_code) || E'\n';
    code_text := code_text || '兑换码: ' || oc.redemption_code || E'\n';
    code_text := code_text || '密码: ' || oc.password || E'\n\n';
    code_text := code_text || '请在「兑换」页面输入兑换码获取密码。';
    INSERT INTO inbox (device_code, order_id, type, title, content)
    VALUES (o.device_code, p_order_id, 'code', oc.product_code || ' 兑换码', code_text);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'invoice', invoice_text);
END; $$;
