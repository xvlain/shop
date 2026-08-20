-- 商城函数 Part 1
-- 从 https://raw.githubusercontent.com/xvlain/shop/main/shop_rpc_shop.sql 复制全部内容到 Supabase SQL Editor 执行

CREATE OR REPLACE FUNCTION shop_products()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'code', code, 'name', name, 'price', price,
    'group_price', group_price, 'category', category,
    'game_group', game_group, 'game_name', game_name, 'ver', ver
  ) ORDER BY game_group, category DESC) INTO rows FROM products;
  RETURN jsonb_build_object('ok', true, 'products', COALESCE(rows, '[]'::jsonb));
END; $$;

CREATE OR REPLACE FUNCTION shop_submit_order(p_device TEXT, p_items JSONB)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  dc RECORD;
  order_id INTEGER;
  item JSONB;
  prod RECORD;
  qty INTEGER;
  total INTEGER := 0;
  line_total INTEGER;
  has_char BOOLEAN;
  has_wpn BOOLEAN;
  gg TEXT;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;
  INSERT INTO orders (device_code, status, total_price) VALUES (p_device, 'pending', 0) RETURNING id INTO order_id;
  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO prod FROM products WHERE code = (item->>'product_code');
    IF NOT FOUND THEN CONTINUE; END IF;
    qty := COALESCE((item->>'quantity')::int, 1);
    IF qty < 1 THEN qty := 1; END IF;
    line_total := prod.price * qty;
    INSERT INTO order_items (order_id, product_code, product_name, quantity, unit_price, line_total)
    VALUES (order_id, prod.code, prod.name, qty, prod.price, line_total);
    total := total + line_total;
  END LOOP;
  FOR gg IN SELECT DISTINCT p.game_group FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = order_id LOOP
    SELECT EXISTS(SELECT 1 FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = order_id AND p.game_group = gg AND p.category = 'character') INTO has_char;
    SELECT EXISTS(SELECT 1 FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = order_id AND p.game_group = gg AND p.category = 'weapon') INTO has_wpn;
    IF has_char AND has_wpn THEN
      UPDATE order_items SET line_total = 0, unit_price = 0
      WHERE order_id = order_id AND product_code IN (
        SELECT code FROM products WHERE game_group = gg AND category = 'weapon'
      );
    END IF;
  END LOOP;
  SELECT COALESCE(SUM(line_total), 0) INTO total FROM order_items WHERE order_id = order_id;
  UPDATE orders SET total_price = total WHERE id = order_id;
  RETURN jsonb_build_object('ok', true, 'order_id', order_id, 'total', total);
END; $$;

CREATE OR REPLACE FUNCTION shop_my_orders(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'id', o.id, 'status', o.status, 'total', o.total_price,
    'payment_method', o.payment_method, 'is_group_buy', o.is_group_buy,
    'group_id', o.group_id, 'notes', o.notes,
    'created_at', o.created_at, 'completed_at', o.completed_at,
    'items', (SELECT jsonb_agg(jsonb_build_object(
      'product_code', oi.product_code, 'product_name', oi.product_name,
      'quantity', oi.quantity, 'unit_price', oi.unit_price, 'line_total', oi.line_total
    )) FROM order_items oi WHERE oi.order_id = o.id),
    'codes', (SELECT jsonb_agg(jsonb_build_object(
      'redemption_code', oc.redemption_code, 'product_code', oc.product_code, 'password', oc.password
    )) FROM order_codes oc WHERE oc.order_id = o.id)
  ) ORDER BY o.created_at DESC) INTO rows FROM orders o WHERE o.device_code = p_device;
  RETURN jsonb_build_object('ok', true, 'orders', COALESCE(rows, '[]'::jsonb));
END; $$;

CREATE OR REPLACE FUNCTION shop_my_inbox(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'id', i.id, 'type', i.type, 'title', i.title,
    'content', i.content, 'is_read', i.is_read,
    'order_id', i.order_id, 'created_at', i.created_at
  ) ORDER BY i.created_at DESC) INTO rows FROM inbox i WHERE i.device_code = p_device;
  UPDATE inbox SET is_read = true WHERE device_code = p_device AND is_read = false;
  RETURN jsonb_build_object('ok', true, 'messages', COALESCE(rows, '[]'::jsonb));
END; $$;

CREATE OR REPLACE FUNCTION shop_unread_count(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cnt INTEGER;
BEGIN
  SELECT count(*) INTO cnt FROM inbox WHERE device_code = p_device AND is_read = false;
  RETURN jsonb_build_object('ok', true, 'count', cnt);
END; $$;
