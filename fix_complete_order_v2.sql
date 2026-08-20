-- ============================================
-- 修复 admin_complete_order 的 redemptions 表冲突
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- 1. 删除旧的 (device_code, gid) 唯一约束（这是冲突根源）
ALTER TABLE redemptions DROP CONSTRAINT IF EXISTS redemptions_device_gid_key;

-- 2. 清理重复数据后添加 (device_code, product_code) 唯一约束
DELETE FROM redemptions a USING redemptions b
WHERE a.id > b.id AND a.device_code = b.device_code AND a.product_code = b.product_code;

-- 删除可能存在的旧约束
ALTER TABLE redemptions DROP CONSTRAINT IF EXISTS redemptions_device_product_key;

ALTER TABLE redemptions ADD CONSTRAINT redemptions_device_product_key
UNIQUE (device_code, product_code);

-- 3. 重写 admin_complete_order（修复 gid 冲突 + 自动解锁）
CREATE OR REPLACE FUNCTION admin_complete_order(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_order RECORD;
  v_oc RECORD;
  v_prod RECORD;
  v_invoice TEXT := '';
  v_code_text TEXT := '';
  v_code_count INTEGER;
  v_item_count INTEGER;
  v_gid TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;

  -- 检查是否所有付费商品都已分配兑换码
  SELECT count(*) INTO v_item_count FROM order_items WHERE order_items.order_id = p_order_id AND line_total > 0;
  SELECT count(*) INTO v_code_count FROM order_codes WHERE order_codes.order_id = p_order_id;
  IF v_code_count < v_item_count THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_all_codes_assigned', 'needed', v_item_count, 'assigned', v_code_count);
  END IF;

  -- 标记订单完成
  UPDATE orders SET status = 'completed', completed_at = now() WHERE orders.id = p_order_id;

  -- 处理兑换码
  FOR v_oc IN SELECT * FROM order_codes WHERE order_codes.order_id = p_order_id LOOP
    -- 标记兑换码已使用
    UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = v_order.device_code, product_code = v_oc.product_code
    WHERE code = v_oc.redemption_code AND used = false;

    -- 写入 redemptions 表
    INSERT INTO redemptions (device_code, product_code, redemption_code, password)
    VALUES (v_order.device_code, v_oc.product_code, v_oc.redemption_code, COALESCE(v_oc.password, ''))
    ON CONFLICT (device_code, product_code) DO NOTHING;

    -- 自动解锁：写入 unlocks 表
    SELECT * INTO v_prod FROM products WHERE code = v_oc.product_code;
    IF FOUND THEN
      v_gid := v_prod.game_name || '-' || v_prod.ver || '-' ||
        CASE
          WHEN v_prod.category = 'character' THEN '角色'
          WHEN v_prod.game_group LIKE 'hsr%' THEN '光锥'
          WHEN v_prod.game_group LIKE 'zzz%' THEN '音擎'
          ELSE '武器'
        END;
      INSERT INTO unlocks (device_code, gid, pool, redemption_code)
      VALUES (v_order.device_code, v_gid, v_prod.category, v_oc.redemption_code)
      ON CONFLICT (device_code, gid) DO NOTHING;
    END IF;
  END LOOP;

  -- 生成发票
  v_invoice := '【二游情报铺 · 电子发票】' || E'\n';
  v_invoice := v_invoice || '订单号: #' || p_order_id || E'\n';
  v_invoice := v_invoice || '设备码: ' || v_order.device_code || E'\n';
  v_invoice := v_invoice || '支付方式: ' || COALESCE(v_order.payment_method, '现金') || E'\n';
  IF v_order.is_group_buy THEN v_invoice := v_invoice || '拼团订单: 是' || E'\n'; END IF;
  v_invoice := v_invoice || E'\n--- 商品明细 ---' || E'\n';

  FOR v_oc IN SELECT oi.product_name, oi.quantity, oi.unit_price, oi.line_total FROM order_items oi WHERE oi.order_id = p_order_id LOOP
    v_invoice := v_invoice || v_oc.product_name || ' ×' || v_oc.quantity;
    IF v_oc.line_total = 0 THEN
      v_invoice := v_invoice || ' (优惠)' || E'\n';
    ELSE
      v_invoice := v_invoice || ' = ' || v_oc.line_total || '元' || E'\n';
    END IF;
  END LOOP;

  v_invoice := v_invoice || E'\n合计: ' || v_order.total_price || '元' || E'\n';
  v_invoice := v_invoice || '完成时间: ' || to_char(now(), 'YYYY-MM-DD HH24:MI') || E'\n';
  v_invoice := v_invoice || E'\n感谢惠顾！';

  INSERT INTO inbox (device_code, order_id, type, title, content)
  VALUES (v_order.device_code, p_order_id, 'invoice', '订单 #' || p_order_id || ' 电子发票', v_invoice);

  FOR v_oc IN SELECT * FROM order_codes WHERE order_codes.order_id = p_order_id LOOP
    v_code_text := '商品: ' || (SELECT name FROM products WHERE code = v_oc.product_code) || E'\n';
    v_code_text := v_code_text || '兑换码: ' || v_oc.redemption_code || E'\n';
    IF v_oc.password IS NOT NULL AND v_oc.password != '' THEN
      v_code_text := v_code_text || '密码: ' || v_oc.password || E'\n\n';
    END IF;
    v_code_text := v_code_text || '请在「兑换」页面输入兑换码解锁。';
    INSERT INTO inbox (device_code, order_id, type, title, content)
    VALUES (v_order.device_code, p_order_id, 'code', v_oc.product_code || ' 兑换码', v_code_text);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'invoice', v_invoice);
END; $function$;

GRANT EXECUTE ON FUNCTION admin_complete_order(TEXT, INTEGER) TO anon;
