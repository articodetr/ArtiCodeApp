/*
  # تحديث حساب الأدمن من Ali إلى A

  ## التغييرات
  
  1. تحديث الـ triggers والـ functions لحماية حساب "A" بدلاً من "Ali"
  2. تحديث دالة delete_user_by_id لمنع حذف حساب "A"
  
  ## الأمان
  - حساب "A" محمي من الحذف
  - يجب أن يكون هناك مستخدم admin واحد على الأقل في النظام
*/

-- تحديث دالة منع حذف الحساب الرئيسي
CREATE OR REPLACE FUNCTION prevent_ali_deletion()
RETURNS TRIGGER AS $$
BEGIN
  IF LOWER(OLD.user_name) = 'a' THEN
    RAISE EXCEPTION 'لا يمكن حذف حساب A - هذا هو الحساب الرئيسي';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- تحديث دالة delete_user_by_id لمنع حذف حساب A
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

  -- منع حذف حساب A
  IF LOWER(v_user_name) = 'a' THEN
    RETURN json_build_object(
      'success', false,
      'message', 'لا يمكن حذف حساب A - هذا هو الحساب الرئيسي'
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
