/*
  # إضافة دالة set_current_user

  ## الغرض
  - إنشاء دالة لتعيين المستخدم الحالي في سياق Supabase
  - تستخدم لتفعيل Row Level Security بشكل صحيح

  ## الدالة
  - set_current_user(user_name): تعيين المستخدم الحالي في app.current_user
*/

-- دالة لتعيين المستخدم الحالي في السياق
CREATE OR REPLACE FUNCTION set_current_user(user_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Set the current user in the session context
  PERFORM set_config('app.current_user', user_name, false);
END;
$$;

-- منح الصلاحيات للجميع لاستدعاء هذه الدالة
GRANT EXECUTE ON FUNCTION set_current_user(text) TO anon, authenticated;
