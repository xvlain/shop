-- ============================================
-- 二游情报铺 · 商城系统数据库扩展
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- ===== 1. 扩展 products 表 =====
ALTER TABLE products ADD COLUMN IF NOT EXISTS price INTEGER NOT NULL DEFAULT 0;
ALTER TABLE products ADD COLUMN IF NOT EXISTS group_price INTEGER NOT NULL DEFAULT 0;
ALTER TABLE products ADD COLUMN IF NOT EXISTS category TEXT NOT NULL DEFAULT 'character';
ALTER TABLE products ADD COLUMN IF NOT EXISTS game_group TEXT NOT NULL DEFAULT '';
ALTER TABLE products ADD COLUMN IF NOT EXISTS game_name TEXT NOT NULL DEFAULT '';
ALTER TABLE products ADD COLUMN IF NOT EXISTS ver TEXT NOT NULL DEFAULT '';

UPDATE products SET price = 5, group_price = 4, category = 'character', game_group = 'hsr45', game_name = '崩坏：星穹铁道', ver = '4.5' WHERE code = 'HSR45CHAR';
UPDATE products SET price = 2, group_price = 1, category = 'weapon',    game_group = 'hsr45', game_name = '崩坏：星穹铁道', ver = '4.5' WHERE code = 'HSR45LC';
UPDATE products SET price = 5, group_price = 4, category = 'character', game_group = 'gi71',  game_name = '原神', ver = '7.1' WHERE code = 'GI71CHAR';
UPDATE products SET price = 2, group_price = 1, category = 'weapon',    game_group = 'gi71',  game_name = '原神', ver = '7.1' WHERE code = 'GI71WPN';
UPDATE products SET price = 5, group_price = 4, category = 'character', game_group = 'er13',  game_name = '异环', ver = '1.3' WHERE code = 'ER13CHAR';
UPDATE products SET price = 2, group_price = 1, category = 'weapon',    game_group = 'er13',  game_name = '异环', ver = '1.3' WHERE code = 'ER13WPN';
UPDATE products SET price = 5, group_price = 4, category = 'character', game_group = 'zzz32', game_name = '绝区零', ver = '3.2' WHERE code = 'ZZZ32CHAR';
UPDATE products SET price = 2, group_price = 1, category = 'weapon',    game_group = 'zzz32', game_name = '绝区零', ver = '3.2' WHERE code = 'ZZZ32WPN';

-- ===== 2. 创建订单相关表 =====

CREATE TABLE IF NOT EXISTS order_groups (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  is_public BOOLEAN DEFAULT false,
  public_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
  id SERIAL PRIMARY KEY,
  device_code TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  payment_method TEXT,
  notes TEXT DEFAULT '',
  group_id INTEGER REFERENCES order_groups(id) ON DELETE SET NULL,
  is_group_buy BOOLEAN DEFAULT false,
  total_price INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS order_items (
  id SERIAL PRIMARY KEY,
  order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_code TEXT NOT NULL REFERENCES products(code),
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL DEFAULT 1,
  unit_price INTEGER NOT NULL,
  line_total INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS order_codes (
  id SERIAL PRIMARY KEY,
  order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  redemption_code TEXT NOT NULL,
  product_code TEXT NOT NULL,
  password TEXT NOT NULL,
  assigned_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inbox (
  id SERIAL PRIMARY KEY,
  device_code TEXT NOT NULL,
  order_id INTEGER REFERENCES orders(id) ON DELETE SET NULL,
  type TEXT NOT NULL DEFAULT 'invoice',
  title TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  is_read BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ===== 3. 启用 RLS =====
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE inbox ENABLE ROW LEVEL SECURITY;

-- ===== 4. 商城函数 =====

-- 获取所有在售商品
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

-- 用户提交订单
CREATE OR REPLACE FUNCTION shop_submit_order(
  p_device TEXT,
  p_items JSONB  -- [{"product_code":"HSR45CHAR","quantity":1}, ...]
)
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
  item_rec RECORD;
BEGIN
  -- verify device
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;

  -- create order
  INSERT INTO orders (device_code, status, total_price) VALUES (p_device, 'pending', 0) RETURNING id INTO order_id;

  -- insert items with pricing
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

  -- apply bundle rule: same game_group char+wpn → weapon free
  FOR gg IN SELECT DISTINCT p.game_group FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = order_id LOOP
    SELECT EXISTS(SELECT 1 FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = order_id AND p.game_group = gg AND p.category = 'character') INTO has_char;
    SELECT EXISTS(SELECT 1 FROM order_items oi JOIN products p ON oi.product_code = p.code WHERE oi.order_id = order_id AND p.game_group = gg AND p.category = 'weapon') INTO has_wpn;
    IF has_char AND has_wpn THEN
      -- set weapon line_total to 0
      UPDATE order_items SET line_total = 0, unit_price = 0
      WHERE order_id = order_id AND product_code IN (
        SELECT code FROM products WHERE game_group = gg AND category = 'weapon'
      );
    END IF;
  END LOOP;

  -- recalculate total
  SELECT COALESCE(SUM(line_total), 0) INTO total FROM order_items WHERE order_id = order_id;
  UPDATE orders SET total_price = total WHERE id = order_id;

  RETURN jsonb_build_object('ok', true, 'order_id', order_id, 'total', total);
END; $$;

-- 用户查看自己的订单
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

-- 用户查看邮箱
CREATE OR REPLACE FUNCTION shop_my_inbox(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'id', i.id, 'type', i.type, 'title', i.title,
    'content', i.content, 'is_read', i.is_read,
    'order_id', i.order_id, 'created_at', i.created_at
  ) ORDER BY i.created_at DESC) INTO rows FROM inbox i WHERE i.device_code = p_device;
  -- mark as read
  UPDATE inbox SET is_read = true WHERE device_code = p_device AND is_read = false;
  RETURN jsonb_build_object('ok', true, 'messages', COALESCE(rows, '[]'::jsonb));
END; $$;

-- 用户未读消息数
CREATE OR REPLACE FUNCTION shop_unread_count(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cnt INTEGER;
BEGIN
  SELECT count(*) INTO cnt FROM inbox WHERE device_code = p_device AND is_read = false;
  RETURN jsonb_build_object('ok', true, 'count', cnt);
END; $$;

-- ===== 5. 管理员订单函数 =====

-- 管理员获取所有订单
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

-- 管理员编辑订单（只能改 notes, payment_method, is_group_buy）
CREATE OR REPLACE FUNCTION admin_edit_order(
  p_secret TEXT, p_order_id INTEGER,
  p_notes TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT NULL,
  p_is_group_buy BOOLEAN DEFAULT NULL
)
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

-- 管理员分配兑换码到订单
CREATE OR REPLACE FUNCTION admin_assign_codes(
  p_secret TEXT, p_order_id INTEGER,
  p_codes JSONB  -- [{"redemption_code":"XXXX-XXXX","product_code":"HSR45CHAR"}, ...]
)
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
    -- remove existing assignment for this order+product
    DELETE FROM order_codes WHERE order_id = p_order_id AND product_code = (item->>'product_code');
    INSERT INTO order_codes (order_id, redemption_code, product_code, password)
    VALUES (p_order_id, item->>'redemption_code', item->>'product_code', pwd);
  END LOOP;

  RETURN jsonb_build_object('ok', true);
END; $$;

-- 管理员完成订单
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

  -- check codes assigned
  SELECT count(*) INTO item_count FROM order_items WHERE order_id = p_order_id AND line_total > 0;
  SELECT count(*) INTO total FROM order_codes WHERE order_id = p_order_id;
  IF total < item_count THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_all_codes_assigned', 'needed', item_count, 'assigned', total);
  END IF;

  -- mark order completed
  UPDATE orders SET status = 'completed', completed_at = now() WHERE id = p_order_id;

  -- mark redemption codes as used
  FOR oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = o.device_code, product_code = oc.product_code
    WHERE code = oc.redemption_code AND used = false;
    -- add to redemptions table
    INSERT INTO redemptions (device_code, product_code, redemption_code, password)
    VALUES (o.device_code, oc.product_code, oc.redemption_code, oc.password)
    ON CONFLICT (device_code, product_code) DO NOTHING;
  END LOOP;

  -- build invoice
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

  -- send invoice to inbox
  INSERT INTO inbox (device_code, order_id, type, title, content)
  VALUES (o.device_code, p_order_id, 'invoice', '订单 #' || p_order_id || ' 电子发票', invoice_text);

  -- send codes to inbox
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

-- ===== 6. 拼团管理函数 =====

-- 创建拼团组
CREATE OR REPLACE FUNCTION admin_create_group(p_secret TEXT, p_name TEXT DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE gid INTEGER;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  INSERT INTO order_groups (name) VALUES (COALESCE(p_name, '')) RETURNING id INTO gid;
  RETURN jsonb_build_object('ok', true, 'group_id', gid);
END; $$;

-- 获取所有拼团组
CREATE OR REPLACE FUNCTION admin_groups(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT jsonb_agg(jsonb_build_object(
    'id', g.id, 'name', g.name, 'is_public', g.is_public,
    'public_at', g.public_at, 'status', g.status, 'created_at', g.created_at,
    'order_count', (SELECT count(*) FROM orders o WHERE o.group_id = g.id),
    'device_count', (SELECT count(DISTINCT o.device_code) FROM orders o WHERE o.group_id = g.id),
    'total_price', (SELECT COALESCE(SUM(o.total_price), 0) FROM orders o WHERE o.group_id = g.id)
  ) ORDER BY g.created_at DESC) INTO rows FROM order_groups g;
  RETURN jsonb_build_object('ok', true, 'groups', COALESCE(rows, '[]'::jsonb));
END; $$;

-- 将订单加入拼团组
CREATE OR REPLACE FUNCTION admin_add_to_group(p_secret TEXT, p_order_id INTEGER, p_group_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  device_count INTEGER;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  -- check group device limit (max 5 distinct devices)
  SELECT count(DISTINCT o.device_code) INTO device_count FROM orders o WHERE o.group_id = p_group_id;
  IF device_count >= 5 THEN
    -- check if this order's device is already in the group
    IF NOT EXISTS (SELECT 1 FROM orders WHERE id = p_order_id AND device_code IN (SELECT device_code FROM orders WHERE group_id = p_group_id)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_device_limit', 'max', 5, 'current', device_count);
    END IF;
  END IF;
  UPDATE orders SET group_id = p_group_id, is_group_buy = true WHERE id = p_order_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- 将订单移出拼团组
CREATE OR REPLACE FUNCTION admin_remove_from_group(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  UPDATE orders SET group_id = NULL, is_group_buy = false WHERE id = p_order_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- 重命名拼团组
CREATE OR REPLACE FUNCTION admin_rename_group(p_secret TEXT, p_group_id INTEGER, p_name TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  UPDATE order_groups SET name = p_name WHERE id = p_group_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- 设置拼团组公开状态
CREATE OR REPLACE FUNCTION admin_set_group_public(p_secret TEXT, p_group_id INTEGER, p_public BOOLEAN)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  UPDATE order_groups SET is_public = p_public, public_at = CASE WHEN p_public THEN now() ELSE NULL END WHERE id = p_group_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- 删除拼团组（将组内订单移出）
CREATE OR REPLACE FUNCTION admin_delete_group(p_secret TEXT, p_group_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  UPDATE orders SET group_id = NULL, is_group_buy = false WHERE group_id = p_group_id;
  DELETE FROM order_groups WHERE id = p_group_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- ===== 7. 授权 =====
GRANT EXECUTE ON FUNCTION shop_products() TO anon;
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB) TO anon;
GRANT EXECUTE ON FUNCTION shop_my_orders(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION shop_my_inbox(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION shop_unread_count(TEXT) TO anon;

-- ===== 完成 =====
