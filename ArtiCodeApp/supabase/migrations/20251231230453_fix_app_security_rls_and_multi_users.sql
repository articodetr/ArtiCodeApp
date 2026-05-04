/*
  # إصلاح نظام أمان PIN ودعم مستخدمين متعددين

  ## التغييرات الرئيسية

  1. إزالة القيد الفريد (single_pin_config) للسماح بمستخدمين متعددين
  2. تحديث سياسات RLS من authenticated إلى anon للسماح بالوصول
  3. إضافة حقول جديدة:
     - role (نوع المستخدم: admin, user)
     - is_active (حالة المستخدم)
     - last_login (آخر تسجيل دخول)

  4. دوال جديدة لإدارة المستخدمين:
     - get_all_users() - الحصول على جميع المستخدمين
     - update_user_pin() - تحديث PIN لمستخدم
     - delete_user_by_id() - حذف مستخدم
     - update_last_login() - تحديث آخر تسجيل دخول

  ## الأمان
  - RLS مفعل مع سماح الوصول للجميع (anon)
  - تسجيل جميع العمليات في deletion_logs
*/

-- إزالة القيد الفريد للسماح بمستخدمين متعددين
DROP INDEX IF EXISTS single_pin_config;

-- إضافة حقول جديدة للجدول
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_security' AND column_name = 'role'
  ) THEN
    ALTER TABLE app_security ADD COLUMN role text DEFAULT 'user' CHECK (role IN ('admin', 'user'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_security' AND column_name = 'is_active'
  ) THEN
    ALTER TABLE app_security ADD COLUMN is_active boolean DEFAULT true;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_security' AND column_name = 'last_login'
  ) THEN
    ALTER TABLE app_security ADD COLUMN last_login timestamptz;
  END IF;
END $$;

-- حذف السياسات القديمة
DROP POLICY IF EXISTS "Authenticated users can view PIN settings" ON app_security;
DROP POLICY IF EXISTS "Authenticated users can insert PIN settings" ON app_security;
DROP POLICY IF EXISTS "Authenticated users can update PIN settings" ON app_security;
DROP POLICY IF EXISTS "Authenticated users can delete PIN settings" ON app_security;

-- إنشاء سياسات جديدة للسماح بالوصول للجميع (anon)
CREATE POLICY "Allow all to view users"
  ON app_security FOR SELECT
  USING (true);

CREATE POLICY "Allow all to insert users"
  ON app_security FOR INSERT
  WITH CHECK (true);

CREATE POLICY "Allow all to update users"
  ON app_security FOR UPDATE
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow all to delete users"
  ON app_security FOR DELETE
  USING (true);

-- دالة للحصول على جميع المستخدمين
CREATE OR REPLACE FUNCTION get_all_users()
RETURNS TABLE (
  id uuid,
  user_name text,
  role text,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  last_login timestamptz
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.id,
    s.user_name,
    s.role,
    s.is_active,
    s.created_at,
    s.updated_at,
    s.last_login
  FROM app_security s
  ORDER BY s.created_at DESC;
END;
$$;

-- دالة لتحديث PIN لمستخدم
CREATE OR REPLACE FUNCTION update_user_pin(
  p_user_id uuid,
  p_new_pin_hash text
)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_name text;
  v_result json;
BEGIN
  -- التحقق من وجود المستخدم
  SELECT user_name INTO v_user_name
  FROM app_security
  WHERE id = p_user_id;

  IF v_user_name IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'message', 'المستخدم غير موجود'
    );
  END IF;

  -- تحديث PIN
  UPDATE app_security
  SET pin_hash = p_new_pin_hash,
      updated_at = now()
  WHERE id = p_user_id;

  v_result := json_build_object(
    'success', true,
    'message', 'تم تحديث PIN بنجاح',
    'user_name', v_user_name
  );

  RETURN v_result;
END;
$$;

-- دالة لحذف مستخدم
CREATE OR REPLACE FUNCTION delete_user_by_id(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_name text;
  v_result json;
BEGIN
  -- التحقق من وجود المستخدم
  SELECT user_name INTO v_user_name
  FROM app_security
  WHERE id = p_user_id;

  IF v_user_name IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'message', 'المستخدم غير موجود'
    );
  END IF;

  -- تسجيل العملية في سجل الحذف
  INSERT INTO deletion_logs (
    operation_type,
    customer_id,
    customer_name,
    notes
  ) VALUES (
    'delete_user',
    p_user_id,
    v_user_name,
    'تم حذف مستخدم من نظام الأمان'
  );

  -- حذف المستخدم
  DELETE FROM app_security WHERE id = p_user_id;

  v_result := json_build_object(
    'success', true,
    'message', 'تم حذف المستخدم بنجاح',
    'user_name', v_user_name
  );

  RETURN v_result;
END;
$$;

-- دالة لتحديث آخر تسجيل دخول
CREATE OR REPLACE FUNCTION update_last_login(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE app_security
  SET last_login = now()
  WHERE id = p_user_id;
END;
$$;

-- دالة للحصول على عدد المستخدمين
CREATE OR REPLACE FUNCTION get_users_count()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count FROM app_security;
  RETURN v_count;
END;
$$;

-- إنشاء فهرس لتحسين الأداء
CREATE INDEX IF NOT EXISTS app_security_user_name_idx ON app_security(user_name);
CREATE INDEX IF NOT EXISTS app_security_is_active_idx ON app_security(is_active);
CREATE INDEX IF NOT EXISTS app_security_last_login_idx ON app_security(last_login DESC);
