/*
  # إعادة إنشاء نظام الإشعارات مع البيانات الكاملة
  
  ## المشاكل المُعالجة:
  
  1. **بيانات الإشعارات فارغة**: الحقول amount, currency, customer_name تكون NULL
  2. **خطأ "Movement is not pending approval"**: الحركات المرآة معتمدة مسبقاً
  3. **عدم ظهور أزرار الموافقة/الرفض بشكل صحيح**
  
  ## التغييرات:
  
  1. إنشاء دالة create_notification جديدة مع جميع المعاملات المطلوبة
  2. تحديث دالة create_mirror_movement_v2 لتمرير البيانات الكاملة
  3. تحديث دالة approve_movement لتمرير البيانات الكاملة
  4. تحديث دالة void_movement_and_mirror لتمرير البيانات الكاملة
  5. إصلاح البيانات الموجودة في الإشعارات غير المقروءة
*/

-- ============================================================
-- 1. إنشاء دالة create_notification جديدة
-- ============================================================

CREATE OR REPLACE FUNCTION create_notification(
  p_movement_id uuid,
  p_user_id uuid,
  p_notification_type text,
  p_message text,
  p_movement_number text DEFAULT NULL,
  p_amount numeric DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_customer_name text DEFAULT NULL,
  p_actor_name text DEFAULT NULL,
  p_movement_type text DEFAULT NULL,
  p_extra_data jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_notification_id uuid;
BEGIN
  INSERT INTO movement_notifications (
    movement_id,
    user_id,
    notification_type,
    message,
    movement_number,
    amount,
    currency,
    customer_name,
    actor_name,
    movement_type,
    extra_data
  ) VALUES (
    p_movement_id,
    p_user_id,
    p_notification_type,
    p_message,
    p_movement_number,
    p_amount,
    p_currency,
    p_customer_name,
    p_actor_name,
    p_movement_type,
    p_extra_data
  )
  RETURNING id INTO v_notification_id;

  RETURN v_notification_id;
END;
$$;

COMMENT ON FUNCTION create_notification IS 'إنشاء إشعار جديد مع البيانات الكاملة للحركة';

-- ============================================================
-- 2. تحديث create_mirror_movement_v2 لتمرير البيانات الكاملة
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
    net_amount,
    currency,
    description,
    commission,
    commission_currency,
    commission_recipient,
    user_id,
    created_by_user_id,
    mirrored_from_movement_id,
    pending_approval,
    approval_status,
    is_voided
  ) VALUES (
    v_linked_customer_id,
    v_mirror_type,
    v_original_movement.amount,
    v_original_movement.net_amount,
    v_original_movement.currency,
    v_original_movement.description,
    v_original_movement.commission,
    v_original_movement.commission_currency,
    v_original_movement.commission_recipient,
    v_customer.linked_user_id,
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

  -- إنشاء إشعار للطرف الآخر مع البيانات الكاملة
  PERFORM create_notification(
    v_mirror_movement_id,
    v_customer.linked_user_id,
    'movement_added',
    'تم إضافة حركة جديدة من ' || v_customer.name,
    NULL, -- movement_number
    v_original_movement.amount,
    v_original_movement.currency,
    v_customer.name,
    v_customer.name, -- actor_name
    v_mirror_type,
    NULL -- extra_data
  );

  RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء الحركة المرآة: %', v_mirror_movement_id;
  RETURN v_mirror_movement_id;
END;
$$;

-- ============================================================
-- 3. تحديث approve_movement لتمرير البيانات الكاملة
-- ============================================================

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
  v_customer record;
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

  -- الحصول على بيانات العميل
  SELECT * INTO v_customer
  FROM customers
  WHERE id = v_movement.customer_id;

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

  -- إنشاء إشعار للمنشئ مع البيانات الكاملة
  IF v_movement.created_by_user_id IS NOT NULL THEN
    PERFORM create_notification(
      p_movement_id,
      v_movement.created_by_user_id,
      'approved',
      'تمت الموافقة على الحركة من قبل ' || COALESCE(v_customer.name, 'مستخدم'),
      v_movement.movement_number,
      v_movement.amount,
      v_movement.currency,
      v_customer.name,
      p_user_name, -- actor_name
      v_movement.movement_type,
      NULL -- extra_data
    );
  END IF;

  -- إذا كانت هناك حركة مرآة، تحديث حالتها أيضاً
  IF v_movement.mirror_movement_id IS NOT NULL THEN
    UPDATE account_movements
    SET 
      approval_status = 'approved',
      pending_approval = false,
      approved_by_user_id = v_user_id,
      approved_at = now()
    WHERE id = v_movement.mirror_movement_id;
  END IF;

  v_result := json_build_object(
    'success', true,
    'message', 'تمت الموافقة على الحركة بنجاح',
    'movement_id', p_movement_id
  );

  RETURN v_result;
END;
$$;

-- ============================================================
-- 4. تحديث void_movement_and_mirror لتمرير البيانات الكاملة
-- ============================================================

CREATE OR REPLACE FUNCTION void_movement_and_mirror(
  p_movement_id uuid,
  p_user_name text,
  p_reason text DEFAULT 'رفض الحركة'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_movement record;
  v_customer record;
  v_mirror_movement record;
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

  -- الحصول على بيانات العميل
  SELECT * INTO v_customer
  FROM customers
  WHERE id = v_movement.customer_id;

  -- إلغاء الحركة
  UPDATE account_movements
  SET 
    is_voided = true,
    voided_at = now(),
    voided_by_user_id = v_user_id,
    void_reason = p_reason
  WHERE id = p_movement_id;

  -- إلغاء الحركة المرآة إذا وجدت
  IF v_movement.mirror_movement_id IS NOT NULL THEN
    SELECT * INTO v_mirror_movement
    FROM account_movements
    WHERE id = v_movement.mirror_movement_id;

    UPDATE account_movements
    SET 
      is_voided = true,
      voided_at = now(),
      voided_by_user_id = v_user_id,
      void_reason = p_reason
    WHERE id = v_movement.mirror_movement_id;

    -- إنشاء إشعار للطرف الآخر مع البيانات الكاملة
    IF v_mirror_movement.user_id IS NOT NULL THEN
      PERFORM create_notification(
        v_movement.mirror_movement_id,
        v_mirror_movement.user_id,
        'rejected',
        'تم رفض الحركة من قبل ' || COALESCE(v_customer.name, 'مستخدم'),
        v_movement.movement_number,
        v_movement.amount,
        v_movement.currency,
        v_customer.name,
        p_user_name, -- actor_name
        v_movement.movement_type,
        json_build_object('reason', p_reason) -- extra_data
      );
    END IF;
  END IF;

  -- إنشاء إشعار للمنشئ إذا كان مختلفاً مع البيانات الكاملة
  IF v_movement.created_by_user_id IS NOT NULL AND v_movement.created_by_user_id != v_user_id THEN
    PERFORM create_notification(
      p_movement_id,
      v_movement.created_by_user_id,
      'rejected',
      'تم رفض الحركة من قبل ' || p_user_name,
      v_movement.movement_number,
      v_movement.amount,
      v_movement.currency,
      v_customer.name,
      p_user_name, -- actor_name
      v_movement.movement_type,
      json_build_object('reason', p_reason) -- extra_data
    );
  END IF;

  v_result := json_build_object(
    'success', true,
    'message', 'تم رفض الحركة بنجاح',
    'movement_id', p_movement_id,
    'mirror_movement_id', v_movement.mirror_movement_id
  );

  RETURN v_result;
END;
$$;

-- ============================================================
-- 5. إصلاح البيانات الموجودة في الإشعارات غير المقروءة
-- ============================================================

UPDATE movement_notifications mn
SET 
  amount = am.amount,
  currency = am.currency,
  customer_name = c.name,
  movement_type = am.movement_type,
  movement_number = am.movement_number
FROM account_movements am
LEFT JOIN customers c ON am.customer_id = c.id
WHERE mn.movement_id = am.id
  AND mn.is_read = false
  AND (mn.amount IS NULL OR mn.currency IS NULL OR mn.customer_name IS NULL);
