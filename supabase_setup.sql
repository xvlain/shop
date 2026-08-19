-- ============================================
-- 二游情报铺 Supabase 数据库初始化脚本
-- 在 Supabase SQL Editor 中一次性执行
-- ============================================

-- 启用 pgcrypto（提供 digest 函数）
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ===== 1. 创建表 =====

CREATE TABLE IF NOT EXISTS device_codes (
  id SERIAL PRIMARY KEY,
  code TEXT UNIQUE NOT NULL,
  claimed BOOLEAN DEFAULT false,
  fingerprint TEXT,
  assigned_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS redemption_codes (
  id SERIAL PRIMARY KEY,
  code TEXT UNIQUE NOT NULL,
  used BOOLEAN DEFAULT false,
  used_at TIMESTAMPTZ,
  used_by_device TEXT,
  product_code TEXT
);

CREATE TABLE IF NOT EXISTS products (
  code TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  base_secret TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS redemptions (
  id SERIAL PRIMARY KEY,
  device_code TEXT NOT NULL,
  product_code TEXT NOT NULL,
  redemption_code TEXT NOT NULL,
  password TEXT NOT NULL,
  redeemed_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(device_code, product_code)
);

-- ===== 2. 启用 RLS =====

ALTER TABLE device_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE redemption_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE redemptions ENABLE ROW LEVEL SECURITY;

-- ===== 3. 密码派生函数 =====

CREATE OR REPLACE FUNCTION derive_password(device TEXT, product TEXT)
RETURNS TEXT AS $$
DECLARE
  secret TEXT;
  h1 TEXT;
  h2 TEXT;
BEGIN
  SELECT base_secret INTO secret FROM products WHERE code = product;
  IF secret IS NULL THEN RETURN NULL; END IF;
  h1 := encode(digest(device || ':' || product || ':' || secret, 'sha256'), 'hex');
  h2 := encode(digest(product || ':' || device || ':' || secret, 'sha256'), 'hex');
  RETURN upper(substr(h1, 1, 5)) || '-' || upper(substr(h2, 1, 5));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ===== 4. 设备码认领函数 =====

CREATE OR REPLACE FUNCTION claim_device_code(fp TEXT)
RETURNS JSONB AS $$
DECLARE
  dc RECORD;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE fingerprint = fp AND claimed = true LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'device_code', dc.code, 'already_assigned', true);
  END IF;

  SELECT * INTO dc FROM device_codes WHERE claimed = false ORDER BY RANDOM() LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_device_codes_available');
  END IF;

  UPDATE device_codes SET claimed = true, fingerprint = fp, assigned_at = now() WHERE id = dc.id;
  RETURN jsonb_build_object('ok', true, 'device_code', dc.code, 'already_assigned', false);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ===== 5. 兑换函数 =====

CREATE OR REPLACE FUNCTION do_redeem(p_device TEXT, p_product TEXT, p_redemption TEXT)
RETURNS JSONB AS $$
DECLARE
  dc RECORD;
  rc RECORD;
  pr RECORD;
  existing RECORD;
  new_pwd TEXT;
BEGIN
  SELECT * INTO dc FROM device_codes WHERE code = p_device AND claimed = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_device_code');
  END IF;

  SELECT * INTO pr FROM products WHERE code = p_product;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_product_code');
  END IF;

  SELECT * INTO rc FROM redemption_codes WHERE code = p_redemption AND used = false;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_or_used_redemption_code');
  END IF;

  SELECT * INTO existing FROM redemptions WHERE device_code = p_device AND product_code = p_product;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'already_redeemed', true, 'password', existing.password);
  END IF;

  new_pwd := derive_password(p_device, p_product);

  UPDATE redemption_codes SET used = true, used_at = now(), used_by_device = p_device, product_code = p_product WHERE id = rc.id;

  INSERT INTO redemptions (device_code, product_code, redemption_code, password) VALUES (p_device, p_product, p_redemption, new_pwd);

  RETURN jsonb_build_object('ok', true, 'already_redeemed', false, 'password', new_pwd);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ===== 6. 插入设备码 =====

INSERT INTO device_codes (code) VALUES ('0S1L-YB2C');
INSERT INTO device_codes (code) VALUES ('1CTX-HKWB');
INSERT INTO device_codes (code) VALUES ('47GA-XKRI');
INSERT INTO device_codes (code) VALUES ('5AY5-AON1');
INSERT INTO device_codes (code) VALUES ('5HVS-XUY0');
INSERT INTO device_codes (code) VALUES ('7PYL-F2Q2');
INSERT INTO device_codes (code) VALUES ('BQC1-4OXK');
INSERT INTO device_codes (code) VALUES ('C89P-JPGS');
INSERT INTO device_codes (code) VALUES ('DVNT-XUR9');
INSERT INTO device_codes (code) VALUES ('FVPD-XNY0');
INSERT INTO device_codes (code) VALUES ('H06G-032U');
INSERT INTO device_codes (code) VALUES ('M67Z-8F1A');
INSERT INTO device_codes (code) VALUES ('N94Q-I41P');
INSERT INTO device_codes (code) VALUES ('OW07-BKC6');
INSERT INTO device_codes (code) VALUES ('QECX-ZX2G');
INSERT INTO device_codes (code) VALUES ('T440-HIAN');
INSERT INTO device_codes (code) VALUES ('T9DE-AP9J');
INSERT INTO device_codes (code) VALUES ('VRUT-I0IU');
INSERT INTO device_codes (code) VALUES ('Y9FA-IMUD');
INSERT INTO device_codes (code) VALUES ('Z95B-NYTJ');

-- ===== 7. 插入兑换码 =====

INSERT INTO redemption_codes (code) VALUES ('0ET5-ZR5Z');
INSERT INTO redemption_codes (code) VALUES ('1DBK-NKJC');
INSERT INTO redemption_codes (code) VALUES ('29Q0-C22D');
INSERT INTO redemption_codes (code) VALUES ('2GOU-5WYQ');
INSERT INTO redemption_codes (code) VALUES ('3B0Z-T211');
INSERT INTO redemption_codes (code) VALUES ('3KEY-6TPZ');
INSERT INTO redemption_codes (code) VALUES ('4666-GHL3');
INSERT INTO redemption_codes (code) VALUES ('4D2D-PZX8');
INSERT INTO redemption_codes (code) VALUES ('4IJZ-MUJO');
INSERT INTO redemption_codes (code) VALUES ('4YWE-20SJ');
INSERT INTO redemption_codes (code) VALUES ('5MUA-HUM8');
INSERT INTO redemption_codes (code) VALUES ('6IYP-5DRE');
INSERT INTO redemption_codes (code) VALUES ('6JFD-R8B4');
INSERT INTO redemption_codes (code) VALUES ('6VR8-X080');
INSERT INTO redemption_codes (code) VALUES ('6YIL-6TT8');
INSERT INTO redemption_codes (code) VALUES ('70FC-AF5M');
INSERT INTO redemption_codes (code) VALUES ('742B-58L6');
INSERT INTO redemption_codes (code) VALUES ('7F6A-5RQO');
INSERT INTO redemption_codes (code) VALUES ('7VYR-YHJ9');
INSERT INTO redemption_codes (code) VALUES ('8A2T-IMH0');
INSERT INTO redemption_codes (code) VALUES ('8J7U-T8P3');
INSERT INTO redemption_codes (code) VALUES ('8JL3-X4I2');
INSERT INTO redemption_codes (code) VALUES ('8JYI-P36K');
INSERT INTO redemption_codes (code) VALUES ('8KZI-MNJO');
INSERT INTO redemption_codes (code) VALUES ('8M8B-XJSY');
INSERT INTO redemption_codes (code) VALUES ('8QM1-FYPJ');
INSERT INTO redemption_codes (code) VALUES ('AHWF-2TZS');
INSERT INTO redemption_codes (code) VALUES ('AKJG-DRIO');
INSERT INTO redemption_codes (code) VALUES ('AZJK-OUUW');
INSERT INTO redemption_codes (code) VALUES ('B96T-DP9E');
INSERT INTO redemption_codes (code) VALUES ('BDHU-W1HH');
INSERT INTO redemption_codes (code) VALUES ('BMWE-ZLPW');
INSERT INTO redemption_codes (code) VALUES ('CT5Y-ZHMT');
INSERT INTO redemption_codes (code) VALUES ('CXQ7-OIIA');
INSERT INTO redemption_codes (code) VALUES ('CZ4C-W6CT');
INSERT INTO redemption_codes (code) VALUES ('D13D-DMVQ');
INSERT INTO redemption_codes (code) VALUES ('DNAM-8W4E');
INSERT INTO redemption_codes (code) VALUES ('F3QE-HH2C');
INSERT INTO redemption_codes (code) VALUES ('F4XK-C5A7');
INSERT INTO redemption_codes (code) VALUES ('F88S-41TU');
INSERT INTO redemption_codes (code) VALUES ('G3OZ-HJWY');
INSERT INTO redemption_codes (code) VALUES ('GAWN-9YH1');
INSERT INTO redemption_codes (code) VALUES ('H3HF-3K3M');
INSERT INTO redemption_codes (code) VALUES ('HFOR-Q36A');
INSERT INTO redemption_codes (code) VALUES ('HHU8-W6IR');
INSERT INTO redemption_codes (code) VALUES ('HIN5-OBGD');
INSERT INTO redemption_codes (code) VALUES ('HY9E-HD0D');
INSERT INTO redemption_codes (code) VALUES ('HYFY-ZMYT');
INSERT INTO redemption_codes (code) VALUES ('I14V-Z5U0');
INSERT INTO redemption_codes (code) VALUES ('I9SK-SGP5');
INSERT INTO redemption_codes (code) VALUES ('IAMZ-IHDH');
INSERT INTO redemption_codes (code) VALUES ('IV90-RQE3');
INSERT INTO redemption_codes (code) VALUES ('IVAY-ZIR4');
INSERT INTO redemption_codes (code) VALUES ('JL4S-S3Y8');
INSERT INTO redemption_codes (code) VALUES ('K4TX-MTW4');
INSERT INTO redemption_codes (code) VALUES ('KMOM-U1YO');
INSERT INTO redemption_codes (code) VALUES ('KRBV-Q5F9');
INSERT INTO redemption_codes (code) VALUES ('KRDN-I0UI');
INSERT INTO redemption_codes (code) VALUES ('KV4M-M8SC');
INSERT INTO redemption_codes (code) VALUES ('KVE4-GRGS');
INSERT INTO redemption_codes (code) VALUES ('KXIW-X42N');
INSERT INTO redemption_codes (code) VALUES ('LAV3-JNX4');
INSERT INTO redemption_codes (code) VALUES ('M27G-ZA6H');
INSERT INTO redemption_codes (code) VALUES ('M2LS-R0HI');
INSERT INTO redemption_codes (code) VALUES ('M2T8-UI6H');
INSERT INTO redemption_codes (code) VALUES ('MEHG-SRCQ');
INSERT INTO redemption_codes (code) VALUES ('MI0N-00U0');
INSERT INTO redemption_codes (code) VALUES ('MLI7-71PZ');
INSERT INTO redemption_codes (code) VALUES ('MX1P-O6GT');
INSERT INTO redemption_codes (code) VALUES ('N04I-Q0VE');
INSERT INTO redemption_codes (code) VALUES ('N2IX-NUWC');
INSERT INTO redemption_codes (code) VALUES ('N6IT-PB1A');
INSERT INTO redemption_codes (code) VALUES ('NC58-TVCO');
INSERT INTO redemption_codes (code) VALUES ('NL5W-7KEE');
INSERT INTO redemption_codes (code) VALUES ('NSPP-IE9D');
INSERT INTO redemption_codes (code) VALUES ('O43C-351B');
INSERT INTO redemption_codes (code) VALUES ('O67I-L08I');
INSERT INTO redemption_codes (code) VALUES ('O7EC-0U0C');
INSERT INTO redemption_codes (code) VALUES ('OPOA-R78K');
INSERT INTO redemption_codes (code) VALUES ('PLUF-93MU');
INSERT INTO redemption_codes (code) VALUES ('PYGT-EWC5');
INSERT INTO redemption_codes (code) VALUES ('Q325-KGIO');
INSERT INTO redemption_codes (code) VALUES ('Q58K-X82F');
INSERT INTO redemption_codes (code) VALUES ('QW89-91VS');
INSERT INTO redemption_codes (code) VALUES ('RV8N-94KF');
INSERT INTO redemption_codes (code) VALUES ('S8CQ-4KKB');
INSERT INTO redemption_codes (code) VALUES ('SOJS-9KZO');
INSERT INTO redemption_codes (code) VALUES ('SQRS-1KB4');
INSERT INTO redemption_codes (code) VALUES ('SXQM-KV0Z');
INSERT INTO redemption_codes (code) VALUES ('T9PT-EXMR');
INSERT INTO redemption_codes (code) VALUES ('TCLJ-CV84');
INSERT INTO redemption_codes (code) VALUES ('U82R-2AJD');
INSERT INTO redemption_codes (code) VALUES ('UHC5-8CXC');
INSERT INTO redemption_codes (code) VALUES ('V6QP-BI8B');
INSERT INTO redemption_codes (code) VALUES ('VOOK-2FUZ');
INSERT INTO redemption_codes (code) VALUES ('W0G8-2MBH');
INSERT INTO redemption_codes (code) VALUES ('WP9I-FVAJ');
INSERT INTO redemption_codes (code) VALUES ('X4VP-8I9I');
INSERT INTO redemption_codes (code) VALUES ('XBM0-VVY2');
INSERT INTO redemption_codes (code) VALUES ('ZKPE-YEJH');

-- ===== 8. 插入商品码 =====

INSERT INTO products (code, name, base_secret) VALUES ('HSR45CHAR', '星铁4.5角色库', 'hsr45char');
INSERT INTO products (code, name, base_secret) VALUES ('HSR45LC', '星铁4.5光锥库', 'hsr45lc');
INSERT INTO products (code, name, base_secret) VALUES ('GI71CHAR', '原神7.1角色库', 'gi71char');
INSERT INTO products (code, name, base_secret) VALUES ('GI71WPN', '原神7.1武器库', 'gi71wpn');
INSERT INTO products (code, name, base_secret) VALUES ('ER13CHAR', '异环1.3角色库', 'er13char');
INSERT INTO products (code, name, base_secret) VALUES ('ER13WPN', '异环1.3武器库', 'er13wpn');

-- ===== 9. 授权 =====

GRANT EXECUTE ON FUNCTION claim_device_code(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION do_redeem(TEXT, TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION derive_password(TEXT, TEXT) TO anon;

-- ===== 完成！=====
