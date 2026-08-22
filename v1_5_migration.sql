-- ============================================
-- 二游情报铺 v1.5 迁移
-- 拼团机制优化：
--   1. 拼团3天自动结束（到期触发）
--   2. 单人订单≥3商品视为个人拼团
--   3. 管理员后台管理拼团（踢人/加人+即时通知+重算价格）
--   4. 拼团结束通知所有参与者
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- ===== 0. order_groups 表增加字段 =====
ALTER TABLE order_groups ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE order_groups ADD COLUMN IF NOT EXISTS ended_at TIMESTAMPTZ;
ALTER TABLE order_groups ADD COLUMN IF NOT EXISTS result TEXT DEFAULT '';
-- result: '' = 进行中, 'success' = 成功, 'failed' = 失败, 'expired' = 超时结束

-- ===== 1. 重写 shop_create_group：设置3天过期时间 =====
CREATE OR REPLACE FUNCTION shop_create_group(p_device TEXT, p_name TEXT DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  dc RECORD;
  v_gid INTEGER;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;
  INSERT INTO order_groups (name, is_public, status, expires_at)
  VALUES (COALESCE(p_name, ''), true, 'pending', now() + interval '3 days')
  RETURNING id INTO v_gid;
  RETURN jsonb_build_object('ok', true, 'group_id', v_gid);
END; $function$;
GRANT EXECUTE ON FUNCTION shop_create_group(TEXT, TEXT) TO anon;

-- ===== 2. 重写 shop_submit_order：个人拼团 + 拼团结束通知 =====
DROP FUNCTION IF EXISTS shop_submit_order(TEXT, JSONB, INTEGER);

CREATE OR REPLACE FUNCTION shop_submit_order(p_device TEXT, p_items JSONB, p_group_id INTEGER DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  dc RECORD;
  v_oid INTEGER;
  v_item JSONB;
  v_prod RECORD;
  v_total INTEGER := 0;
  v_lt INTEGER;
  v_dev_count INTEGER;
  v_order_count INTEGER;
  v_group_item_count INTEGER;
  v_avail RECORD;
  v_gid TEXT;
  v_pwd TEXT;
  v_unlocked_gids TEXT[] := '{}';
  v_existing_unlock RECORD;
  v_my_item_count INTEGER := 0;
  v_is_personal_group BOOLEAN := false;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;

  -- 检查拼团组是否已过期或已结束
  IF p_group_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM order_groups
      WHERE id = p_group_id AND (status IN ('ended', 'expired') OR (expires_at IS NOT NULL AND expires_at < now()))
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_ended');
    END IF;

    SELECT count(DISTINCT o.device_code) INTO v_dev_count FROM orders o WHERE o.group_id = p_group_id;
    IF v_dev_count >= 5 THEN
      IF NOT EXISTS (SELECT 1 FROM orders WHERE device_code = p_device AND group_id = p_group_id) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'group_device_limit');
      END IF;
    END IF;
  END IF;

  -- 创建订单
  INSERT INTO orders (device_code, status, total_price, group_id, is_group_buy)
  VALUES (p_device, 'pending', 0, p_group_id, p_group_id IS NOT NULL)
  RETURNING id INTO v_oid;

  -- 插入订单项（限购1）+ 自动分配兑换码 + 自动解锁
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_prod FROM products WHERE code = (v_item->>'product_code');
    IF NOT FOUND THEN CONTINUE; END IF;

    v_lt := v_prod.price;
    v_my_item_count := v_my_item_count + 1;

    IF EXISTS (
      SELECT 1 FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      WHERE o.device_code = p_device AND oi.product_code = v_prod.code
    ) THEN
      v_lt := 0;
    END IF;

    INSERT INTO order_items (order_id, product_code, product_name, quantity, unit_price, line_total)
    VALUES (v_oid, v_prod.code, v_prod.name, 1, v_prod.price, v_lt);
    v_total := v_total + v_lt;

    -- 自动分配兑换码
    IF v_lt > 0 THEN
      SELECT * INTO v_avail FROM redemption_codes
      WHERE used = false AND pool = v_prod.category
      ORDER BY RANDOM() LIMIT 1;

      IF NOT FOUND THEN CONTINUE; END IF;

      v_pwd := derive_password(p_device, v_prod.code);
      INSERT INTO order_codes (order_id, redemption_code, product_code, password)
      VALUES (v_oid, v_avail.code, v_prod.code, COALESCE(v_pwd, ''));
      UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = p_device
      WHERE code = v_avail.code AND used = false;

      -- 自动解锁
      SELECT * INTO v_existing_unlock FROM unlocks WHERE device_code = p_device AND gid = (
        SELECT game_name || '-' || ver || '-' ||
          CASE
            WHEN category = 'character' THEN
              CASE WHEN game_group LIKE 'zzz%' THEN '代理人' ELSE '角色' END
            WHEN game_group LIKE 'hsr%' THEN '光锥'
            WHEN game_group LIKE 'zzz%' THEN '音擎'
            ELSE '武器'
          END
        FROM products WHERE code = v_prod.code
      );

      IF NOT FOUND THEN
        INSERT INTO unlocks (device_code, gid, pool, redemption_code)
        VALUES (
          p_device,
          (SELECT game_name || '-' || ver || '-' ||
            CASE
              WHEN category = 'character' THEN
                CASE WHEN game_group LIKE 'zzz%' THEN '代理人' ELSE '角色' END
              WHEN game_group LIKE 'hsr%' THEN '光锥'
              WHEN game_group LIKE 'zzz%' THEN '音擎'
              ELSE '武器'
            END
          FROM products WHERE code = v_prod.code),
          v_prod.category, v_avail.code
        ) ON CONFLICT (device_code, gid) DO NOTHING;

        INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool)
        VALUES (
          p_device, v_prod.code, v_avail.code,
          (SELECT game_name || '-' || ver || '-' ||
            CASE
              WHEN category = 'character' THEN
                CASE WHEN game_group LIKE 'zzz%' THEN '代理人' ELSE '角色' END
              WHEN game_group LIKE 'hsr%' THEN '光锥'
              WHEN game_group LIKE 'zzz%' THEN '音擎'
              ELSE '武器'
            END
          FROM products WHERE code = v_prod.code),
          v_prod.category
        ) ON CONFLICT DO NOTHING;

        v_unlocked_gids := array_append(v_unlocked_gids,
          (SELECT game_name || '-' || ver || '-' ||
            CASE
              WHEN category = 'character' THEN
                CASE WHEN game_group LIKE 'zzz%' THEN '代理人' ELSE '角色' END
              WHEN game_group LIKE 'hsr%' THEN '光锥'
              WHEN game_group LIKE 'zzz%' THEN '音擎'
              ELSE '武器'
            END
          FROM products WHERE code = v_prod.code)
        );
      END IF;
    END IF;
  END LOOP;

  -- 捆绑优惠：同游戏角色+武器，武器免费
  UPDATE order_items SET line_total = 0, unit_price = 0
  WHERE order_id = v_oid
  AND product_code IN (
    SELECT code FROM products p2
    WHERE p2.category = 'weapon'
    AND EXISTS (
      SELECT 1 FROM order_items oi2
      JOIN products p3 ON oi2.product_code = p3.code
      WHERE oi2.order_id = v_oid AND p3.category = 'character' AND p3.game_group = p2.game_group AND oi2.line_total > 0
    )
  )
  AND line_total > 0;

  -- 重算总价
  SELECT COALESCE(SUM(line_total), 0) INTO v_total FROM order_items WHERE order_id = v_oid;
  UPDATE orders SET total_price = v_total WHERE id = v_oid;

  -- 个人拼团判断：单笔订单商品数≥3，无拼团组时也视为个人拼团
  IF p_group_id IS NULL AND v_my_item_count >= 3 THEN
    v_is_personal_group := true;
    UPDATE orders SET is_group_buy = true WHERE id = v_oid;
  END IF;

  -- 拼团组商品数统计
  IF p_group_id IS NOT NULL THEN
    SELECT count(*) INTO v_order_count FROM orders WHERE group_id = p_group_id;
    SELECT count(DISTINCT p.game_name || '|' || p.ver) INTO v_group_item_count
    FROM order_items oi
    JOIN products p ON oi.product_code = p.code
    JOIN orders o ON oi.order_id = o.id
    WHERE o.group_id = p_group_id AND oi.line_total > 0;

    RETURN jsonb_build_object(
      'ok', true, 'order_id', v_oid, 'total', v_total,
      'group_ready', v_group_item_count >= 3,
      'order_count', v_order_count, 'item_count', v_group_item_count,
      'auto_assigned', true, 'unlocked_gids', to_jsonb(v_unlocked_gids),
      'personal_group', v_is_personal_group
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'order_id', v_oid, 'total', v_total,
    'auto_assigned', true, 'unlocked_gids', to_jsonb(v_unlocked_gids),
    'personal_group', v_is_personal_group
  );
END; $function$;
GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;

-- ===== 3. 重写 shop_public_groups：返回商品数+过期时间 =====
CREATE OR REPLACE FUNCTION shop_public_groups()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
  -- 自动结束过期拼团
  UPDATE order_groups SET status = 'expired', ended_at = now()
  WHERE status = 'pending' AND expires_at IS NOT NULL AND expires_at < now();

  SELECT jsonb_agg(jsonb_build_object(
    'id', g.id, 'name', g.name,
    'order_count', (SELECT count(*) FROM orders o WHERE o.group_id = g.id),
    'device_count', (SELECT count(DISTINCT o.device_code) FROM orders o WHERE o.group_id = g.id),
    'item_count', (
      SELECT count(DISTINCT p.game_name || '|' || p.ver)
      FROM order_items oi
      JOIN products p ON oi.product_code = p.code
      JOIN orders o ON oi.order_id = o.id
      WHERE o.group_id = g.id AND oi.line_total > 0
    ),
    'total_price', (SELECT COALESCE(SUM(o.total_price), 0) FROM orders o WHERE o.group_id = g.id),
    'expires_at', g.expires_at
  ) ORDER BY g.created_at DESC) INTO rows FROM order_groups g WHERE g.is_public = true AND g.status = 'pending';
  RETURN jsonb_build_object('ok', true, 'groups', COALESCE(rows, '[]'::jsonb));
END; $function$;
GRANT EXECUTE ON FUNCTION shop_public_groups() TO anon;

-- ===== 4. 拼团结束函数（管理员手动触发或定时触发） =====
CREATE OR REPLACE FUNCTION admin_end_group(p_secret TEXT, p_group_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
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

  -- 统计
  SELECT count(DISTINCT p.game_name || '|' || p.ver) INTO v_item_count
  FROM order_items oi
  JOIN products p ON oi.product_code = p.code
  JOIN orders o ON oi.order_id = o.id
  WHERE o.group_id = p_group_id AND oi.line_total > 0;

  SELECT count(DISTINCT o.device_code) INTO v_device_count FROM orders o WHERE o.group_id = p_group_id;

  -- 判断结果：商品数 > 参与人数 = 成功
  IF v_item_count > v_device_count THEN
    v_result := 'success';
  ELSE
    v_result := 'failed';
  END IF;

  v_group_name := COALESCE(NULLIF(v_group.name, ''), '拼团 #' || p_group_id);

  -- 更新拼团组状态
  UPDATE order_groups SET status = 'ended', ended_at = now(), result = v_result WHERE id = p_group_id;

  -- 向所有参与者发送通知
  FOR v_participant IN SELECT DISTINCT device_code FROM orders WHERE group_id = p_group_id LOOP
    IF v_result = 'success' THEN
      v_msg := '拼团「' || v_group_name || '」已结束' || E'\n\n';
      v_msg := v_msg || '结果：拼团成功！' || E'\n';
      v_msg := v_msg || '参与人数：' || v_device_count || ' 人' || E'\n';
      v_msg := v_msg || '总商品数：' || v_item_count || ' 个' || E'\n\n';
      v_msg := v_msg || '感谢参与，祝游戏愉快！';
    ELSE
      v_msg := '拼团「' || v_group_name || '」已结束' || E'\n\n';
      v_msg := v_msg || '结果：拼团未成功' || E'\n';
      v_msg := v_msg || '参与人数：' || v_device_count || ' 人' || E'\n';
      v_msg := v_msg || '总商品数：' || v_item_count || ' 个' || E'\n\n';
      v_msg := v_msg || '商品数未达到人数要求，拼团失败。';
    END IF;

    INSERT INTO inbox (device_code, order_id, type, title, content)
    VALUES (v_participant.device_code, NULL, 'group_result', '拼团结果通知', v_msg);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'result', v_result, 'item_count', v_item_count, 'device_count', v_device_count);
END; $function$;
GRANT EXECUTE ON FUNCTION admin_end_group(TEXT, INTEGER) TO anon;

-- ===== 5. 过期拼团自动结束检查（管理员每次打开后台时调用） =====
CREATE OR REPLACE FUNCTION admin_check_expired_groups(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_expired RECORD;
  v_count INTEGER := 0;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;

  FOR v_expired IN
    SELECT id FROM order_groups
    WHERE status = 'pending' AND expires_at IS NOT NULL AND expires_at < now()
  LOOP
    -- 调用结束函数（但不用 admin 密钥，因为这是内部调用）
    UPDATE order_groups SET status = 'expired', ended_at = now(), result = 'expired' WHERE id = v_expired.id;

    -- 向参与者发送过期通知
    INSERT INTO inbox (device_code, order_id, type, title, content)
    SELECT DISTINCT o.device_code, NULL, 'group_result', '拼团超时通知',
      '拼团「' || COALESCE(NULLIF(g.name, ''), '拼团 #' || g.id) || '」已超时结束（3天到期）' || E'\n\n' ||
      '拼团未在有效期内达到成团条件，已自动结束。'
    FROM orders o
    JOIN order_groups g ON g.id = o.group_id
    WHERE o.group_id = v_expired.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'ended_count', v_count);
END; $function$;
GRANT EXECUTE ON FUNCTION admin_check_expired_groups(TEXT) TO anon;

-- ===== 6. 管理员踢出订单（从拼团中移除）+ 即时通知 =====
CREATE OR REPLACE FUNCTION admin_remove_from_group(p_secret TEXT, p_order_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_order RECORD;
  v_group RECORD;
  v_group_name TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;

  IF v_order.group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_in_group');
  END IF;

  SELECT * INTO v_group FROM order_groups WHERE id = v_order.group_id;
  v_group_name := COALESCE(NULLIF(v_group.name, ''), '拼团 #' || v_order.group_id);

  -- 从拼团组移除
  UPDATE orders SET group_id = NULL, is_group_buy = false WHERE id = p_order_id;

  -- 重新计算该订单的价格（移除捆绑优惠）
  UPDATE order_items oi SET line_total = oi.unit_price
  WHERE oi.order_id = p_order_id AND oi.line_total = 0 AND oi.unit_price > 0;

  -- 重新检查捆绑优惠
  UPDATE order_items SET line_total = 0, unit_price = 0
  WHERE order_id = p_order_id
  AND product_code IN (
    SELECT code FROM products p2
    WHERE p2.category = 'weapon'
    AND EXISTS (
      SELECT 1 FROM order_items oi2
      JOIN products p3 ON oi2.product_code = p3.code
      WHERE oi2.order_id = p_order_id AND p3.category = 'character' AND p3.game_group = p2.game_group AND oi2.line_total > 0
    )
  )
  AND line_total > 0;

  UPDATE orders SET total_price = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id)
  WHERE id = p_order_id;

  -- 发送通知给被踢出的用户
  INSERT INTO inbox (device_code, order_id, type, title, content)
  VALUES (v_order.device_code, p_order_id, 'group_update', '拼团状态变更',
    '你的订单 #' || p_order_id || ' 已被管理员从拼团「' || v_group_name || '」中移除。' || E'\n\n' ||
    '订单已转为普通订单，价格已重新计算。');

  RETURN jsonb_build_object('ok', true);
END; $function$;
GRANT EXECUTE ON FUNCTION admin_remove_from_group(TEXT, INTEGER) TO anon;

-- ===== 7. 管理员将订单加入拼团 + 即时通知 =====
CREATE OR REPLACE FUNCTION admin_add_to_group(p_secret TEXT, p_order_id INTEGER, p_group_id INTEGER)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_order RECORD;
  v_group RECORD;
  v_dev_count INTEGER;
  v_group_name TEXT;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order_not_found'); END IF;

  SELECT * INTO v_group FROM order_groups WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;
  IF v_group.status != 'pending' THEN RETURN jsonb_build_object('ok', false, 'error', 'group_ended'); END IF;

  SELECT count(DISTINCT o.device_code) INTO v_dev_count FROM orders o WHERE o.group_id = p_group_id;
  IF v_dev_count >= 5 THEN
    IF NOT EXISTS (SELECT 1 FROM orders WHERE device_code = v_order.device_code AND group_id = p_group_id) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_device_limit', 'max', 5, 'current', v_dev_count);
    END IF;
  END IF;

  v_group_name := COALESCE(NULLIF(v_group.name, ''), '拼团 #' || p_group_id);

  UPDATE orders SET group_id = p_group_id, is_group_buy = true WHERE id = p_order_id;

  -- 重新计算捆绑优惠
  UPDATE order_items SET line_total = 0, unit_price = 0
  WHERE order_id = p_order_id
  AND product_code IN (
    SELECT code FROM products p2
    WHERE p2.category = 'weapon'
    AND EXISTS (
      SELECT 1 FROM order_items oi2
      JOIN products p3 ON oi2.product_code = p3.code
      WHERE oi2.order_id = p_order_id AND p3.category = 'character' AND p3.game_group = p2.game_group AND oi2.line_total > 0
    )
  )
  AND line_total > 0;

  UPDATE orders SET total_price = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order_id)
  WHERE id = p_order_id;

  -- 发送通知
  INSERT INTO inbox (device_code, order_id, type, title, content)
  VALUES (v_order.device_code, p_order_id, 'group_update', '拼团状态变更',
    '你的订单 #' || p_order_id || ' 已被管理员加入拼团「' || v_group_name || '」。' || E'\n\n' ||
    '订单已转为拼团订单，价格已重新计算。');

  RETURN jsonb_build_object('ok', true);
END; $function$;
GRANT EXECUTE ON FUNCTION admin_add_to_group(TEXT, INTEGER, INTEGER) TO anon;

-- ===== 8. 更新 admin_groups：返回商品数+状态+过期时间 =====
CREATE OR REPLACE FUNCTION admin_groups(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
  IF p_secret != 'Qwert12345' THEN RETURN jsonb_build_object('ok', false, 'error', 'unauthorized'); END IF;

  -- 自动结束过期的拼团
  PERFORM admin_check_expired_groups(p_secret);

  SELECT jsonb_agg(jsonb_build_object(
    'id', g.id, 'name', g.name, 'is_public', g.is_public,
    'public_at', g.public_at, 'status', g.status, 'result', g.result,
    'created_at', g.created_at, 'expires_at', g.expires_at, 'ended_at', g.ended_at,
    'order_count', (SELECT count(*) FROM orders o WHERE o.group_id = g.id),
    'device_count', (SELECT count(DISTINCT o.device_code) FROM orders o WHERE o.group_id = g.id),
    'item_count', (
      SELECT count(DISTINCT p.game_name || '|' || p.ver)
      FROM order_items oi
      JOIN products p ON oi.product_code = p.code
      JOIN orders o ON oi.order_id = o.id
      WHERE o.group_id = g.id AND oi.line_total > 0
    ),
    'total_price', (SELECT COALESCE(SUM(o.total_price), 0) FROM orders o WHERE o.group_id = g.id)
  ) ORDER BY g.created_at DESC) INTO rows FROM order_groups g;
  RETURN jsonb_build_object('ok', true, 'groups', COALESCE(rows, '[]'::jsonb));
END; $function$;
GRANT EXECUTE ON FUNCTION admin_groups(TEXT) TO anon;

-- ===== 9. 用户端查询自己的拼团状态 =====
CREATE OR REPLACE FUNCTION shop_my_groups(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'id', g.id, 'name', g.name, 'status', g.status, 'result', g.result,
    'created_at', g.created_at, 'expires_at', g.expires_at, 'ended_at', g.ended_at,
    'order_count', (SELECT count(*) FROM orders o WHERE o.group_id = g.id),
    'device_count', (SELECT count(DISTINCT o.device_code) FROM orders o WHERE o.group_id = g.id),
    'item_count', (
      SELECT count(DISTINCT p.game_name || '|' || p.ver)
      FROM order_items oi
      JOIN products p ON oi.product_code = p.code
      JOIN orders o ON oi.order_id = o.id
      WHERE o.group_id = g.id AND oi.line_total > 0
    ),
    'total_price', (SELECT COALESCE(SUM(o.total_price), 0) FROM orders o WHERE o.group_id = g.id),
    'my_orders', (SELECT jsonb_agg(o.id) FROM orders o WHERE o.group_id = g.id AND o.device_code = p_device)
  ) ORDER BY g.created_at DESC) INTO rows
  FROM order_groups g
  WHERE g.id IN (SELECT DISTINCT group_id FROM orders WHERE device_code = p_device AND group_id IS NOT NULL);
  RETURN jsonb_build_object('ok', true, 'groups', COALESCE(rows, '[]'::jsonb));
END; $function$;
GRANT EXECUTE ON FUNCTION shop_my_groups(TEXT) TO anon;
