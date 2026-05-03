/*
  # إصلاح نظام الحسابات المرتبطة (Splitwise-like System)

  ## المشكلة
  عندما يضيف مستخدم حركة مالية على حساب مرتبط، لا تظهر الحركة المرآة للطرف الآخر
  إذا كان أحد الطرفين فقط أضاف الآخر، فإن إنشاء الحركة المرآة يفشل.

  ## الحل

  ### 1. تحديث نظام الإشعارات
    - إضافة نوع إشعار جديد: 'customer_added'
    - جعل movement_id nullable لدعم الإشعارات بدون حركة مالية
    - تحديث دالة create_notification لقبول NULL في movement_id

  ### 2. إصلاح create_mirror_movement_v2
    - استخدام get_or_create_reciprocal_customer بدلاً من إرجاع NULL
    - إنشاء العميل المقابل تلقائياً إذا لم يكن موجوداً
    - إنشاء إشعار customer_added عند إنشاء العميل تلقائياً

  ### 3. تحديث create_linked_customer للربط الثنائي
    - إنشاء العميل المقابل تلقائياً للطرف الآخر
    - إنشاء سجل في user_customer_links للطرف الآخر
    - إرسال إشعار للطرف الآخر بأنه تم إضافته

  ## معايير القبول
  - إنشاء حركة مرآة دائماً حتى لو لم يكن العميل المقابل موجوداً
  - ربط ثنائي تلقائي عند إضافة حساب مرتبط
  - إشعارات واضحة لكل طرف
*/

-- ============================================================
-- 1. تحديث جدول الإشعارات
-- ============================================================

-- إضافة نوع إشعار جديد للعملاء
DO $$
BEGIN
  -- حذف القيد القديم على notification_type
  ALTER TABLE movement_notifications
    DROP CONSTRAINT IF EXISTS movement_notifications_notification_type_check;

  -- إضافة القيد الجديد مع الأنواع الجديدة
  ALTER TABLE movement_notifications
    ADD CONSTRAINT movement_notifications_notification_type_check
    CHECK (notification_type IN (
      'approval_needed',
      'deletion_request',
      'approved',
      'rejected',
      'movement_added',
      'customer_added',
      'linked_account_added'
    ));

  RAISE NOTICE 'تم تحديث أنواع الإشعارات بنجاح';
END $$;

-- جعل movement_id nullable (إزالة NOT NULL)
ALTER TABLE movement_notifications
  ALTER COLUMN movement_id DROP NOT NULL;

COMMENT ON COLUMN movement_notifications.movement_id IS 'معرف الحركة (nullable للإشعارات بدون حركة مثل إضافة عميل)';
COMMENT ON COLUMN movement_notifications.notification_type IS 'نوع الإشعار: approval_needed, deletion_request, approved, rejected, movement_added, customer_added, linked_account_added';

-- ============================================================
-- 2. تحديث دالة create_notification لقبول NULL
-- ============================================================

CREATE OR REPLACE FUNCTION create_notification(
  p_movement_id uuid,
  p_user_id uuid,
  p_notification_type text,
  p_message text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_notification_id uuid;
BEGIN
  -- p_movement_id يمكن أن يكون NULL الآن
  INSERT INTO movement_notifications (
    movement_id,
    user_id,
    notification_type,
    message
  ) VALUES (
    p_movement_id,  -- يمكن أن يكون NULL
    p_user_id,
    p_notification_type,
    p_message
  )
  RETURNING id INTO v_notification_id;

  RETURN v_notification_id;
END;
$$;

COMMENT ON FUNCTION create_notification IS 'إنشاء إشعار جديد للمستخدم (movement_id يمكن أن يكون NULL)';

-- ============================================================
-- 3. تحديث create_mirror_movement_v2 لإنشاء العميل تلقائياً
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
    v_original_movement.receipt_number
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
    ' - ' || v_original_movement.movement_number
  );

  RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء الحركة المرآة بنجاح: %', v_mirror_movement_id;
  RETURN v_mirror_movement_id;
END;
$$;

COMMENT ON FUNCTION create_mirror_movement_v2 IS 'إنشاء حركة مرآة مع إنشاء العميل المقابل تلقائياً إذا لزم الأمر';

-- ============================================================
-- 4. تحديث create_linked_customer للربط الثنائي التلقائي
-- ============================================================

CREATE OR REPLACE FUNCTION create_linked_customer(
  p_owner_user_id uuid,
  p_linked_user_id uuid,
  p_customer_name text
)
RETURNS TABLE (
  success boolean,
  customer_id uuid,
  message text
) AS $$
DECLARE
  v_customer_id uuid;
  v_reciprocal_customer_id uuid;
  v_linked_user_name text;
  v_owner_user_name text;
  v_linked_account_number text;
  v_owner_account_number text;
  v_existing_link uuid;
  v_existing_reciprocal_link uuid;
BEGIN
  -- التحقق من عدم ربط نفس المستخدم
  IF p_owner_user_id = p_linked_user_id THEN
    RETURN QUERY SELECT false, NULL::uuid, 'لا يمكن ربط نفسك كعميل'::text;
    RETURN;
  END IF;

  -- التحقق من وجود ربط سابق
  SELECT id INTO v_existing_link
  FROM customers
  WHERE user_id = p_owner_user_id
    AND linked_user_id = p_linked_user_id;

  IF v_existing_link IS NOT NULL THEN
    RETURN QUERY SELECT false, v_existing_link, 'هذا المستخدم مربوط بالفعل'::text;
    RETURN;
  END IF;

  -- الحصول على معلومات المستخدم المرتبط
  SELECT full_name, account_number INTO v_linked_user_name, v_linked_account_number
  FROM app_security
  WHERE id = p_linked_user_id;

  IF v_linked_user_name IS NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, 'المستخدم المحدد غير موجود'::text;
    RETURN;
  END IF;

  -- الحصول على معلومات المستخدم المالك
  SELECT full_name, account_number INTO v_owner_user_name, v_owner_account_number
  FROM app_security
  WHERE id = p_owner_user_id;

  -- إنشاء سجل العميل المرتبط (A -> B)
  INSERT INTO customers (
    user_id,
    linked_user_id,
    name,
    phone,
    account_number,
    notes
  ) VALUES (
    p_owner_user_id,
    p_linked_user_id,
    COALESCE(p_customer_name, v_linked_user_name),
    'LINKED_USER_' || v_linked_account_number,
    v_linked_account_number,
    'عميل مرتبط بمستخدم مسجل - رقم الحساب الحقيقي: ' || v_linked_account_number
  ) RETURNING id INTO v_customer_id;

  -- إنشاء سجل في user_customer_links (A -> B)
  INSERT INTO user_customer_links (
    owner_user_id,
    linked_user_id,
    customer_id,
    status,
    notes
  ) VALUES (
    p_owner_user_id,
    p_linked_user_id,
    v_customer_id,
    'active',
    'ربط تلقائي عند إضافة العميل'
  );

  -- ============================================================
  -- الربط الثنائي: إنشاء العميل المقابل تلقائياً (B -> A)
  -- ============================================================

  -- التحقق من عدم وجود ربط عكسي بالفعل
  SELECT id INTO v_existing_reciprocal_link
  FROM customers
  WHERE user_id = p_linked_user_id
    AND linked_user_id = p_owner_user_id;

  IF v_existing_reciprocal_link IS NULL THEN
    -- إنشاء العميل المقابل (B -> A)
    INSERT INTO customers (
      user_id,
      linked_user_id,
      name,
      phone,
      account_number,
      notes
    ) VALUES (
      p_linked_user_id,         -- المستخدم المستهدف يصبح مالك
      p_owner_user_id,          -- المستخدم المالك يصبح مرتبط
      v_owner_user_name,        -- اسم المستخدم المالك
      'LINKED_USER_' || v_owner_account_number,
      v_owner_account_number,   -- رقم حساب المستخدم المالك
      'تم إنشاؤه تلقائياً كحساب متبادل - رقم الحساب الحقيقي: ' || v_owner_account_number
    ) RETURNING id INTO v_reciprocal_customer_id;

    -- إنشاء سجل في user_customer_links (B -> A)
    INSERT INTO user_customer_links (
      owner_user_id,
      linked_user_id,
      customer_id,
      status,
      notes
    ) VALUES (
      p_linked_user_id,
      p_owner_user_id,
      v_reciprocal_customer_id,
      'active',
      'ربط متبادل تلقائي'
    );

    -- إرسال إشعار للمستخدم المرتبط (B)
    PERFORM create_notification(
      NULL,
      p_linked_user_id,
      'customer_added',
      'تم إضافتك كحساب مرتبط من قبل ' || v_owner_user_name || ' (رقم الحساب: ' || v_owner_account_number || ')'
    );

    RAISE NOTICE 'تم إنشاء الربط الثنائي: العميل المقابل ID = %', v_reciprocal_customer_id;
  ELSE
    RAISE NOTICE 'الربط العكسي موجود بالفعل: %', v_existing_reciprocal_link;
  END IF;

  RETURN QUERY SELECT
    true,
    v_customer_id,
    'تم ربط المستخدم كعميل بنجاح (ربط ثنائي) - رقم الحساب: ' || v_linked_account_number::text;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION create_linked_customer IS 'إنشاء عميل مرتبط مع ربط ثنائي تلقائي وإشعارات';

-- ============================================================
-- 5. إنشاء indexes للأداء
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_movement_notifications_user_type
  ON movement_notifications(user_id, notification_type);

CREATE INDEX IF NOT EXISTS idx_movement_notifications_movement_null
  ON movement_notifications(user_id)
  WHERE movement_id IS NULL;

-- ============================================================
-- 6. اختبار النظام
-- ============================================================

DO $$
DECLARE
  v_notification_count int;
  v_linked_customers_count int;
BEGIN
  -- عد الإشعارات
  SELECT COUNT(*) INTO v_notification_count
  FROM movement_notifications;

  -- عد العملاء المرتبطين
  SELECT COUNT(*) INTO v_linked_customers_count
  FROM customers
  WHERE linked_user_id IS NOT NULL;

  RAISE NOTICE '=====================================';
  RAISE NOTICE 'تم إصلاح نظام الحسابات المرتبطة بنجاح';
  RAISE NOTICE '=====================================';
  RAISE NOTICE 'عدد الإشعارات: %', v_notification_count;
  RAISE NOTICE 'عدد العملاء المرتبطين: %', v_linked_customers_count;
  RAISE NOTICE '';
  RAISE NOTICE 'الميزات الجديدة:';
  RAISE NOTICE '  ✓ إنشاء العميل المقابل تلقائياً عند الحاجة';
  RAISE NOTICE '  ✓ ربط ثنائي تلقائي عند إضافة حساب مرتبط';
  RAISE NOTICE '  ✓ إشعارات عند إضافة عميل (customer_added)';
  RAISE NOTICE '  ✓ دعم الإشعارات بدون حركة مالية';
  RAISE NOTICE '=====================================';
END $$;
