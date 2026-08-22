-- ============================================
-- 二游情报铺 v1.6 迁移
-- 1. 用户取消订单功能
-- 2. 拼团结束后自动设为不公开且不可再公开
-- 3. 管理员对已结束拼团限制操作
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- ===== 1. 用户取消订单 =====
CREATE OR REPLACE FUNCTION shop_cancel_order(p_device TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order RECORD;
  v_oc RECORD;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;
  IF v_order.device_code != p_device THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF v_order.status != 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_pending');
  END IF;
  -- 检查拼团是否已结束
  IF v_order.group_id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM order_groups WHERE id = v_order.group_id AND status IN ('ended', 'expired')) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_already_ended');
    END IF;
  END IF;
  -- 释放已分配的兑换码
  FOR v_oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    UPDATE redemption_codes SET used = false, used_at = NULL, used_by_device = NULL
    WHERE code = v_oc.redemption_code AND used = true AND used_by_device = p_device;
  END LOOP;
  -- 删除分配记录
  DELETE FROM order_codes WHERE order_id = p_order_id;
  -- 标记订单为已取消
  UPDATE orders SET status = 'cancelled', completed_at = now() WHERE id = p_order_id;
  -- 如果是拼团订单，从拼团组移除
  IF v_order.group_id IS NOT NULL THEN
    UPDATE orders SET group_id = NULL, is_group_buy = false WHERE id = p_order_id;
  END IF;
  RETURN jsonb_build_object('ok', true);
END; $$;
GRANT EXECUTE ON FUNCTION shop_cancel_order(TEXT, INTEGER) TO anon;

-- ===== 2. 更新 admin_end_group：结束后设为不公开且锁定 =====
CREATE OR REPLACE FUNCTION admin_end_group(p_secret TEXT, p_group_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_group RECORD;
  v_item_count INTEGER;
  v_device_count INTEGER;
  v_result TEXT;
  v_participant RECORD;
  v_msg TEXT;
  v_group_name TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT * INTO v_group FROM order_groups WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;
  IF v_group.status != 'pending' THEN RETURN jsonb_build_object('ok', false, 'error', 'group_already_ended'); END IF;

  SELECT count(DISTINCT p.game_name || '|' || p.ver) INTO v_item_count
  FROM order_items oi JOIN products p ON oi.product_code = p.code JOIN orders o ON oi.order_id = o.id
  WHERE o.group_id = p_group_id AND oi.line_total > 0;
  SELECT count(DISTINCT o.device_code) INTO v_device_count FROM orders o WHERE o.group_id = p_group_id;
  IF v_item_count > v_device_count THEN v_result := 'success'; ELSE v_result := 'failed'; END IF;
  v_group_name := COALESCE(NULLIF(v_group.name, ''), '拼团 #' || p_group_id);

  -- 结束拼团：设为不公开 + 锁定
  UPDATE order_groups SET status = 'ended', ended_at = now(), result = v_result, is_public = false WHERE id = p_group_id;

  FOR v_participant IN SELECT DISTINCT device_code FROM orders WHERE group_id = p_group_id LOOP
    IF v_result = 'success' THEN
      v_msg := '拼团「' || v_group_name || '」已结束' || E'\n\n' || '结果：拼团成功！' || E'\n' || '参与人数：' || v_device_count || ' 人' || E'\n' || '总商品数：' || v_item_count || ' 个' || E'\n\n' || '感谢参与，祝游戏愉快！';
    ELSE
      v_msg := '拼团「' || v_group_name || '」已结束' || E'\n\n' || '结果：拼团未成功' || E'\n' || '参与人数：' || v_device_count || ' 人' || E'\n' || '总商品数：' || v_item_count || ' 个' || E'\n\n' || '商品数未达到人数要求，拼团失败。';
    END IF;
    INSERT INTO inbox (device_code, order_id, type, title, content) VALUES (v_participant.device_code, NULL, 'group_result', '拼团结果通知', v_msg);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'result', v_result, 'item_count', v_item_count, 'device_count', v_device_count);
END; $$;
GRANT EXECUTE ON FUNCTION admin_end_group(TEXT, INTEGER) TO anon;

-- ===== 3. 更新 admin_set_group_public：禁止已结束拼团再公开 =====
CREATE OR REPLACE FUNCTION admin_set_group_public(p_secret TEXT, p_group_id INTEGER, p_public BOOLEAN)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_group RECORD;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT * INTO v_group FROM order_groups WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;
  IF v_group.status != 'pending' AND p_public = true THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_ended_cannot_public');
  END IF;
  UPDATE order_groups SET is_public = p_public, public_at = CASE WHEN p_public THEN now() ELSE NULL END WHERE id = p_group_id;
  RETURN jsonb_build_object('ok', true);
END; $$;
GRANT EXECUTE ON FUNCTION admin_set_group_public(TEXT, INTEGER, BOOLEAN) TO anon;

-- ===== 4. 更新 admin_add_to_group：允许对已结束拼团加入（仅限加入和踢除） =====
CREATE OR REPLACE FUNCTION admin_add_to_group(p_secret TEXT, p_order_id INTEGER, p_group_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order RECORD; v_group RECORD; v_dev_count INTEGER; v_group_name TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;
  SELECT * INTO v_group FROM order_groups WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;
  -- 允许 pending 和 ended 状态加入
  IF v_group.status = 'expired' THEN RETURN jsonb_build_object('ok', false, 'error', 'group_expired'); END IF;
  SELECT count(DISTINCT o.device_code) INTO v_dev_count FROM orders o WHERE o.group_id = p_group_id;
  IF v_dev_count >= 5 THEN IF NOT EXISTS (SELECT 1 FROM orders WHERE device_code = v_order.device_code AND group_id = p_group_id) THEN RETURN jsonb_build_object('ok', false, 'error', 'group_device_limit'); END IF; END IF;
  v_group_name := COALESCE(NULLIF(v_group.name, ''), '拼团 #' || p_group_id);
  UPDATE orders SET group_id = p_group_id, is_group_buy = true WHERE id = p_order_id;
  UPDATE order_items SET line_total = 0, unit_price = 0 WHERE order_id = p_order_id AND product_code IN (SELECT code FROM products p2 WHERE p2.category = 'weapon' AND EXISTS (SELECT 1 FROM order_items oi2 JOIN products p3 ON oi2.product_code = p3.code WHERE oi2.order_id = p_order_id AND p3.category = 'character' AND p3.game_group = p2.game_group AND oi2.line_total > 0)) AND line_total > 0;
  UPDATE orders SET total_price = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id) WHERE id = p_order_id;
  INSERT INTO inbox (device_code, order_id, type, title, content) VALUES (v_order.device_code, p_order_id, 'group_update', '拼团状态变更', '你的订单 #' || p_order_id || ' 已被管理员加入拼团「' || v_group_name || '」。' || E'\n\n' || '订单已转为拼团订单，价格已重新计算。');
  RETURN jsonb_build_object('ok', true);
END; $$;
GRANT EXECUTE ON FUNCTION admin_add_to_group(TEXT, INTEGER, INTEGER) TO anon;

-- ===== 5. 更新 admin_remove_from_group：允许对已结束拼团踢除 =====
CREATE OR REPLACE FUNCTION admin_remove_from_group(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_order RECORD; v_group RECORD; v_group_name TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;
  IF v_order.group_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_in_group'); END IF;
  SELECT * INTO v_group FROM order_groups WHERE id = v_order.group_id;
  -- 允许 pending 和 ended 状态踢除
  IF v_group.status = 'expired' THEN RETURN jsonb_build_object('ok', false, 'error', 'group_expired'); END IF;
  v_group_name := COALESCE(NULLIF(v_group.name, ''), '拼团 #' || v_order.group_id);
  UPDATE orders SET group_id = NULL, is_group_buy = false WHERE id = p_order_id;
  UPDATE order_items oi SET line_total = oi.unit_price WHERE oi.order_id = p_order_id AND oi.line_total = 0 AND oi.unit_price > 0;
  UPDATE order_items SET line_total = 0, unit_price = 0 WHERE order_id = p_order_id AND product_code IN (SELECT code FROM products p2 WHERE p2.category = 'weapon' AND EXISTS (SELECT 1 FROM order_items oi2 JOIN products p3 ON oi2.product_code = p3.code WHERE oi2.order_id = p_order_id AND p3.category = 'character' AND p3.game_group = p2.game_group AND oi2.line_total > 0)) AND line_total > 0;
  UPDATE orders SET total_price = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id) WHERE id = p_order_id;
  INSERT INTO inbox (device_code, order_id, type, title, content) VALUES (v_order.device_code, p_order_id, 'group_update', '拼团状态变更', '你的订单 #' || p_order_id || ' 已被管理员从拼团「' || v_group_name || '」中移除。' || E'\n\n' || '订单已转为普通订单，价格已重新计算。');
  RETURN jsonb_build_object('ok', true);
END; $$;
GRANT EXECUTE ON FUNCTION admin_remove_from_group(TEXT, INTEGER) TO anon;
