-- ============================================
-- 二游情报铺 v1.2 数据库迁移
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- ===== 1. 修复 admin_redemptions（password 列已不存在） =====
CREATE OR REPLACE FUNCTION admin_redemptions(p_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  rows jsonb;
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', r.id,
      'device_code', r.device_code,
      'product_code', r.product_code,
      'redemption_code', r.redemption_code,
      'gid', COALESCE(r.gid, ''),
      'pool', COALESCE(r.pool, ''),
      'redeemed_at', r.redeemed_at
    ) ORDER BY r.redeemed_at DESC
  ) INTO rows
  FROM redemptions r;
  RETURN jsonb_build_object('ok', true, 'redemptions', COALESCE(rows, '[]'::jsonb));
END;
$function$;

-- ===== 2. 一键已读函数 =====
CREATE OR REPLACE FUNCTION shop_mark_all_read(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
BEGIN
  UPDATE inbox SET is_read = true WHERE device_code = p_device AND is_read = false;
  RETURN jsonb_build_object('ok', true);
END; $function$;
GRANT EXECUTE ON FUNCTION shop_mark_all_read(TEXT) TO anon;

-- ===== 3. 自动分配兑换码（管理员确认订单时自动选取可用码） =====
CREATE OR REPLACE FUNCTION admin_auto_assign_and_complete(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_order RECORD;
  v_item RECORD;
  v_oc RECORD;
  v_prod RECORD;
  v_invoice TEXT := '';
  v_code_text TEXT := '';
  v_code_count INTEGER;
  v_item_count INTEGER;
  v_gid TEXT;
  v_pool TEXT;
  v_avail RECORD;
  v_pwd TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;
  IF v_order.status = 'completed' THEN RETURN jsonb_build_object('ok', false, 'error', 'already_completed'); END IF;

  -- 检查已分配数量
  SELECT count(*) INTO v_item_count FROM order_items WHERE order_id = p_order_id AND line_total > 0;
  SELECT count(*) INTO v_code_count FROM order_codes WHERE order_id = p_order_id;

  -- 自动为未分配的商品选取可用兑换码
  FOR v_item IN
    SELECT oi.product_code, oi.product_name
    FROM order_items oi
    WHERE oi.order_id = p_order_id AND oi.line_total > 0
    AND NOT EXISTS (SELECT 1 FROM order_codes oc WHERE oc.order_id = p_order_id AND oc.product_code = oi.product_code)
  LOOP
    -- 获取该商品的 pool
    SELECT category INTO v_pool FROM products WHERE code = v_item.product_code;
    IF v_pool IS NULL THEN v_pool := 'weapon'; END IF;

    -- 找一个同 pool 的可用兑换码
    SELECT * INTO v_avail FROM redemption_codes WHERE used = false AND pool = v_pool ORDER BY RANDOM() LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'no_available_codes', 'product', v_item.product_name, 'pool', v_pool);
    END IF;

    -- 计算密码
    v_pwd := derive_password(v_order.device_code, v_item.product_code);

    -- 删除旧分配（如果有）
    DELETE FROM order_codes WHERE order_id = p_order_id AND product_code = v_item.product_code;

    -- 写入分配记录
    INSERT INTO order_codes (order_id, redemption_code, product_code, password)
    VALUES (p_order_id, v_avail.code, v_item.product_code, COALESCE(v_pwd, ''));
  END LOOP;

  -- 重新检查
  SELECT count(*) INTO v_code_count FROM order_codes WHERE order_id = p_order_id;
  IF v_code_count < v_item_count THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_all_codes_assigned', 'needed', v_item_count, 'assigned', v_code_count);
  END IF;

  -- 标记订单完成
  UPDATE orders SET status = 'completed', completed_at = now() WHERE id = p_order_id;

  -- 处理兑换码
  FOR v_oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = v_order.device_code, product_code = v_oc.product_code
    WHERE code = v_oc.redemption_code AND used = false;

    INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool)
    VALUES (v_order.device_code, v_oc.product_code, v_oc.redemption_code,
      (SELECT game_name || '-' || ver || '-' || CASE WHEN category = 'character' THEN '角色' WHEN game_group LIKE 'hsr%' THEN '光锥' WHEN game_group LIKE 'zzz%' THEN '音擎' ELSE '武器' END FROM products WHERE code = v_oc.product_code),
      (SELECT category FROM products WHERE code = v_oc.product_code))
    ON CONFLICT DO NOTHING;

    -- 自动解锁
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

  FOR v_oc IN SELECT * FROM order_codes WHERE order_id = p_order_id LOOP
    v_code_text := '商品: ' || (SELECT name FROM products WHERE code = v_oc.product_code) || E'\n';
    v_code_text := v_code_text || '兑换码: ' || v_oc.redemption_code || E'\n';
    IF v_oc.password IS NOT NULL AND v_oc.password != '' THEN
      v_code_text := v_code_text || '密码: ' || v_oc.password || E'\n\n';
    END IF;
    v_code_text := v_code_text || '请在「兑换」页面输入兑换码解锁。';
    INSERT INTO inbox (device_code, order_id, type, title, content)
    VALUES (v_order.device_code, p_order_id, 'code', v_oc.product_code || ' 兑换码', v_code_text);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'invoice', v_invoice, 'auto_assigned', true);
END; $function$;
GRANT EXECUTE ON FUNCTION admin_auto_assign_and_complete(TEXT, INTEGER) TO anon;

-- ===== 4. 按 pool 生成兑换码 =====
CREATE OR REPLACE FUNCTION admin_generate_codes(p_secret text, p_count int DEFAULT 50, p_pool text DEFAULT 'weapon')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  new_codes text[] := '{}';
  v_code text;
  i int;
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF p_count < 1 OR p_count > 500 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'count must be 1-500');
  END IF;
  FOR i IN 1..p_count LOOP
    LOOP
      v_code := substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) || '-' ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1);
      EXIT WHEN NOT EXISTS (SELECT 1 FROM redemption_codes WHERE code = v_code);
    END LOOP;
    INSERT INTO redemption_codes (code, used, pool) VALUES (v_code, false, p_pool);
    new_codes := array_append(new_codes, v_code);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'codes', to_jsonb(new_codes), 'count', p_count, 'pool', p_pool);
END;
$function$;

-- ===== 5. 按 pool 分类查询可用兑换码 =====
CREATE OR REPLACE FUNCTION admin_unused_codes(p_secret text, p_pool text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  codes jsonb;
  total int;
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF p_pool IS NOT NULL THEN
    SELECT jsonb_agg(code ORDER BY code), count(*)
    INTO codes, total
    FROM redemption_codes WHERE used = false AND pool = p_pool;
  ELSE
    SELECT jsonb_agg(code ORDER BY code), count(*)
    INTO codes, total
    FROM redemption_codes WHERE used = false;
  END IF;
  RETURN jsonb_build_object('ok', true, 'codes', COALESCE(codes, '[]'::jsonb), 'total', COALESCE(total, 0));
END;
$function$;

-- ===== 6. 统计增加按 pool 分类的可用码数量 =====
CREATE OR REPLACE FUNCTION admin_stats(p_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  unused_codes int;
  used_codes int;
  total_devices int;
  claimed_devices int;
  total_redeem int;
  char_unused int;
  weapon_unused int;
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT count(*) FILTER (WHERE used = false), count(*) FILTER (WHERE used = true)
  INTO unused_codes, used_codes FROM redemption_codes;
  SELECT count(*), count(*) FILTER (WHERE claimed = true)
  INTO total_devices, claimed_devices FROM device_codes;
  SELECT count(*) INTO total_redeem FROM redemptions;
  SELECT count(*) INTO char_unused FROM redemption_codes WHERE used = false AND pool = 'character';
  SELECT count(*) INTO weapon_unused FROM redemption_codes WHERE used = false AND pool = 'weapon';
  RETURN jsonb_build_object('ok', true,
    'unused_codes', unused_codes,
    'used_codes', used_codes,
    'total_devices', total_devices,
    'claimed_devices', claimed_devices,
    'free_devices', total_devices - claimed_devices,
    'total_redemptions', total_redeem,
    'char_unused', char_unused,
    'weapon_unused', weapon_unused);
END;
$function$;
