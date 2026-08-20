-- ============================================
-- 修复确认订单后自动解锁不生效的问题
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- 1. 给 anon 角色授权 unlocks 表的插入权限（让 SECURITY DEFINER 函数能正常写入）
GRANT INSERT ON unlocks TO anon;

-- 创建 RLS 策略允许插入
CREATE POLICY "allow_insert_unlocks" ON unlocks
FOR INSERT TO anon
WITH CHECK (true);

-- 2. 补录已确认订单的解锁记录

-- 订单 #13 (G8CM-ZO6R)
INSERT INTO unlocks (device_code, gid, pool, redemption_code) VALUES
('G8CM-ZO6R', '原神-7.1-武器', 'weapon', '1OY8-R90M'),
('G8CM-ZO6R', '原神-7.1-角色', 'character', '3B0Z-T211'),
('G8CM-ZO6R', '崩坏：星穹铁道-4.5-光锥', 'weapon', '1COI-EWV4'),
('G8CM-ZO6R', '崩坏：星穹铁道-4.5-角色', 'character', '4KMI-7B0L'),
('G8CM-ZO6R', '异环-1.3-武器', 'weapon', '4666-GHL3')
ON CONFLICT (device_code, gid) DO NOTHING;

-- 订单 #12 (5AY5-AON1)
INSERT INTO unlocks (device_code, gid, pool, redemption_code) VALUES
('5AY5-AON1', '异环-1.3-角色', 'character', '2GOU-5WYQ')
ON CONFLICT (device_code, gid) DO NOTHING;
