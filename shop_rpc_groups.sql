-- 拼团管理函数 Part 3
-- 从 https://raw.githubusercontent.com/xvlain/shop/main/shop_rpc_groups.sql 复制全部内容到 Supabase SQL Editor 执行

CREATE OR REPLACE FUNCTION admin_create_group(p_secret TEXT, p_name TEXT DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE gid INTEGER;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  INSERT INTO order_groups (name) VALUES (COALESCE(p_name, '')) RETURNING id INTO gid;
  RETURN jsonb_build_object('ok', true, 'group_id', gid);
END; $$;

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

CREATE OR REPLACE FUNCTION admin_add_to_group(p_secret TEXT, p_order_id INTEGER, p_group_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE device_count INTEGER;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT count(DISTINCT o.device_code) INTO device_count FROM orders o WHERE o.group_id = p_group_id;
  IF device_count >= 5 THEN
    IF NOT EXISTS (SELECT 1 FROM orders WHERE id = p_order_id AND device_code IN (SELECT device_code FROM orders WHERE group_id = p_group_id)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_device_limit', 'max', 5, 'current', device_count);
    END IF;
  END IF;
  UPDATE orders SET group_id = p_group_id, is_group_buy = true WHERE id = p_order_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

CREATE OR REPLACE FUNCTION admin_remove_from_group(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  UPDATE orders SET group_id = NULL, is_group_buy = false WHERE id = p_order_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

CREATE OR REPLACE FUNCTION admin_rename_group(p_secret TEXT, p_group_id INTEGER, p_name TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  UPDATE order_groups SET name = p_name WHERE id = p_group_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

CREATE OR REPLACE FUNCTION admin_set_group_public(p_secret TEXT, p_group_id INTEGER, p_public BOOLEAN)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  UPDATE order_groups SET is_public = p_public, public_at = CASE WHEN p_public THEN now() ELSE NULL END WHERE id = p_group_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

CREATE OR REPLACE FUNCTION admin_delete_group(p_secret TEXT, p_group_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  UPDATE orders SET group_id = NULL, is_group_buy = false WHERE group_id = p_group_id;
  DELETE FROM order_groups WHERE id = p_group_id;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- 授权
GRANT EXECUTE ON FUNCTION shop_products() TO anon;
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB) TO anon;
GRANT EXECUTE ON FUNCTION shop_my_orders(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION shop_my_inbox(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION shop_unread_count(TEXT) TO anon;
