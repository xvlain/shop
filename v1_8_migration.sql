-- ============================================
-- 二游情报铺 v1.8 迁移
-- 1. 修复清除数据 bug：新增 shop_clear_unlocks RPC
-- 2. 售后系统：after_sales 表 + 相关 RPC
-- 3. 黑名单系统：blacklist 表 + 相关 RPC
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- ===== 1. 黑名单表 =====
CREATE TABLE IF NOT EXISTS blacklist (
  id SERIAL PRIMARY KEY,
  device_code TEXT NOT NULL UNIQUE,
  reason TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_blacklist_device ON blacklist(device_code);

-- ===== 2. 售后申请表 =====
CREATE TABLE IF NOT EXISTS after_sales (
  id SERIAL PRIMARY KEY,
  order_id INTEGER NOT NULL REFERENCES orders(id),
  device_code TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('cancel','change_group','return_items')),
  -- cancel: 取消整个订单
  -- change_group: 更换拼团
  -- return_items: 退换指定商品
  details JSONB DEFAULT '[]'::jsonb,
  -- return_items 时为 [{product_code, reason}]
  -- change_group 时为 {new_group_id} 或 null(退出拼团)
  status TEXT DEFAULT 'done' CHECK (status IN ('done','rejected')),
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_after_sales_order ON after_sales(order_id);
CREATE INDEX IF NOT EXISTS idx_after_sales_device ON after_sales(device_code);

-- ===== 3. 清除解锁记录（修复清除数据 bug）=====
CREATE OR REPLACE FUNCTION shop_clear_unlocks(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cnt INTEGER;
BEGIN
  -- 删除该设备码的所有兑换记录（解锁记录）
  DELETE FROM redemptions WHERE device_code = p_device;
  GET DIAGNOSTICS cnt = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'cleared', cnt);
END; $$;
GRANT EXECUTE ON FUNCTION shop_clear_unlocks(TEXT) TO anon;

-- ===== 4. 检查是否黑名单 =====
CREATE OR REPLACE FUNCTION shop_check_blacklist(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE is_bl BOOLEAN;
BEGIN
  SELECT EXISTS(SELECT 1 FROM blacklist WHERE device_code = p_device) INTO is_bl;
  RETURN jsonb_build_object('ok', true, 'is_blacklisted', COALESCE(is_bl, false));
END; $$;
GRANT EXECUTE ON FUNCTION shop_check_blacklist(TEXT) TO anon;

-- ===== 5. 用户获取自己的订单列表 =====
CREATE OR REPLACE FUNCTION shop_my_orders(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'id', o.id,
    'status', o.status,
    'total', COALESCE(o.total_price, 0),
    'is_group_buy', COALESCE(o.is_group_buy, false),
    'group_id', o.group_id,
    'payment_method', o.payment_method,
    'created_at', o.created_at,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'product_code', oi.product_code,
        'product_name', oi.product_name,
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'line_total', oi.line_total
      ))
      FROM order_items oi WHERE oi.order_id = o.id
    ), '[]'::jsonb),
    'codes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'product_code', oc.product_code,
        'redemption_code', oc.redemption_code
      ))
      FROM order_codes oc WHERE oc.order_id = o.id
    ), '[]'::jsonb),
    'after_sales_status', (
      SELECT asa.status FROM after_sales asa
      WHERE asa.order_id = o.id
      ORDER BY asa.created_at DESC LIMIT 1
    )
  ) ORDER BY o.created_at DESC) INTO rows
  FROM orders o
  WHERE o.device_code = p_device;

  RETURN jsonb_build_object('ok', true, 'orders', COALESCE(rows, '[]'::jsonb));
END; $$;
GRANT EXECUTE ON FUNCTION shop_my_orders(TEXT) TO anon;

-- ===== 6. 申请售后 =====
CREATE OR REPLACE FUNCTION shop_apply_after_sales(
  p_device TEXT,
  p_order_id INTEGER,
  p_type TEXT,
  p_details JSONB DEFAULT '[]'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order RECORD;
  v_group RECORD;
  v_is_bl BOOLEAN;
  v_existing RECORD;
BEGIN
  -- 检查黑名单
  SELECT EXISTS(SELECT 1 FROM blacklist WHERE device_code = p_device) INTO v_is_bl;
  IF v_is_bl THEN
    RETURN jsonb_build_object('ok', false, 'error', 'blacklisted');
  END IF;

  -- 检查订单存在且属于该设备
  SELECT * INTO v_order FROM orders WHERE id = p_order_id AND device_code = p_device;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  -- 条件 1: 订单未完成
  IF v_order.status = 'completed' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_completed');
  END IF;

  -- 条件 2: 参加的拼团没有结束，并没有向所有参加该拼团的用户发送结果
  IF v_order.group_id IS NOT NULL THEN
    SELECT * INTO v_group FROM groups WHERE id = v_order.group_id;
    IF v_group.status != 'pending' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_ended');
    END IF;
  END IF;

  -- 检查是否已经申请过售后（每个订单只能申请一次）
  SELECT * INTO v_existing FROM after_sales WHERE order_id = p_order_id LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_applied');
  END IF;

  -- 执行售后操作
  IF p_type = 'cancel' THEN
    -- 取消订单：将订单状态改为 cancelled，退出拼团
    UPDATE orders SET status = 'cancelled' WHERE id = p_order_id;
    IF v_order.group_id IS NOT NULL THEN
      UPDATE orders SET group_id = NULL WHERE id = p_order_id;
    END IF;

  ELSIF p_type = 'change_group' THEN
    -- 更换拼团
    IF p_details IS NOT NULL AND p_details ? 'new_group_id' THEN
      -- 加入新拼团
      UPDATE orders SET group_id = (p_details->>'new_group_id')::INTEGER
      WHERE id = p_order_id;
    ELSE
      -- 退出拼团
      UPDATE orders SET group_id = NULL, is_group_buy = false
      WHERE id = p_order_id;
    END IF;

  ELSIF p_type = 'return_items' THEN
    -- 退换商品：从订单中移除指定商品，退还兑换码
    DECLARE
      item RECORD;
      item_codes TEXT[];
    BEGIN
      FOR item IN SELECT jsonb_array_elements(p_details) AS obj LOOP
        -- 删除订单项
        DELETE FROM order_items
        WHERE order_id = p_order_id
          AND product_code = (item.obj->>'product_code');

        -- 回收并释放兑换码
        DELETE FROM order_codes
        WHERE order_id = p_order_id
          AND product_code = (item.obj->>'product_code')
        RETURNING redemption_code INTO item_codes;

        -- 将兑换码标记为已使用（废码）
        IF item_codes IS NOT NULL AND array_length(item_codes, 1) > 0 THEN
          UPDATE codes SET used = true, used_at = now(), device_code = p_device || '_returned'
          WHERE code = ANY(item_codes) AND used = false;
        END IF;

        -- 撤销该商品的解锁
        DELETE FROM redemptions
        WHERE device_code = p_device
          AND gid IN (
            SELECT gid FROM shop_product_gid_map
            WHERE product_code = (item.obj->>'product_code')
          );
      END LOOP;

      -- 更新订单总价
      UPDATE orders SET total_price = (
        SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id
      ) WHERE id = p_order_id;
    END;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  -- 记录售后申请
  INSERT INTO after_sales (order_id, device_code, type, details, status)
  VALUES (p_order_id, p_device, p_type, p_details, 'done');

  RETURN jsonb_build_object('ok', true, 'type', p_type);
END; $$;
GRANT EXECUTE ON FUNCTION shop_apply_after_sales(TEXT, INTEGER, TEXT, JSONB) TO anon;

-- ===== 7. 管理员：黑名单管理 =====
CREATE OR REPLACE FUNCTION admin_blacklist_list(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  IF NOT admin_check_secret(p_secret) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT jsonb_agg(jsonb_build_object(
    'id', b.id, 'device_code', b.device_code,
    'reason', b.reason, 'created_at', b.created_at
  ) ORDER BY b.created_at DESC) INTO rows FROM blacklist b;
  RETURN jsonb_build_object('ok', true, 'list', COALESCE(rows, '[]'::jsonb));
END; $$;
GRANT EXECUTE ON FUNCTION admin_blacklist_list(TEXT) TO anon;

CREATE OR REPLACE FUNCTION admin_blacklist_add(p_secret TEXT, p_device TEXT, p_reason TEXT DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT admin_check_secret(p_secret) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  INSERT INTO blacklist (device_code, reason) VALUES (p_device, p_reason)
  ON CONFLICT (device_code) DO UPDATE SET reason = p_reason, created_at = now();
  RETURN jsonb_build_object('ok', true);
END; $$;
GRANT EXECUTE ON FUNCTION admin_blacklist_add(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION admin_blacklist_remove(p_secret TEXT, p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT admin_check_secret(p_secret) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  DELETE FROM blacklist WHERE device_code = p_device;
  RETURN jsonb_build_object('ok', true);
END; $$;
GRANT EXECUTE ON FUNCTION admin_blacklist_remove(TEXT, TEXT) TO anon;

-- ===== 8. 管理员：查看售后列表 =====
CREATE OR REPLACE FUNCTION admin_after_sales_list(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  IF NOT admin_check_secret(p_secret) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT jsonb_agg(jsonb_build_object(
    'id', a.id, 'order_id', a.order_id, 'device_code', a.device_code,
    'type', a.type, 'details', a.details, 'status', a.status,
    'created_at', a.created_at
  ) ORDER BY a.created_at DESC) INTO rows FROM after_sales a;
  RETURN jsonb_build_object('ok', true, 'list', COALESCE(rows, '[]'::jsonb));
END; $$;
GRANT EXECUTE ON FUNCTION admin_after_sales_list(TEXT) TO anon;

-- ===== 9. 辅助表：product_code -> gid 映射（用于退换时撤销解锁）=====
CREATE TABLE IF NOT EXISTS shop_product_gid_map (
  product_code TEXT PRIMARY KEY,
  gid TEXT NOT NULL
);

-- 预填充映射数据
INSERT INTO shop_product_gid_map (product_code, gid) VALUES
  ('HSR45CHAR', '崩坏星穹铁道-4.5-角色'),
  ('HSR45LC',   '崩坏星穹铁道-4.5-光锥'),
  ('GI71CHAR',  '原神-7.1-角色'),
  ('GI71WPN',   '原神-7.1-武器'),
  ('ER13CHAR',  '异环-1.3-角色'),
  ('ER13WPN',   '异环-1.3-武器'),
  ('ZZZ32CHAR', '绝区零-3.2-代理人'),
  ('ZZZ32WPN',  '绝区零-3.2-音擎')
ON CONFLICT (product_code) DO NOTHING;

-- ===== 10. 更新 shop_submit_order 支持 cancelled 状态的订单重新下单 =====
-- （无需修改，cancelled 状态的订单不影响新订单提交）

-- ===== 11. 管理员：查看订单时包含 cancelled 状态 =====
-- admin_orders 已经返回所有订单，cancelled 状态会自动包含

-- ===== 12. 管理员统计：新增黑名单和售后计数 =====
-- 更新 admin_stats 添加黑名单和售后计数
DROP FUNCTION IF EXISTS admin_stats(TEXT);
CREATE OR REPLACE FUNCTION admin_stats(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_unused INTEGER; v_used INTEGER; v_redemptions INTEGER;
  v_free INTEGER; v_claimed INTEGER;
  v_char_unused INTEGER; v_weapon_unused INTEGER;
  v_blacklist INTEGER; v_after_sales INTEGER;
BEGIN
  IF NOT admin_check_secret(p_secret) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT count(*) INTO v_unused FROM codes WHERE used = false;
  SELECT count(*) INTO v_used FROM codes WHERE used = true;
  SELECT count(*) INTO v_redemptions FROM redemptions;
  SELECT count(*) INTO v_free FROM device_codes WHERE claimed = false;
  SELECT count(*) INTO v_claimed FROM device_codes WHERE claimed = true;
  SELECT count(*) INTO v_char_unused FROM codes WHERE used = false AND pool = 'character';
  SELECT count(*) INTO v_weapon_unused FROM codes WHERE used = false AND pool = 'weapon';
  SELECT count(*) INTO v_blacklist FROM blacklist;
  SELECT count(*) INTO v_after_sales FROM after_sales;
  RETURN jsonb_build_object(
    'ok', true,
    'unused_codes', v_unused, 'used_codes', v_used,
    'total_redemptions', v_redemptions,
    'free_devices', v_free, 'claimed_devices', v_claimed,
    'char_unused', v_char_unused, 'weapon_unused', v_weapon_unused,
    'blacklist_count', v_blacklist, 'after_sales_count', v_after_sales
  );
END; $$;
GRANT EXECUTE ON FUNCTION admin_stats(TEXT) TO anon;
