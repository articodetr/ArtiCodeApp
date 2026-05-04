/*
  # إصلاح منطق العمولة للتحويل الداخلي
  
  ## المشكلة السابقة
  العمولة كانت تُضاف كحركات منفصلة بدون تأثير صحيح على المبالغ الأساسية
  
  ## الحل الجديد
  
  ### السيناريو: جلال يرسل لعماد 5000$ والعمولة 50$
  
  **الحالة 1: العمولة تذهب لعماد (المستلم)**
  - جلال: outgoing بمبلغ 5000$
  - عماد: incoming بمبلغ 5000$
  - الأرباح: outgoing بمبلغ 50$ (تدفع)
  - عماد: incoming بمبلغ 50$ (عمولة إضافية)
  - النتيجة: جلال -5000$، عماد +5050$، الأرباح -50$
  
  **الحالة 2: العمولة تذهب للأرباح والخسائر**
  - جلال: outgoing بمبلغ 5000$
  - عماد: incoming بمبلغ 4950$ (المبلغ ناقص العمولة)
  - الأرباح: incoming بمبلغ 50$ (تحصل على العمولة)
  - النتيجة: جلال -5000$، عماد +4950$، الأرباح +50$
  
  **الحالة 3: العمولة تذهب لجلال (المرسل)**
  - جلال: outgoing بمبلغ 5000$
  - عماد: incoming بمبلغ 5000$
  - الأرباح: outgoing بمبلغ 50$ (تدفع)
  - جلال: incoming بمبلغ 50$ (عمولة مرتجعة)
  - النتيجة: جلال -4950$، عماد +5000$، الأرباح -50$
  
  ## التغييرات
  
  1. تعديل دالة `create_internal_transfer`:
     - في حالة `commission_recipient_id = NULL`، المستلم يحصل على (amount - commission)
     - في الحالات الأخرى، المبالغ تبقى أساسية والعمولة تُضاف عبر الـ trigger
  
  2. تعديل trigger `record_commission_to_profit_loss`:
     - الحالة NULL: إنشاء incoming للأرباح بمبلغ العمولة (تم تطبيقها في المبلغ الأساسي)
     - الحالات الأخرى: إنشاء outgoing من الأرباح و incoming للمستلم
*/

-- 1. حذف الدالة القديمة
DROP FUNCTION IF EXISTS create_internal_transfer(uuid, uuid, decimal, text, text, decimal, text, uuid);

-- 2. إنشاء دالة create_internal_transfer محدّثة
CREATE OR REPLACE FUNCTION create_internal_transfer(
  p_from_customer_id uuid,
  p_to_customer_id uuid,
  p_amount decimal,
  p_currency text,
  p_notes text DEFAULT NULL,
  p_commission decimal DEFAULT NULL,
  p_commission_currency text DEFAULT 'USD',
  p_commission_recipient_id uuid DEFAULT NULL
)
RETURNS TABLE (
  from_movement_id uuid,
  to_movement_id uuid,
  success boolean,
  message text
) AS $$
DECLARE
  v_from_movement_id uuid;
  v_to_movement_id uuid;
  v_from_movement_number text;
  v_to_movement_number text;
  v_transfer_direction text;
  v_from_customer_name text;
  v_to_customer_name text;
  v_actual_to_amount decimal;
BEGIN
  -- التحقق من صحة البيانات
  IF p_amount <= 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'المبلغ يجب أن يكون أكبر من صفر'::text;
    RETURN;
  END IF;

  -- التحقق من صحة العمولة إذا كانت موجودة
  IF p_commission IS NOT NULL AND p_commission < 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العمولة يجب أن تكون صفر أو أكبر'::text;
    RETURN;
  END IF;

  -- التحقق من عدم التحويل لنفس الطرف
  IF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NOT NULL AND p_from_customer_id = p_to_customer_id THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'لا يمكن التحويل لنفس العميل'::text;
    RETURN;
  END IF;

  -- التحقق من صحة مستلم العمولة
  IF p_commission_recipient_id IS NOT NULL THEN
    IF p_commission_recipient_id != p_from_customer_id AND p_commission_recipient_id != p_to_customer_id THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'مستلم العمولة يجب أن يكون أحد أطراف التحويل'::text;
      RETURN;
    END IF;
  END IF;

  -- تحديد اتجاه التحويل
  IF p_from_customer_id IS NULL AND p_to_customer_id IS NOT NULL THEN
    v_transfer_direction := 'shop_to_customer';
  ELSIF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NULL THEN
    v_transfer_direction := 'customer_to_shop';
  ELSIF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NOT NULL THEN
    v_transfer_direction := 'customer_to_customer';
  ELSE
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'يجب تحديد طرف واحد على الأقل'::text;
    RETURN;
  END IF;

  -- الحصول على أسماء الأطراف
  IF p_from_customer_id IS NOT NULL THEN
    SELECT name INTO v_from_customer_name FROM customers WHERE id = p_from_customer_id;
    IF v_from_customer_name IS NULL THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العميل المُحوِّل غير موجود'::text;
      RETURN;
    END IF;
  ELSE
    v_from_customer_name := 'المحل';
  END IF;

  IF p_to_customer_id IS NOT NULL THEN
    SELECT name INTO v_to_customer_name FROM customers WHERE id = p_to_customer_id;
    IF v_to_customer_name IS NULL THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العميل المُحوَّل إليه غير موجود'::text;
      RETURN;
    END IF;
  ELSE
    v_to_customer_name := 'المحل';
  END IF;

  -- حساب المبلغ الفعلي للمستلم
  -- في حالة commission_recipient_id = NULL، المبلغ ينقص بمقدار العمولة
  IF p_commission_recipient_id IS NULL AND p_commission IS NOT NULL AND p_commission > 0 THEN
    v_actual_to_amount := p_amount - p_commission;
  ELSE
    v_actual_to_amount := p_amount;
  END IF;

  -- البدء بـ transaction
  BEGIN
    -- حالة 1: المحل → عميل (تسليم للعميل)
    IF v_transfer_direction = 'shop_to_customer' THEN
      v_to_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        sender_name,
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
      ) VALUES (
        v_to_movement_number,
        p_to_customer_id,
        'incoming',
        v_actual_to_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        NULL,
        p_to_customer_id,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name,
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_to_movement_id;

      RETURN QUERY SELECT NULL::uuid, v_to_movement_id, true, 'تم التحويل بنجاح من المحل إلى ' || v_to_customer_name::text;
      RETURN;

    -- حالة 2: عميل → المحل (استلام من العميل)
    ELSIF v_transfer_direction = 'customer_to_shop' THEN
      v_from_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        sender_name,
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
      ) VALUES (
        v_from_movement_number,
        p_from_customer_id,
        'outgoing',
        p_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        NULL,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name,
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      RETURN QUERY SELECT v_from_movement_id, NULL::uuid, true, 'تم التحويل بنجاح من ' || v_from_customer_name || ' إلى المحل'::text;
      RETURN;

    -- حالة 3: عميل → عميل (إنشاء حركتين مترابطتين)
    ELSIF v_transfer_direction = 'customer_to_customer' THEN
      v_from_movement_number := generate_movement_number();
      v_to_movement_number := generate_movement_number();

      -- حركة العميل المُحوِّل (outgoing) - دائماً بالمبلغ الأساسي
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        sender_name,
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
      ) VALUES (
        v_from_movement_number,
        p_from_customer_id,
        'outgoing',
        p_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        p_to_customer_id,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name,
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      -- حركة العميل المُحوَّل إليه (incoming) - بالمبلغ المعدّل في حالة NULL
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        related_transfer_id,
        sender_name,
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
      ) VALUES (
        v_to_movement_number,
        p_to_customer_id,
        'incoming',
        v_actual_to_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        p_to_customer_id,
        v_transfer_direction,
        v_from_movement_id,
        v_from_customer_name,
        v_to_customer_name,
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_to_movement_id;

      -- ربط الحركة الأولى بالثانية
      UPDATE account_movements
      SET related_transfer_id = v_to_movement_id
      WHERE id = v_from_movement_id;

      RETURN QUERY SELECT v_from_movement_id, v_to_movement_id, true, 'تم التحويل بنجاح من ' || v_from_customer_name || ' إلى ' || v_to_customer_name::text;
      RETURN;
    END IF;

  EXCEPTION
    WHEN OTHERS THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'خطأ في إنشاء التحويل: ' || SQLERRM::text;
      RETURN;
  END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION create_internal_transfer IS 'دالة لإنشاء تحويل داخلي - في حالة commission_recipient_id = NULL، المبلغ المستلم = amount - commission';
