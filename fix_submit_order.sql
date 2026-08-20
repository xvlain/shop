CREATE OR REPLACE FUNCTION shop_submit_order(p_device TEXT, p_items JSONB)
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
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;
  INSERT INTO orders (device_code, status, total_price) VALUES (p_device, 'pending', 0) RETURNING id INTO v_oid;
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
  RETURN jsonb_build_object('ok', true, 'order_id', v_oid, 'total', v_total);
END; $function$;
