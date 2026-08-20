-- ============================================
-- 二游情报铺 · 兑换码解锁系统迁移
-- 废除密码机制，改用一次性兑换码解锁库
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- ===== 1. 迁移兑换码池 =====
ALTER TABLE redemption_codes ADD COLUMN IF NOT EXISTS pool TEXT NOT NULL DEFAULT 'weapon';
UPDATE redemption_codes SET pool = 'character' WHERE code IN (
  '90W0-0U62','D3T8-Z1VI','5RWI-SN8L','07HS-DWEL','3BRU-5O1G','02VD-NXGC','3KEY-6TPZ','1DBK-NKJC','0ET5-ZR5Z'
);

-- ===== 2. 创建解锁记录表 =====
DROP TABLE IF EXISTS unlocks;
CREATE TABLE unlocks (
  id SERIAL PRIMARY KEY,
  device_code TEXT NOT NULL,
  gid TEXT NOT NULL,
  pool TEXT NOT NULL,
  redemption_code TEXT NOT NULL,
  unlocked_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(device_code, gid)
);
ALTER TABLE unlocks ENABLE ROW LEVEL SECURITY;

-- ===== 3. 改造兑换记录表 =====
ALTER TABLE redemptions ADD COLUMN IF NOT EXISTS gid TEXT NOT NULL DEFAULT '';
ALTER TABLE redemptions ADD COLUMN IF NOT EXISTS pool TEXT NOT NULL DEFAULT '';
ALTER TABLE redemptions DROP COLUMN IF EXISTS password;

-- 迁移已有数据
UPDATE redemptions SET gid = '崩坏星穹铁道-4.5-角色', pool = 'character' WHERE product_code = 'HSR45CHAR';
UPDATE redemptions SET gid = '崩坏星穹铁道-4.5-光锥', pool = 'weapon' WHERE product_code = 'HSR45LC';
UPDATE redemptions SET gid = '原神-7.1-角色', pool = 'character' WHERE product_code = 'GI71CHAR';
UPDATE redemptions SET gid = '原神-7.1-武器', pool = 'weapon' WHERE product_code = 'GI71WPN';
UPDATE redemptions SET gid = '异环-1.3-角色', pool = 'character' WHERE product_code = 'ER13CHAR';
UPDATE redemptions SET gid = '异环-1.3-武器', pool = 'weapon' WHERE product_code = 'ER13WPN';
UPDATE redemptions SET gid = '绝区零-3.2-代理人', pool = 'character' WHERE product_code = 'ZZZ32CHAR';
UPDATE redemptions SET gid = '绝区零-3.2-音擎', pool = 'weapon' WHERE product_code = 'ZZZ32WPN';

-- 重建唯一约束
ALTER TABLE redemptions DROP CONSTRAINT IF EXISTS redemptions_device_code_product_code_key;
ALTER TABLE redemptions ADD CONSTRAINT redemptions_device_gid_key UNIQUE(device_code, gid);

-- 为已有兑换记录创建解锁条目
INSERT INTO unlocks (device_code, gid, pool, redemption_code, unlocked_at)
SELECT device_code, gid, pool, redemption_code, redeemed_at FROM redemptions WHERE gid != ''
ON CONFLICT DO NOTHING;

-- ===== 4. 更新商品名称（新格式） =====
UPDATE products SET name = '崩坏：星穹铁道 角色库 4.5', game_group = 'hsr45', game_name = '崩坏：星穹铁道', ver = '4.5', category = 'character', price = 5, group_price = 4 WHERE code = 'HSR45CHAR';
UPDATE products SET name = '崩坏：星穹铁道 光锥库 4.5', game_group = 'hsr45', game_name = '崩坏：星穹铁道', ver = '4.5', category = 'weapon', price = 2, group_price = 1 WHERE code = 'HSR45LC';
UPDATE products SET name = '原神 角色库 7.1', game_group = 'gi71', game_name = '原神', ver = '7.1', category = 'character', price = 5, group_price = 4 WHERE code = 'GI71CHAR';
UPDATE products SET name = '原神 武器库 7.1', game_group = 'gi71', game_name = '原神', ver = '7.1', category = 'weapon', price = 2, group_price = 1 WHERE code = 'GI71WPN';
UPDATE products SET name = '异环 角色库 1.3', game_group = 'er13', game_name = '异环', ver = '1.3', category = 'character', price = 5, group_price = 4 WHERE code = 'ER13CHAR';
UPDATE products SET name = '异环 武器库 1.3', game_group = 'er13', game_name = '异环', ver = '1.3', category = 'weapon', price = 2, group_price = 1 WHERE code = 'ER13WPN';
UPDATE products SET name = '绝区零 代理人库 3.2', game_group = 'zzz32', game_name = '绝区零', ver = '3.2', category = 'character', price = 5, group_price = 4 WHERE code = 'ZZZ32CHAR';
UPDATE products SET name = '绝区零 音擎库 3.2', game_group = 'zzz32', game_name = '绝区零', ver = '3.2', category = 'weapon', price = 2, group_price = 1 WHERE code = 'ZZZ32WPN';

-- 删除旧数据（price=0 的条目）
DELETE FROM products WHERE price = 0;

-- ===== 5. 新 RPC：查询设备已解锁的库 =====
CREATE OR REPLACE FUNCTION check_unlocks(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(gid) INTO rows FROM unlocks WHERE device_code = p_device;
  RETURN jsonb_build_object('ok', true, 'unlocked', COALESCE(rows, '[]'::jsonb));
END; $function$;

-- ===== 6. 重写兑换函数 =====
CREATE OR REPLACE FUNCTION do_redeem(p_device TEXT, p_gid TEXT, p_pool TEXT, p_redemption TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  dc RECORD;
  rc RECORD;
  existing RECORD;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device_code');
  END IF;
  SELECT * INTO existing FROM unlocks WHERE device_code = p_device AND gid = p_gid;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'already_redeemed', true);
  END IF;
  SELECT * INTO rc FROM redemption_codes WHERE code = p_redemption AND used = false AND pool = p_pool;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_or_used_code');
  END IF;
  UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = p_device WHERE id = rc.id;
  INSERT INTO unlocks (device_code, gid, pool, redemption_code) VALUES (p_device, p_gid, p_pool, p_redemption);
  INSERT INTO redemptions (device_code, product_code, redemption_code, gid, pool) VALUES (p_device, '', p_redemption, p_gid, p_pool) ON CONFLICT DO NOTHING;
  RETURN jsonb_build_object('ok', true, 'already_redeemed', false);
END; $function$;

-- ===== 7. 授权 =====
GRANT EXECUTE ON FUNCTION check_unlocks(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION do_redeem(TEXT, TEXT, TEXT, TEXT) TO anon;
