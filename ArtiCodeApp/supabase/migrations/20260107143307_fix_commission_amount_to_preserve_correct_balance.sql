/*
  # إصلاح مبلغ الحركة للحفاظ على صحة الأرصدة
  
  ## المشكلة
  
  عندما نسجل في الحركة الأساسية (amount - commission) بدلاً من amount الكامل:
  - الأرصدة النهائية تصبح خاطئة
  - مثال: جلال لديه 5000$، يحول 5000$ مع عمولة 50$ لصالحه
    - المسجل: outgoing 4950 + incoming 50 = -4900
    - الرصيد النهائي: 5000 - 4900 = 100$ ✗ (خطأ!)
    - الصحيح: 5000 - 5000 + 50 = 50$ ✓
  
  ## الحل
  
  1. **في قاعدة البيانات**: تسجيل المبلغ الكامل دائماً
  2. **في التطبيق**: عرض المبلغ بعد خصم العمولة إذا كانت لصالح المُحوِّل
  
  ## صيغة العرض في التطبيق
  
  ```typescript
  // للحركة من نوع outgoing مع عمولة لصالح المُحوِّل:
  const displayAmount = movement.commission_recipient_id === movement.from_customer_id
    ? movement.amount - movement.commission
    : movement.amount;
  ```
  
  هذا يحافظ على:
  - صحة الأرصدة في قاعدة البيانات
  - وضوح العرض للمستخدم (يرى المبلغ الصافي الذي خرج فعلياً)
*/

-- حذف البيانات الاختبارية
TRUNCATE account_movements CASCADE;
DELETE FROM customers WHERE phone IN ('777123456', '777654321');

-- تحديث دالة create_internal_transfer
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
  IF p_amount <= 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'المبلغ يجب أن يكون أكبر من صفر'::text;
    RETURN;
  END IF;

  IF p_commission IS NOT NULL AND p_commission < 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العمولة يجب أن تكون صفر أو أكبر'::text;
    RETURN;
  END IF;

  IF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NOT NULL AND p_from_customer_id = p_to_customer_id THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'لا يمكن التحويل لنفس العميل'::text;
    RETURN;
  END IF;

  IF p_commission_recipient_id IS NOT NULL THEN
    IF p_commission_recipient_id != p_from_customer_id AND p_commission_recipient_id != p_to_customer_id THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'مستلم العمولة يجب أن يكون أحد أطراف التحويل'::text;
      RETURN;
    END IF;
  END IF;

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

  -- حساب المبلغ الفعلي للمستلم فقط
  IF p_commission IS NOT NULL AND p_commission > 0 THEN
    IF p_commission_recipient_id IS NULL THEN
      v_actual_to_amount := p_amount - p_commission;
    ELSIF p_commission_recipient_id = p_to_customer_id THEN
      v_actual_to_amount := p_amount + p_commission;
    ELSE
      v_actual_to_amount := p_amount;
    END IF;
  ELSE
    v_actual_to_amount := p_amount;
  END IF;

  BEGIN
    IF v_transfer_direction = 'shop_to_customer' THEN
      v_to_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_to_movement_number, p_to_customer_id, 'incoming', v_actual_to_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        NULL, p_to_customer_id, v_transfer_direction,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_to_movement_id;

      RETURN QUERY SELECT NULL::uuid, v_to_movement_id, true, 'تم التحويل بنجاح من المحل إلى ' || v_to_customer_name::text;
      RETURN;

    ELSIF v_transfer_direction = 'customer_to_shop' THEN
      v_from_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_from_movement_number, p_from_customer_id, 'outgoing', p_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id, NULL, v_transfer_direction,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      RETURN QUERY SELECT v_from_movement_id, NULL::uuid, true, 'تم التحويل بنجاح من ' || v_from_customer_name || ' إلى المحل'::text;
      RETURN;

    ELSIF v_transfer_direction = 'customer_to_customer' THEN
      v_from_movement_number := generate_movement_number();
      v_to_movement_number := generate_movement_number();

      -- حركة المُحوِّل: دائماً المبلغ الكامل
      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_from_movement_number, p_from_customer_id, 'outgoing', p_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id, p_to_customer_id, v_transfer_direction,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      -- حركة المستلم: حسب مستلم العمولة
      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction, related_transfer_id,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_to_movement_number, p_to_customer_id, 'incoming', v_actual_to_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id, p_to_customer_id, v_transfer_direction, v_from_movement_id,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_to_movement_id;

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

COMMENT ON FUNCTION create_internal_transfer IS 'إنشاء تحويل داخلي - تسجيل المبلغ الكامل دائماً، العرض في التطبيق يُحسب: (amount - commission) عند commission_recipient_id=from';
