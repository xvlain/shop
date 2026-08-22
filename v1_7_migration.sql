-- ============================================
-- 二游情报铺 v1.7 迁移
-- 修复邮箱一键已读被覆盖问题
-- 在 Supabase SQL Editor 中执行全部内容
-- ============================================

-- 重写 shop_my_inbox：不自动标记已读，仅返回消息
CREATE OR REPLACE FUNCTION shop_my_inbox(p_device TEXT)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'id', i.id, 'type', i.type, 'title', i.title,
    'content', i.content, 'is_read', i.is_read,
    'order_id', i.order_id, 'created_at', i.created_at
  ) ORDER BY i.created_at DESC) INTO rows FROM inbox i WHERE i.device_code = p_device;
  RETURN jsonb_build_object('ok', true, 'messages', COALESCE(rows, '[]'::jsonb));
END; $$;
GRANT EXECUTE ON FUNCTION shop_my_inbox(TEXT) TO anon;
