/*
  # حماية حساب Ali كحساب مدير رئيسي

  ## التغييرات

  1. تحديث حساب Ali ليكون admin
  2. إضافة trigger لمنع حذف حساب Ali
  3. إضافة constraint لضمان وجود مستخدم واحد على الأقل بصلاحيات admin

  ## الأمان
  - حساب Ali محمي من الحذف
  - يجب أن يكون هناك مستخدم admin واحد على الأقل في النظام
*/

-- تحديث حساب Ali ليكون admin (إذا كان موجوداً)
UPDATE app_security 
SET role = 'admin' 
WHERE LOWER(user_name) = 'ali' AND role != 'admin';

-- إنشاء دالة لمنع حذف حساب Ali
CREATE OR REPLACE FUNCTION prevent_ali_deletion()
RETURNS TRIGGER AS $$
BEGIN
  IF LOWER(OLD.user_name) = 'ali' THEN
    RAISE EXCEPTION 'لا يمكن حذف حساب Ali - هذا هو الحساب الرئيسي';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- إنشاء trigger لمنع حذف Ali
DROP TRIGGER IF EXISTS prevent_ali_deletion_trigger ON app_security;
CREATE TRIGGER prevent_ali_deletion_trigger
  BEFORE DELETE ON app_security
  FOR EACH ROW
  EXECUTE FUNCTION prevent_ali_deletion();

-- إنشاء دالة لضمان وجود admin واحد على الأقل
CREATE OR REPLACE FUNCTION ensure_at_least_one_admin()
RETURNS TRIGGER AS $$
DECLARE
  admin_count int;
BEGIN
  -- التحقق من عدد المدراء المتبقين
  SELECT COUNT(*) INTO admin_count
  FROM app_security
  WHERE role = 'admin' AND id != OLD.id;

  IF admin_count = 0 THEN
    RAISE EXCEPTION 'لا يمكن حذف آخر مدير في النظام';
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- إنشاء trigger لضمان وجود admin
DROP TRIGGER IF EXISTS ensure_admin_exists_trigger ON app_security;
CREATE TRIGGER ensure_admin_exists_trigger
  BEFORE DELETE ON app_security
  FOR EACH ROW
  WHEN (OLD.role = 'admin')
  EXECUTE FUNCTION ensure_at_least_one_admin();

-- تحديث دالة delete_user_by_id لمنع حذف Ali
CREATE OR REPLACE FUNCTION delete_user_by_id(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_name text;
  v_role text;
  v_result json;
BEGIN
  -- التحقق من وجود المستخدم
  SELECT user_name, role INTO v_user_name, v_role
  FROM app_security
  WHERE id = p_user_id;

  IF v_user_name IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'message', 'المستخدم غير موجود'
    );
  END IF;

  -- منع حذف Ali
  IF LOWER(v_user_name) = 'ali' THEN
    RETURN json_build_object(
      'success', false,
      'message', 'لا يمكن حذف حساب Ali - هذا هو الحساب الرئيسي'
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
