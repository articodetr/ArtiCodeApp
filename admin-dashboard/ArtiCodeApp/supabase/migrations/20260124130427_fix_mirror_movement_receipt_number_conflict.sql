/*
  # إصلاح تعارض receipt_number في الحركات المرآة

  ## المشكلة
  عند إنشاء حركة مرآة، النظام يحاول استخدام نفس receipt_number من الحركة الأصلية
  مما يسبب duplicate key error لأن هناك unique constraint على (customer_id, receipt_number)
  
  ## الحل
  - عدم تمرير receipt_number عند إنشاء mirror movement
  - السماح لـ trigger auto_generate_receipt_number بتوليد رقم جديد فريد لكل حركة
  
  ## مثال
  - Taha يضيف حركة على Salem customer → receipt = "00001" (السند الأول للعميل Salem)
  - النظام ينشئ mirror على Taha customer → receipt = "00005" (السند التالي للعميل Taha)
*/

-- تحديث function create_mirror_movement_v2 لعدم نسخ receipt_number
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
  v_mirror_movement_number text;
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

  -- توليد رقم حركة جديد للحركة المرآة
  v_mirror_movement_number := generate_movement_number();

  -- إنشاء الحركة المرآة بدون receipt_number
  -- سيتم توليد receipt_number تلقائياً من trigger auto_generate_receipt_number
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
    approval_status
    -- لا نضع receipt_number هنا! سيتم توليده تلقائياً
  ) VALUES (
    v_mirror_movement_number,  -- رقم جديد فريد للحركة المرآة
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
    -- receipt_number سيتم توليده تلقائياً من trigger
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
      COALESCE(v_original_movement.created_by_user_name, 'مستخدم') ||
      ' - ' || v_mirror_movement_number
  );

  RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء الحركة المرآة بنجاح: % برقم %', v_mirror_movement_id, v_mirror_movement_number;
  RETURN v_mirror_movement_id;
END;
$$;

COMMENT ON FUNCTION create_mirror_movement_v2 IS 
  'إنشاء حركة مرآة للحسابات المرتبطة - كل حركة تحصل على receipt_number فريد خاص بها';
