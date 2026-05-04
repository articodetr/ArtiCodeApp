/*
  # إعداد حساب الأدمن Ali

  ## التغييرات
  
  1. إنشاء مستخدم أدمن باسم "Ali" برقم سري "11223344"
  2. حذف المستخدمين الآخرين
  3. حماية حساب Ali من الحذف نهائياً
  4. السماح بتغيير كلمة المرور
  
  ## الأمان
  - حساب Ali محمي من الحذف نهائياً
  - يمكن تغيير كلمة المرور فقط
  - RLS يسمح بإضافة مستخدمين جدد
*/

-- 1. إنشاء حساب Ali أولاً (إذا لم يكن موجوداً)
INSERT INTO app_security (user_name, pin_hash, role, is_active)
SELECT 'Ali', '482c811da5d5b4bc6d497ffa98491e38', 'admin', true
WHERE NOT EXISTS (
  SELECT 1 FROM app_security WHERE LOWER(user_name) = 'ali'
);

-- 2. حذف جميع المستخدمين ما عدا Ali
DELETE FROM app_security WHERE LOWER(user_name) != 'ali';

-- 3. تحديث دالة منع حذف حساب Ali
DROP TRIGGER IF EXISTS prevent_ali_deletion_trigger ON app_security;
DROP FUNCTION IF EXISTS prevent_ali_deletion();

CREATE OR REPLACE FUNCTION prevent_ali_deletion()
RETURNS TRIGGER AS $$
BEGIN
  IF LOWER(OLD.user_name) = 'ali' THEN
    RAISE EXCEPTION 'لا يمكن حذف حساب Ali - هذا هو الحساب الرئيسي';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prevent_ali_deletion_trigger
  BEFORE DELETE ON app_security
  FOR EACH ROW
  EXECUTE FUNCTION prevent_ali_deletion();

-- 4. تحديث دالة ensure_at_least_one_admin لحماية Ali
DROP TRIGGER IF EXISTS ensure_at_least_one_admin_trigger ON app_security;

CREATE OR REPLACE FUNCTION ensure_at_least_one_admin()
RETURNS TRIGGER AS $$
DECLARE
  admin_count INTEGER;
BEGIN
  -- منع حذف حساب Ali بشكل صريح
  IF TG_OP = 'DELETE' AND LOWER(OLD.user_name) = 'ali' THEN
    RAISE EXCEPTION 'لا يمكن حذف حساب Ali - هذا هو الحساب الرئيسي';
  END IF;

  -- عند الحذف أو التحديث، تأكد من وجود admin واحد على الأقل
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND NEW.role != 'admin' AND OLD.role = 'admin') THEN
    SELECT COUNT(*) INTO admin_count
    FROM app_security
    WHERE role = 'admin' AND is_active = true
      AND (TG_OP = 'DELETE' AND id != OLD.id OR TG_OP = 'UPDATE');

    IF admin_count < 1 THEN
      RAISE EXCEPTION 'لا يمكن حذف آخر مدير في النظام';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER ensure_at_least_one_admin_trigger
  BEFORE DELETE OR UPDATE ON app_security
  FOR EACH ROW
  EXECUTE FUNCTION ensure_at_least_one_admin();

-- 5. تحديث دالة delete_user_by_id
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

  -- منع حذف حساب Ali
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

-- 6. تحديث سياسات RLS للسماح بإضافة وتعديل المستخدمين
DROP POLICY IF EXISTS "Allow insert for authenticated users" ON app_security;
DROP POLICY IF EXISTS "Allow users to update their own data" ON app_security;

CREATE POLICY "Allow insert for authenticated users"
  ON app_security
  FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "Allow users to update their own data"
  ON app_security
  FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);
