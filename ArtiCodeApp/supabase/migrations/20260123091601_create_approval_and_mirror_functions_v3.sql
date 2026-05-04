/*
  # دوال الموافقات والحذف ونظام المرآة المحدث - v3
  
  ## 1. دوال الموافقة
    - `approve_movement` - الموافقة على حركة معلقة
    - `reject_movement` - رفض حركة معلقة
    
  ## 2. دوال الحذف
    - `request_movement_deletion` - طلب حذف حركة
    - `approve_movement_deletion` - الموافقة على حذف حركة
    
  ## 3. تحديث نظام المرآة
    - تحديث `create_mirror_movement` لدعم الموافقات
    - إنشاء إشعارات تلقائية
    
  ## 4. Triggers
    - trigger لإنشاء إشعارات عند إضافة حركة جديدة
*/

-- حذف triggers القديمة أولاً
DROP TRIGGER IF EXISTS after_movement_insert_create_mirror ON account_movements;
DROP TRIGGER IF EXISTS trigger_create_mirror_movement ON account_movements;

-- 1. دالة الموافقة على حركة
CREATE OR REPLACE FUNCTION approve_movement(
  p_movement_id uuid,
  p_user_name text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_movement record;
  v_mirror_movement_id uuid;
  v_result json;
BEGIN
  -- الحصول على معرف المستخدم
  SELECT id INTO v_user_id
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  -- الحصول على الحركة
  SELECT * INTO v_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  -- التحقق من أن الحركة تنتظر الموافقة
  IF v_movement.approval_status != 'pending' THEN
    RAISE EXCEPTION 'Movement is not pending approval';
  END IF;

  -- تحديث حالة الموافقة
  UPDATE account_movements
  SET 
    approval_status = 'approved',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now()
  WHERE id = p_movement_id;

  -- إنشاء إشعار للمنشئ
  IF v_movement.created_by_user_id IS NOT NULL THEN
    PERFORM create_notification(
      p_movement_id,
      v_movement.created_by_user_id,
      'approved',
      'تم الموافقة على الحركة رقم ' || v_movement.movement_number
    );
  END IF;

  v_result := json_build_object(
    'success', true,
    'message', 'تم الموافقة على الحركة بنجاح',
    'movement_id', p_movement_id
  );

  RETURN v_result;
END;
$$;

-- 2. دالة رفض حركة
CREATE OR REPLACE FUNCTION reject_movement(
  p_movement_id uuid,
  p_user_name text,
  p_reason text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_movement record;
  v_result json;
  v_message text;
BEGIN
  -- الحصول على معرف المستخدم
  SELECT id INTO v_user_id
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  -- الحصول على الحركة
  SELECT * INTO v_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  -- التحقق من أن الحركة تنتظر الموافقة
  IF v_movement.approval_status != 'pending' THEN
    RAISE EXCEPTION 'Movement is not pending approval';
  END IF;

  -- تحديث حالة الحركة
  UPDATE account_movements
  SET 
    approval_status = 'rejected',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now()
  WHERE id = p_movement_id;

  -- إنشاء رسالة الإشعار
  v_message := 'تم رفض الحركة رقم ' || v_movement.movement_number;
  IF p_reason IS NOT NULL THEN
    v_message := v_message || ' - السبب: ' || p_reason;
  END IF;

  -- إنشاء إشعار للمنشئ
  IF v_movement.created_by_user_id IS NOT NULL THEN
    PERFORM create_notification(
      p_movement_id,
      v_movement.created_by_user_id,
      'rejected',
      v_message
    );
  END IF;

  v_result := json_build_object(
    'success', true,
    'message', 'تم رفض الحركة',
    'movement_id', p_movement_id
  );

  RETURN v_result;
END;
$$;

-- 3. دالة طلب حذف حركة
CREATE OR REPLACE FUNCTION request_movement_deletion(
  p_movement_id uuid,
  p_user_name text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_movement record;
  v_can_delete_directly boolean;
  v_result json;
BEGIN
  -- الحصول على معرف المستخدم
  SELECT id INTO v_user_id
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  -- الحصول على الحركة
  SELECT * INTO v_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  -- التحقق إذا كان المستخدم هو من أنشأ الحركة
  v_can_delete_directly := (v_movement.created_by_user_id = v_user_id);

  IF v_can_delete_directly THEN
    -- حذف مباشر
    DELETE FROM account_movements WHERE id = p_movement_id;
    
    v_result := json_build_object(
      'success', true,
      'message', 'تم حذف الحركة بنجاح',
      'deleted', true
    );
  ELSE
    -- طلب موافقة على الحذف
    UPDATE account_movements
    SET 
      deletion_requested = true,
      deletion_requested_by = v_user_id,
      deletion_requested_at = now()
    WHERE id = p_movement_id;

    -- إنشاء إشعار للمنشئ
    IF v_movement.created_by_user_id IS NOT NULL THEN
      PERFORM create_notification(
        p_movement_id,
        v_movement.created_by_user_id,
        'deletion_request',
        'طلب حذف الحركة رقم ' || v_movement.movement_number
      );
    END IF;

    v_result := json_build_object(
      'success', true,
      'message', 'تم إرسال طلب الحذف',
      'deleted', false,
      'pending_approval', true
    );
  END IF;

  RETURN v_result;
END;
$$;

-- 4. دالة الموافقة على حذف حركة
CREATE OR REPLACE FUNCTION approve_movement_deletion(
  p_movement_id uuid,
  p_user_name text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_movement record;
  v_result json;
BEGIN
  -- الحصول على معرف المستخدم
  SELECT id INTO v_user_id
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  -- الحصول على الحركة
  SELECT * INTO v_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  -- التحقق من وجود طلب حذف
  IF NOT v_movement.deletion_requested THEN
    RAISE EXCEPTION 'No deletion request for this movement';
  END IF;

  -- التحقق من أن المستخدم هو منشئ الحركة
  IF v_movement.created_by_user_id != v_user_id THEN
    RAISE EXCEPTION 'Only the creator can approve deletion';
  END IF;

  -- حذف الحركة
  DELETE FROM account_movements WHERE id = p_movement_id;

  v_result := json_build_object(
    'success', true,
    'message', 'تم حذف الحركة بنجاح'
  );

  RETURN v_result;
END;
$$;

-- 5. حذف جميع نسخ create_mirror_movement
DROP FUNCTION IF EXISTS create_mirror_movement() CASCADE;
DROP FUNCTION IF EXISTS create_mirror_movement(uuid) CASCADE;

-- إنشاء دالة جديدة
CREATE OR REPLACE FUNCTION create_mirror_movement_v2(p_movement_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_original_movement record;
  v_customer record;
  v_linked_customer_id uuid;
  v_mirror_movement_id uuid;
  v_mirror_type text;
  v_mirror_needs_approval boolean;
  v_mirror_approval_status text;
BEGIN
  -- الحصول على الحركة الأصلية
  SELECT * INTO v_original_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF v_original_movement IS NULL THEN
    RETURN NULL;
  END IF;

  -- الحصول على العميل
  SELECT * INTO v_customer
  FROM customers
  WHERE id = v_original_movement.customer_id;

  IF v_customer IS NULL OR v_customer.linked_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- البحث عن العميل المرتبط (العميل المتبادل)
  SELECT id INTO v_linked_customer_id
  FROM customers
  WHERE user_id = v_customer.linked_user_id
    AND linked_user_id = v_customer.user_id
  LIMIT 1;

  IF v_linked_customer_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- تحديد نوع الحركة المرآة (عكس الأصلية)
  IF v_original_movement.movement_type = 'incoming' THEN
    v_mirror_type := 'outgoing';
    -- حركات "له" تُنشأ تلقائياً كمعتمدة
    v_mirror_needs_approval := false;
    v_mirror_approval_status := 'approved';
  ELSE
    v_mirror_type := 'incoming';
    -- حركات "عليه" من الأصل = "له" في المرآة = تلقائية
    v_mirror_needs_approval := false;
    v_mirror_approval_status := 'approved';
  END IF;

  -- إنشاء الحركة المرآة
  INSERT INTO account_movements (
    movement_number,
    customer_id,
    movement_type,
    amount,
    currency,
    notes,
    sender_name,
    beneficiary_name,
    commission,
    commission_currency,
    commission_recipient_id,
    mirror_movement_id,
    source_user_id,
    created_by_user_id,
    created_by_user_name,
    pending_approval,
    approval_status,
    receipt_number
  ) VALUES (
    v_original_movement.movement_number,
    v_linked_customer_id,
    v_mirror_type,
    v_original_movement.amount,
    v_original_movement.currency,
    v_original_movement.notes,
    -- تبديل المرسل والمستفيد
    v_original_movement.beneficiary_name,
    v_original_movement.sender_name,
    v_original_movement.commission,
    v_original_movement.commission_currency,
    v_original_movement.commission_recipient_id,
    p_movement_id,
    v_original_movement.source_user_id,
    v_original_movement.created_by_user_id,
    v_original_movement.created_by_user_name,
    v_mirror_needs_approval,
    v_mirror_approval_status,
    v_original_movement.receipt_number -- نفس رقم السند
  )
  RETURNING id INTO v_mirror_movement_id;

  -- تحديث الحركة الأصلية بمعرف المرآة
  UPDATE account_movements
  SET mirror_movement_id = v_mirror_movement_id
  WHERE id = p_movement_id;

  -- إنشاء إشعار للمستخدم المرتبط
  PERFORM create_notification(
    v_mirror_movement_id,
    v_customer.linked_user_id,
    'movement_added',
    'تم إضافة حركة جديدة من ' || COALESCE(v_original_movement.created_by_user_name, 'مستخدم') || ' - ' || v_original_movement.movement_number
  );

  RETURN v_mirror_movement_id;
END;
$$;

-- 6. Trigger لإنشاء الحركة المرآة تلقائياً
CREATE OR REPLACE FUNCTION trigger_create_mirror_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- إنشاء حركة مرآة فقط إذا لم تكن الحركة نفسها مرآة
  IF NEW.mirror_movement_id IS NULL AND NEW.approval_status = 'approved' THEN
    PERFORM create_mirror_movement_v2(NEW.id);
  END IF;
  
  RETURN NEW;
END;
$$;

-- إنشاء trigger جديد
CREATE TRIGGER after_movement_insert_create_mirror
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION trigger_create_mirror_movement();

COMMENT ON FUNCTION approve_movement IS 'الموافقة على حركة معلقة';
COMMENT ON FUNCTION reject_movement IS 'رفض حركة معلقة';
COMMENT ON FUNCTION request_movement_deletion IS 'طلب حذف حركة (مباشر أو بموافقة)';
COMMENT ON FUNCTION approve_movement_deletion IS 'الموافقة على حذف حركة';
COMMENT ON FUNCTION create_mirror_movement_v2 IS 'إنشاء حركة مرآة مع دعم الموافقات';
