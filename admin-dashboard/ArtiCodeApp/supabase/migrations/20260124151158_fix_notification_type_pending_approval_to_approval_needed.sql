/*
  # إصلاح نوع الإشعار في create_mirror_movement_v2
  
  ## المشكلة
  دالة `create_mirror_movement_v2` تستخدم `'pending_approval'` كنوع إشعار، لكن 
  الـ constraint على جدول `movement_notifications` لا يسمح بهذا النوع.
  
  هذا يتسبب في خطأ عند محاولة إضافة حركة على حساب مرتبط من نوع outgoing.
  
  ## الحل
  1. تحديث دالة `create_mirror_movement_v2` لاستخدام `'approval_needed'` بدلاً من `'pending_approval'`
  2. إزالة الـ constraint المزدوج على جدول `movement_notifications`
  
  ## التأثير
  - إصلاح خطأ إضافة الحركات على الحسابات المرتبطة
  - توحيد أنواع الإشعارات
*/

-- ============================================================
-- 1. إزالة الـ constraint المزدوج (الاحتفاظ بالأحدث فقط)
-- ============================================================

-- إزالة الـ constraint القديم إذا كان موجوداً
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint 
    WHERE conname = 'valid_notification_type'
  ) THEN
    ALTER TABLE movement_notifications DROP CONSTRAINT valid_notification_type;
    RAISE NOTICE 'تم إزالة constraint القديم: valid_notification_type';
  END IF;
END $$;

-- ============================================================
-- 2. تحديث دالة create_mirror_movement_v2
-- ============================================================

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
  v_original_creator_name text;
BEGIN
  RAISE NOTICE '[create_mirror_movement_v2] بدء إنشاء حركة مرآة للحركة: %', p_movement_id;

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
    -- الحصول على اسم المستخدم المنشئ
    SELECT user_name INTO v_original_creator_name
    FROM app_security
    WHERE id = v_customer.user_id
    LIMIT 1;

    INSERT INTO customers (
      user_id,
      name,
      account_number,
      linked_user_id
    ) VALUES (
      v_customer.linked_user_id,
      COALESCE(v_original_creator_name, 'الطرف المقابل'),
      v_customer.account_number,
      v_customer.user_id
    )
    RETURNING id INTO v_linked_customer_id;

    v_customer_was_created := true;
    RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء العميل المتبادل: %', v_linked_customer_id;
  END IF;

  -- تحديد نوع الحركة المرآة
  IF v_original_movement.movement_type = 'outgoing' THEN
    v_mirror_type := 'incoming';
    v_mirror_needs_approval := true;
    v_mirror_approval_status := 'pending';
  ELSE
    v_mirror_type := 'outgoing';
    v_mirror_needs_approval := false;
    v_mirror_approval_status := 'approved';
  END IF;

  -- إنشاء الحركة المرآة
  INSERT INTO account_movements (
    customer_id,
    movement_type,
    amount,
    currency,
    notes,
    commission,
    commission_currency,
    commission_recipient_id,
    created_by_user_id,
    mirror_movement_id,
    pending_approval,
    approval_status,
    is_voided
  ) VALUES (
    v_linked_customer_id,
    v_mirror_type,
    v_original_movement.amount,
    v_original_movement.currency,
    v_original_movement.notes,
    v_original_movement.commission,
    v_original_movement.commission_currency,
    v_original_movement.commission_recipient_id,
    v_original_movement.created_by_user_id,
    p_movement_id,
    v_mirror_needs_approval,
    v_mirror_approval_status,
    false
  )
  RETURNING id INTO v_mirror_movement_id;

  -- تحديث الحركة الأصلية لتشير للحركة المرآة
  UPDATE account_movements
  SET mirror_movement_id = v_mirror_movement_id
  WHERE id = p_movement_id;

  -- إنشاء إشعار للطرف الآخر إذا كانت تحتاج موافقة
  IF v_mirror_needs_approval THEN
    PERFORM create_notification(
      v_mirror_movement_id,
      v_customer.linked_user_id,
      'approval_needed',  -- ✅ تم التصحيح من 'pending_approval'
      'حركة جديدة تنتظر موافقتك من ' || v_customer.name,
      v_original_movement.movement_number,
      v_original_movement.amount,
      v_original_movement.currency,
      v_customer.name, -- customer_name
      v_customer.name, -- actor_name
      v_mirror_type,
      NULL -- extra_data
    );
  END IF;

  RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء الحركة المرآة: %', v_mirror_movement_id;
  RETURN v_mirror_movement_id;
END;
$$;

COMMENT ON FUNCTION create_mirror_movement_v2 IS 'إنشاء حركة مرآة للحسابات المرتبطة مع إشعارات صحيحة';
