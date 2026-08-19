-- ============================================
-- 二游情报铺 管理员后台 RPC 函数
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- 管理员密码（SHA256 哈希存储）
-- 密码: Qwert12345
-- 用 pgcrypto 的 crypt 不方便，直接用简单比对（函数内部硬编码比对）

-- 0. 验证管理员密码
CREATE OR REPLACE FUNCTION admin_verify(p_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_admin_secret');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- 1. 获取所有未使用的兑换码
CREATE OR REPLACE FUNCTION admin_unused_codes(p_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  codes jsonb;
  total int;
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT jsonb_agg(code ORDER BY code), count(*)
  INTO codes, total
  FROM redemption_codes WHERE used = false;
  RETURN jsonb_build_object('ok', true, 'codes', COALESCE(codes, '[]'::jsonb), 'total', total);
END;
$$;

-- 2. 获取所有已使用的兑换码（含使用详情）
CREATE OR REPLACE FUNCTION admin_used_codes(p_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  rows jsonb;
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT jsonb_agg(
    jsonb_build_object(
      'code', rc.code,
      'used_at', rc.used_at,
      'device', rc.used_by_device,
      'product', rc.product_code
    ) ORDER BY rc.used_at DESC
  ) INTO rows
  FROM redemption_codes rc WHERE rc.used = true;
  RETURN jsonb_build_object('ok', true, 'codes', COALESCE(rows, '[]'::jsonb));
END;
$$;

-- 3. 获取所有兑换记录
CREATE OR REPLACE FUNCTION admin_redemptions(p_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
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
      'password', r.password,
      'redeemed_at', r.redeemed_at
    ) ORDER BY r.redeemed_at DESC
  ) INTO rows
  FROM redemptions r;
  RETURN jsonb_build_object('ok', true, 'redemptions', COALESCE(rows, '[]'::jsonb));
END;
$$;

-- 4. 获取所有设备码状态
CREATE OR REPLACE FUNCTION admin_device_codes(p_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  rows jsonb;
  claimed_count int;
  free_count int;
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT count(*) FILTER (WHERE claimed = true),
         count(*) FILTER (WHERE claimed = false)
  INTO claimed_count, free_count
  FROM device_codes;
  SELECT jsonb_agg(
    jsonb_build_object(
      'code', d.code,
      'claimed', d.claimed,
      'fingerprint', d.fingerprint,
      'assigned_at', d.assigned_at
    ) ORDER BY d.claimed DESC, d.assigned_at DESC NULLS LAST
  ) INTO rows
  FROM device_codes d;
  RETURN jsonb_build_object('ok', true,
    'codes', COALESCE(rows, '[]'::jsonb),
    'claimed', claimed_count,
    'free', free_count);
END;
$$;

-- 5. 生成新兑换码
CREATE OR REPLACE FUNCTION admin_generate_codes(p_secret text, p_count int DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  new_codes text[] := '{}';
  code text;
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
      code := substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) || '-' ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1);
      EXIT WHEN NOT EXISTS (SELECT 1 FROM redemption_codes WHERE redemption_codes.code = code);
    END LOOP;
    INSERT INTO redemption_codes (code, used) VALUES (code, false);
    new_codes := array_append(new_codes, code);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'codes', to_jsonb(new_codes), 'count', p_count);
END;
$$;

-- 6. 生成新设备码
CREATE OR REPLACE FUNCTION admin_generate_device_codes(p_secret text, p_count int DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  new_codes text[] := '{}';
  code text;
  i int;
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF p_count < 1 OR p_count > 200 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'count must be 1-200');
  END IF;
  FOR i IN 1..p_count LOOP
    LOOP
      code := substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) || '-' ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1) ||
              substr(chars, (floor(random() * 32) + 1)::int, 1);
      EXIT WHEN NOT EXISTS (SELECT 1 FROM device_codes WHERE device_codes.code = code);
    END LOOP;
    INSERT INTO device_codes (code, claimed) VALUES (code, false);
    new_codes := array_append(new_codes, code);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'codes', to_jsonb(new_codes), 'count', p_count);
END;
$$;

-- 7. 统计概览
CREATE OR REPLACE FUNCTION admin_stats(p_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  unused_codes int;
  used_codes int;
  total_devices int;
  claimed_devices int;
  total_redeem int;
BEGIN
  IF p_secret != 'Qwert12345' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  SELECT count(*) FILTER (WHERE used = false), count(*) FILTER (WHERE used = true)
  INTO unused_codes, used_codes FROM redemption_codes;
  SELECT count(*), count(*) FILTER (WHERE claimed = true)
  INTO total_devices, claimed_devices FROM device_codes;
  SELECT count(*) INTO total_redeem FROM redemptions;
  RETURN jsonb_build_object('ok', true,
    'unused_codes', unused_codes,
    'used_codes', used_codes,
    'total_devices', total_devices,
    'claimed_devices', claimed_devices,
    'free_devices', total_devices - claimed_devices,
    'total_redemptions', total_redeem);
END;
$$;
