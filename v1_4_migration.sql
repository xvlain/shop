-- ============================================
-- 二游情报铺 v1.4 迁移
-- 1. 拼团机制优化：商品数取代单数作为成团条件
-- 2. 邮箱一键已读
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- ===== 1. 重写 shop_public_groups：返回商品数 =====
CREATE OR REPLACE FUNCTION shop_public_groups()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
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
    'total_price', (SELECT COALESCE(SUM(o.total_price), 0) FROM orders o WHERE o.group_id = g.id)
  ) ORDER BY g.created_at DESC) INTO rows FROM order_groups g WHERE g.is_public = true;
  RETURN jsonb_build_object('ok', true, 'groups', COALESCE(rows, '[]'::jsonb));
END; $function$;

-- ===== 2. 重写 shop_submit_order：用商品数判断成团 =====
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
BEGIN
  -- 验证设备码
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device');
  END IF;

  -- 如果加入拼团组，检查设备上限（最多5个不同设备）
  IF p_group_id IS NOT NULL THEN
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

  -- 插入订单项（限购：每个商品数量强制为1）
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_prod FROM products WHERE code = (v_item->>'product_code');
    IF NOT FOUND THEN CONTINUE; END IF;

    v_lt := v_prod.price;

    -- 检查是否已购买过该商品
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

    -- 自动分配兑换码（仅对付费商品）
    IF v_lt > 0 THEN
      SELECT * INTO v_avail FROM redemption_codes
      WHERE used = false AND pool = v_prod.category
      ORDER BY RANDOM() LIMIT 1;

      IF NOT FOUND THEN
        CONTINUE;
      END IF;

      v_pwd := derive_password(p_device, v_prod.code);

      INSERT INTO order_codes (order_id, redemption_code, product_code, password)
      VALUES (v_oid, v_avail.code, v_prod.code, COALESCE(v_pwd, ''));

      UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = p_device
      WHERE code = v_avail.code AND used = false;

      -- 自动解锁
      SELECT * INTO v_existing_unlock FROM unlocks WHERE device_code = p_device AND gid = (
        SELECT game_name || '-' || ver || '-' ||
          CASE
            WHEN category = 'character' THEN '角色'
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
              WHEN category = 'character' THEN '角色'
              WHEN game_group LIKE 'hsr%' THEN '光锥'
              WHEN game_group LIKE 'zzz%' THEN '音擎'
              ELSE '武器'
            END
          FROM products WHERE code = v_prod.code),
          v_prod.category,
          v_avail.code
        ) ON CONFLICT (device_code, gid) DO NOTHING;

        INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool)
        VALUES (
          p_device,
          v_prod.code,
          v_avail.code,
          (SELECT game_name || '-' || ver || '-' ||
            CASE
              WHEN category = 'character' THEN '角色'
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
              WHEN category = 'character' THEN '角色'
              WHEN game_group LIKE 'hsr%' THEN '光锥'
              WHEN game_group LIKE 'zzz%' THEN '音擎'
              ELSE '武器'
            END
          FROM products WHERE code = v_prod.code)
        );
      END IF;
    END IF;
  END LOOP;

  -- 捆绑优惠：同游戏同版本角色+武器 → 武器免费
  UPDATE order_items SET line_total = 0, unit_price = 0
  WHERE order_items.order_id = v_oid
    AND product_code IN (
      SELECT code FROM products p2
      WHERE p2.category = 'weapon'
        AND EXISTS (
          SELECT 1 FROM order_items oi2
          JOIN products p3 ON oi2.product_code = p3.code
          WHERE oi2.order_id = v_oid
            AND p3.category = 'character'
            AND p3.game_group = p2.game_group
            AND oi2.line_total > 0
        )
    )
    AND order_items.line_total > 0;

  -- 重算总价
  SELECT COALESCE(SUM(order_items.line_total), 0) INTO v_total FROM order_items WHERE order_items.order_id = v_oid;
  UPDATE orders SET total_price = v_total WHERE id = v_oid;

  -- 拼团：用商品数判断成团（同游戏同版本角色+武器算1个商品）
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
      'order_count', v_order_count,
      'item_count', v_group_item_count,
      'auto_assigned', true, 'unlocked_gids', to_jsonb(v_unlocked_gids)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'order_id', v_oid, 'total', v_total,
    'auto_assigned', true, 'unlocked_gids', to_jsonb(v_unlocked_gids)
  );
END; $function$;

GRANT EXECUTE ON FUNCTION shop_submit_order(TEXT, JSONB, INTEGER) TO anon;

-- ===== 3. 重写 admin_orders_ready：用商品数判断 =====
CREATE OR REPLACE FUNCTION admin_orders_ready(p_secret TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
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
  ) ORDER BY o.created_at DESC) INTO rows FROM orders o
  WHERE o.status = 'pending' AND (
    o.is_group_buy = false
    OR (o.group_id IS NOT NULL AND (
      SELECT count(DISTINCT p.game_name || '|' || p.ver)
      FROM order_items oi
      JOIN products p ON oi.product_code = p.code
      JOIN orders o2 ON oi.order_id = o2.id
      WHERE o2.group_id = o.group_id AND oi.line_total > 0
    ) >= 3)
  );
  RETURN jsonb_build_object('ok', true, 'orders', COALESCE(rows, '[]'::jsonb));
END; $function$;

-- ===== 4. 邮箱一键已读 =====
CREATE OR REPLACE FUNCTION shop_inbox_mark_read(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_count INTEGER;
BEGIN
  UPDATE inbox SET is_read = true WHERE device_code = p_device AND is_read = false;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'marked', v_count);
END; $$;
GRANT EXECUTE ON FUNCTION shop_inbox_mark_read(TEXT) TO anon;
