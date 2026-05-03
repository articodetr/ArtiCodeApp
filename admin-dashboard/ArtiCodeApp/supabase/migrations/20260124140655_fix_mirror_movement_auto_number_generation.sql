/*
  # إصلاح التوليد التلقائي لرقم الحركة المرآة

  ## المشكلة
  دالة create_mirror_movement_v2 تحاول توليد movement_number يدوياً وتحديده في INSERT
  مما يمنع الـ trigger الجديد auto_generate_movement_number من العمل
  
  ## الحل
  إزالة التوليد اليدوي والسماح للـ trigger بتوليد الرقم تلقائياً
*/

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
  v_customer_was_created boolean := false;
BEGIN
  -- الحصول على الحركة الأصلية
  SELECT * INTO v_original_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF v_original_movement IS NULL THEN
    RAISE NOTICE '[create_mirror_movement_v2] الحركة غير موجودة: %', p_movement_id;
    RETURN NULL;
  END IF;

  -- الحصول على العميل
  SELECT * INTO v_customer
  FROM customers
  WHERE id = v_original_movement.customer_id;

  IF v_customer IS NULL OR v_customer.linked_user_id IS NULL THEN
    RAISE NOTICE '[create_mirror_movement_v2] العميل غير مرتبط بمستخدم';
    RETURN NULL;
  END IF;

  -- البحث عن العميل المرتبط (العميل المتبادل)
  SELECT id INTO v_linked_customer_id
  FROM customers
  WHERE user_id = v_customer.linked_user_id
    AND linked_user_id = v_customer.user_id
  LIMIT 1;

  -- إذا لم يوجد العميل المقابل، إنشاؤه تلقائياً
  IF v_linked_customer_id IS NULL THEN
    RAISE NOTICE '[create_mirror_movement_v2] العميل المقابل غير موجود، سيتم إنشاؤه تلقائياً';
    
    v_linked_customer_id := get_or_create_reciprocal_customer(
      v_customer.linked_user_id,  -- المستخدم المستهدف (الطرف الآخر)
      v_customer.user_id           -- المستخدم المصدر (مالك العميل الأصلي)
    );
    
    v_customer_was_created := true;

    -- إنشاء إشعار customer_added للطرف الآخر
    PERFORM create_notification(
      NULL,  -- لا توجد حركة بعد
      v_customer.linked_user_id,
      'customer_added',
      'تم إضافتك تلقائياً كحساب مرتبط من قبل ' ||
        COALESCE(v_original_movement.created_by_user_name, 'مستخدم') ||
        ' بسبب حركة مالية جديدة'
    );

    RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء العميل المقابل: %', v_linked_customer_id;
  END IF;

  -- تحديد نوع الحركة المرآة (عكس الأصلية)
  IF v_original_movement.movement_type = 'incoming' THEN
    v_mirror_type := 'outgoing';
    v_mirror_needs_approval := false;
    v_mirror_approval_status := 'approved';
  ELSE
    v_mirror_type := 'incoming';
    v_mirror_needs_approval := false;
    v_mirror_approval_status := 'approved';
  END IF;

  -- إنشاء الحركة المرآة بدون movement_number و receipt_number
  -- سيتم توليدهما تلقائياً من triggers
  INSERT INTO account_movements (
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
    approval_status
  ) VALUES (
    v_linked_customer_id,
    v_mirror_type,
    v_original_movement.amount,
    v_original_movement.currency,
    v_original_movement.notes,
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
    v_mirror_approval_status
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
    'تم إضافة حركة جديدة من ' ||
      COALESCE(v_original_movement.created_by_user_name, 'مستخدم')
  );

  RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء الحركة المرآة بنجاح: %', v_mirror_movement_id;
  RETURN v_mirror_movement_id;
END;
$$;

COMMENT ON FUNCTION create_mirror_movement_v2 IS 
  'إنشاء حركة مرآة للحسابات المرتبطة - يتم توليد movement_number و receipt_number تلقائياً';
