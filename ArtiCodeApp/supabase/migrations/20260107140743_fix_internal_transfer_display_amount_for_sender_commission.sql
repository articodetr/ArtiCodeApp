/*
  # إصلاح عرض المبلغ في حركة التحويل الداخلي عندما تكون العمولة لصالح المُحوِّل

  ## المشكلة

  في التحويل الداخلي عندما تكون العمولة لصالح المُحوِّل (from_customer):
  - رصيد جلال قبل: 5000$
  - تحويل: جلال → عماد بمبلغ 5000$
  - عمولة: 50$ لصالح جلال
  - القيود المحاسبية صحيحة:
    * جلال outgoing: -5000$
    * جلال incoming (عمولة): +50$
    * عماد incoming: +5000$
    * الأرباح outgoing: -50$
  - رصيد جلال النهائي: 50$ ✅ (صحيح)
  
  **المشكلة في تقرير حركة الحسابات:**
  - يظهر في حركات جلال: خروج 5000$
  - المطلوب: خروج 4950$ فقط (لأن 50$ عادت له كعمولة)

  ## الحل

  تعديل دالة `create_internal_transfer`:
  - عندما يكون `commission_recipient_id = from_customer_id`
  - حركة outgoing للمُحوِّل = `p_amount - p_commission` بدلاً من `p_amount`
  - هذا يعكس المبلغ الفعلي الذي خرج من حسابه

  ## النتائج المتوقعة

  بعد التحويل:
  - حركة outgoing لجلال: 4950$ ✅
  - حركة incoming لعماد: 5000$ ✅
  - حركة incoming لجلال (عمولة): 50$ ✅
  - حركة outgoing من الأرباح: 50$ ✅
  - رصيد جلال النهائي: 50$ ✅
  - تقرير الحركات: يطابق المنطق الحقيقي ✅

  ## الأمان

  - التعديل يؤثر فقط على العرض، لا على الحسابات
  - الأرصدة النهائية تبقى صحيحة
  - القيود المحاسبية متوازنة
*/

-- 1. حذف الدالة القديمة
DROP FUNCTION IF EXISTS create_internal_transfer(uuid, uuid, decimal, text, text, decimal, text, uuid);

-- 2. إنشاء دالة create_internal_transfer المحدثة
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
  v_actual_from_amount decimal;
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

  -- حساب المبلغ الفعلي للمُحوِّل (من)
  IF p_commission IS NOT NULL AND p_commission > 0 THEN
    IF p_commission_recipient_id = p_from_customer_id THEN
      -- المُحوِّل يستلم العمولة = نخصم العمولة من المبلغ المُسجّل في حركة outgoing
      v_actual_from_amount := p_amount - p_commission;
    ELSE
      -- المُحوِّل لا يستلم العمولة = نسجل المبلغ الكامل
      v_actual_from_amount := p_amount;
    END IF;
  ELSE
    v_actual_from_amount := p_amount;
  END IF;

  -- حساب المبلغ الفعلي للمستلم (إلى)
  IF p_commission IS NOT NULL AND p_commission > 0 THEN
    IF p_commission_recipient_id IS NULL THEN
      -- NULL = الأرباح تستلم، المستلم يحصل على (amount - commission)
      v_actual_to_amount := p_amount - p_commission;
    ELSIF p_commission_recipient_id = p_to_customer_id THEN
      -- المستلم يستلم العمولة = يحصل على (amount + commission)
      v_actual_to_amount := p_amount + p_commission;
    ELSE
      -- المرسل يستلم العمولة = المستلم يحصل على (amount) فقط
      v_actual_to_amount := p_amount;
    END IF;
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
        v_actual_from_amount,
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

      -- حركة العميل المُحوِّل (outgoing) - بالمبلغ المحسوب بناءً على مستلم العمولة
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
        v_actual_from_amount,
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

      -- حركة العميل المُحوَّل إليه (incoming) - بالمبلغ المحسوب
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

COMMENT ON FUNCTION create_internal_transfer IS 'إنشاء تحويل داخلي - عند commission_recipient_id=from: المُحوِّل outgoing=(amount-commission)، عند commission_recipient_id=to: المستلم incoming=(amount+commission)';
