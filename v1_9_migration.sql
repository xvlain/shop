-- ============================================
-- 二游情报铺 v1.9 迁移
-- 修复 v1.8 中的多处错误 + 完善功能
-- 1. 修复清除数据 bug：正确删除 unlocks + redemptions
-- 2. 黑名单系统：修正表引用
-- 3. 售后系统：修正表引用，完善逻辑
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- ===== 0. 辅助函数：管理员密码验证 =====
CREATE OR REPLACE FUNCTION admin_check_secret(p_secret TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN p_secret = 'Qwert12345';
END; $$;

-- ===== 1. 黑名单表（幂等）=====
CREATE TABLE IF NOT EXISTS blacklist (
  id SERIAL PRIMARY KEY,
  device_code TEXT NOT NULL UNIQUE,
  reason TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_blacklist_device ON blacklist(device_code);

-- 设置 RLS
ALTER TABLE blacklist ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "blacklist_select_all" ON blacklist;
CREATE POLICY "blacklist_select_all" ON blacklist FOR SELECT TO anon USING (true);

-- ===== 2. 售后申请表（幂等）=====
CREATE TABLE IF NOT EXISTS after_sales (
  id SERIAL PRIMARY KEY,
  order_id INTEGER NOT NULL REFERENCES orders(id),
  device_code TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('cancel','change_group','return_items')),
  details JSONB DEFAULT '[]'::jsonb,
  status TEXT DEFAULT 'done' CHECK (status IN ('done','rejected')),
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_after_sales_order ON after_sales(order_id);
CREATE INDEX IF NOT EXISTS idx_after_sales_device ON after_sales(device_code);

ALTER TABLE after_sales ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "after_sales_select_all" ON after_sales;
CREATE POLICY "after_sales_select_all" ON after_sales FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "after_sales_insert" ON after_sales;
CREATE POLICY "after_sales_insert" ON after_sales FOR INSERT TO anon WITH CHECK (true);

-- ===== 3. product_code -> gid 映射表（幂等）=====
CREATE TABLE IF NOT EXISTS shop_product_gid_map (
  product_code TEXT PRIMARY KEY,
  gid TEXT NOT NULL
);

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

-- ===== 4. 修复：清除设备解锁记录 =====
CREATE OR REPLACE FUNCTION shop_clear_unlocks(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cnt INTEGER;
BEGIN
  -- 删除 unlocks 表中的记录（check_unlocks 读的就是这个表）
  DELETE FROM unlocks WHERE device_code = p_device;
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  -- 同步清理 redemptions 表
  DELETE FROM redemptions WHERE device_code = p_device;
  -- 清除设备指纹，使下次 claim 获得新设备码
  UPDATE device_codes SET fingerprint = NULL WHERE code = p_device;
  RETURN jsonb_build_object('ok', true, 'cleared', v_cnt);
END; $$;
GRANT EXECUTE ON FUNCTION shop_clear_unlocks(TEXT) TO anon;

-- ===== 5. 检查是否黑名单 =====
CREATE OR REPLACE FUNCTION shop_check_blacklist(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE is_bl BOOLEAN;
BEGIN
  SELECT EXISTS(SELECT 1 FROM blacklist WHERE device_code = p_device) INTO is_bl;
  RETURN jsonb_build_object('ok', true, 'is_blacklisted', COALESCE(is_bl, false));
END; $$;
GRANT EXECUTE ON FUNCTION shop_check_blacklist(TEXT) TO anon;

-- ===== 6. 查询售后资格（前端用来判断可用操作）=====
CREATE OR REPLACE FUNCTION shop_check_after_sales(p_device TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order RECORD;
  v_group RECORD;
  v_is_bl BOOLEAN;
  v_existing RECORD;
  v_can_cancel BOOLEAN := false;
  v_can_change_group BOOLEAN := false;
  v_can_return BOOLEAN := false;
  v_reason TEXT := '';
BEGIN
  -- 检查黑名单
  SELECT EXISTS(SELECT 1 FROM blacklist WHERE device_code = p_device) INTO v_is_bl;
  IF v_is_bl THEN
    RETURN jsonb_build_object('ok', true, 'eligible', false, 'reason', '你的账号已被限制，无法申请售后');
  END IF;

  -- 检查订单
  SELECT * INTO v_order FROM orders WHERE id = p_order_id AND device_code = p_device;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'eligible', false, 'reason', '订单不存在');
  END IF;

  -- 条件1：订单未完成
  IF v_order.status = 'completed' THEN
    RETURN jsonb_build_object('ok', true, 'eligible', false, 'reason', '已完成的订单不可售后');
  END IF;
  IF v_order.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', true, 'eligible', false, 'reason', '已取消的订单不可售后');
  END IF;

  -- 条件2：拼团未结束
  IF v_order.group_id IS NOT NULL THEN
    SELECT * INTO v_group FROM order_groups WHERE id = v_order.group_id;
    IF v_group.status != 'pending' THEN
      RETURN jsonb_build_object('ok', true, 'eligible', false, 'reason', '拼团已结束，无法售后');
    END IF;
  END IF;

  -- 检查是否已申请过售后（每订单限一次）
  SELECT * INTO v_existing FROM after_sales WHERE order_id = p_order_id LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'eligible', false, 'reason', '此订单已申请过售后');
  END IF;

  -- 判断可用操作
  v_can_cancel := true;
  v_can_return := true;
  IF v_order.group_id IS NOT NULL THEN
    v_can_change_group := true;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'eligible', true,
    'can_cancel', v_can_cancel,
    'can_change_group', v_can_change_group,
    'can_return', v_can_return
  );
END; $$;
GRANT EXECUTE ON FUNCTION shop_check_after_sales(TEXT, INTEGER) TO anon;

-- ===== 7. 申请售后 =====
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
  v_oc RECORD;
  v_item JSONB;
  v_gid TEXT;
  v_affected INTEGER := 0;
BEGIN
  -- 检查黑名单
  SELECT EXISTS(SELECT 1 FROM blacklist WHERE device_code = p_device) INTO v_is_bl;
  IF v_is_bl THEN
    RETURN jsonb_build_object('ok', false, 'error', 'blacklisted', 'message', '你的账号已被限制，无法申请售后');
  END IF;

  -- 检查订单存在且属于该设备
  SELECT * INTO v_order FROM orders WHERE id = p_order_id AND device_code = p_device;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  -- 条件1：订单未完成
  IF v_order.status IN ('completed', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_pending');
  END IF;

  -- 条件2：拼团未结束
  IF v_order.group_id IS NOT NULL THEN
    SELECT * INTO v_group FROM order_groups WHERE id = v_order.group_id;
    IF v_group.status != 'pending' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_ended');
    END IF;
  END IF;

  -- 每个订单只能申请一次售后
  SELECT * INTO v_existing FROM after_sales WHERE order_id = p_order_id LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_applied');
  END IF;

  -- 执行售后操作
  IF p_type = 'cancel' THEN
    -- 取消订单
    -- 释放已分配的兑换码
    FOR v_oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
      UPDATE redemption_codes SET used = false, used_at = NULL, used_by_device = NULL
      WHERE code = v_oc.redemption_code AND used = true;
    END LOOP;
    DELETE FROM order_codes WHERE order_id = p_order_id;
    -- 撤销解锁
    DELETE FROM unlocks WHERE device_code = p_device AND gid IN (
      SELECT gid FROM shop_product_gid_map WHERE product_code IN (
        SELECT product_code FROM order_items WHERE order_id = p_order_id
      )
    );
    -- 标记订单为已取消
    UPDATE orders SET status = 'cancelled', completed_at = now(), group_id = NULL, is_group_buy = false WHERE id = p_order_id;

  ELSIF p_type = 'change_group' THEN
    -- 更换拼团
    IF p_details IS NOT NULL AND p_details ? 'new_group_id' AND p_details->>'new_group_id' != '' THEN
      -- 加入新拼团
      DECLARE v_new_gid INTEGER := (p_details->>'new_group_id')::INTEGER;
      BEGIN
        SELECT * INTO v_group FROM order_groups WHERE id = v_new_gid;
        IF NOT FOUND OR NOT v_group.is_public OR v_group.status != 'pending' THEN
          RETURN jsonb_build_object('ok', false, 'error', 'invalid_group');
        END IF;
        -- 先退出旧拼团
        IF v_order.group_id IS NOT NULL THEN
          -- 恢复旧拼团的价格
          UPDATE order_items oi SET line_total = oi.unit_price
          WHERE oi.order_id = p_order_id AND oi.line_total = 0 AND oi.unit_price > 0;
        END IF;
        -- 加入新拼团
        UPDATE orders SET group_id = v_new_gid, is_group_buy = true WHERE id = p_order_id;
        -- 应用拼团优惠（同游戏角色+武器 → 武器免费）
        DECLARE v_gg TEXT; v_has_char BOOLEAN; v_has_wpn BOOLEAN;
        BEGIN
          FOR v_gg IN SELECT DISTINCT p2.game_group FROM order_items oi2 JOIN products p2 ON oi2.product_code = p2.code WHERE oi2.order_id = p_order_id LOOP
            SELECT EXISTS(SELECT 1 FROM order_items oi3 JOIN products p3 ON oi3.product_code = p3.code WHERE oi3.order_id = p_order_id AND p3.game_group = v_gg AND p3.category = 'character' AND oi3.line_total > 0) INTO v_has_char;
            SELECT EXISTS(SELECT 1 FROM order_items oi4 JOIN products p4 ON oi4.product_code = p4.code WHERE oi4.order_id = p_order_id AND p4.game_group = v_gg AND p4.category = 'weapon') INTO v_has_wpn;
            IF v_has_char AND v_has_wpn THEN
              UPDATE order_items SET line_total = 0, unit_price = 0
              WHERE order_id = p_order_id AND product_code IN (SELECT code FROM products WHERE game_group = v_gg AND category = 'weapon');
            END IF;
          END LOOP;
        END;
        UPDATE orders SET total_price = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id) WHERE id = p_order_id;
      END;
    ELSE
      -- 退出拼团
      IF v_order.group_id IS NOT NULL THEN
        -- 恢复价格
        UPDATE order_items oi SET line_total = oi.unit_price
        WHERE oi.order_id = p_order_id AND oi.line_total = 0 AND oi.unit_price > 0;
        UPDATE orders SET group_id = NULL, is_group_buy = false WHERE id = p_order_id;
        UPDATE orders SET total_price = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id) WHERE id = p_order_id;
      END IF;
    END IF;

  ELSIF p_type = 'return_items' THEN
    -- 退换指定商品
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_details) LOOP
      -- 释放该商品的兑换码
      FOR v_oc IN SELECT * FROM order_codes WHERE order_id = p_order_id AND product_code = (v_item->>'product_code') LOOP
        UPDATE redemption_codes SET used = false, used_at = NULL, used_by_device = NULL
        WHERE code = v_oc.redemption_code AND used = true;
      END LOOP;
      DELETE FROM order_codes WHERE order_id = p_order_id AND product_code = (v_item->>'product_code');
      -- 撤销解锁
      SELECT gid INTO v_gid FROM shop_product_gid_map WHERE product_code = (v_item->>'product_code');
      IF v_gid IS NOT NULL THEN
        DELETE FROM unlocks WHERE device_code = p_device AND gid = v_gid;
        DELETE FROM redemptions WHERE device_code = p_device AND gid = v_gid;
      END IF;
      -- 从订单移除该商品
      DELETE FROM order_items WHERE order_id = p_order_id AND product_code = (v_item->>'product_code');
      GET DIAGNOSTICS v_affected = ROW_COUNT;
    END LOOP;
    -- 重新计算总价
    UPDATE orders SET total_price = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id) WHERE id = p_order_id;
    -- 如果订单为空，标记取消
    IF NOT EXISTS (SELECT 1 FROM order_items WHERE order_id = p_order_id) THEN
      UPDATE orders SET status = 'cancelled', completed_at = now() WHERE id = p_order_id;
    END IF;

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  -- 记录售后
  INSERT INTO after_sales (order_id, device_code, type, details, status)
  VALUES (p_order_id, p_device, p_type, p_details, 'done');

  RETURN jsonb_build_object('ok', true, 'type', p_type);
END; $$;
GRANT EXECUTE ON FUNCTION shop_apply_after_sales(TEXT, INTEGER, TEXT, JSONB) TO anon;

-- ===== 8. 管理员：黑名单管理 =====
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
  -- 验证设备码存在
  IF NOT EXISTS (SELECT 1 FROM device_codes WHERE code = p_device) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_found');
  END IF;
  INSERT INTO blacklist (device_code, reason) VALUES (p_device, COALESCE(p_reason, ''))
  ON CONFLICT (device_code) DO UPDATE SET reason = EXCLUDED.reason, created_at = now();
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

-- ===== 9. 管理员：查看售后列表 =====
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

-- ===== 10. 更新 shop_my_orders：包含售后状态和 cancelled 状态 =====
DROP FUNCTION IF EXISTS shop_my_orders(TEXT);
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

-- ===== 11. 更新 admin_stats：添加黑名单和售后计数 =====
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
  SELECT count(*) INTO v_unused FROM redemption_codes WHERE used = false;
  SELECT count(*) INTO v_used FROM redemption_codes WHERE used = true;
  SELECT count(*) INTO v_redemptions FROM redemptions;
  SELECT count(*) INTO v_free FROM device_codes WHERE claimed = false;
  SELECT count(*) INTO v_claimed FROM device_codes WHERE claimed = true;
  SELECT count(*) INTO v_char_unused FROM redemption_codes WHERE used = false AND pool = 'character';
  SELECT count(*) INTO v_weapon_unused FROM redemption_codes WHERE used = false AND pool = 'weapon';
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

-- ===== 12. RLS 策略补充 =====
DROP POLICY IF EXISTS "blacklist_insert" ON blacklist;
DROP POLICY IF EXISTS "blacklist_update" ON blacklist;
DROP POLICY IF EXISTS "blacklist_delete" ON blacklist;
-- 黑名单的写操作通过 SECURITY DEFINER 函数执行，不需要额外 RLS

DROP POLICY IF EXISTS "after_sales_update" ON after_sales;
DROP POLICY IF EXISTS "after_sales_delete" ON after_sales;
-- 售后的写操作通过 SECURITY DEFINER 函数执行

-- ===== 完成 =====
