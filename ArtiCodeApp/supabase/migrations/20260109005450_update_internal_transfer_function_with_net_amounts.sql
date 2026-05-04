/*
  # تحديث دالة التحويل الداخلي لتطبيق منطق العمولة الجديد
  
  ## الحالات الثلاث للتحويل الداخلي
  
  ### الحالة 1: العمولة لصالح المُرسِل
  - المُرسِل: يُخصم منه (المبلغ - العمولة)
  - المستلم: يستلم المبلغ الكامل
  - P&L: لا تُسجل عليه حركة
  
  ### الحالة 2: العمولة لصالح المستلم
  - المُرسِل: يُخصم منه المبلغ الكامل
  - المستلم: يستلم (المبلغ + العمولة)
  - P&L: تسليم العمولة (outgoing)
  
  ### الحالة 3: العمولة لصالح P&L (الافتراضي)
  - المُرسِل: يُخصم منه المبلغ الكامل
  - المستلم: يستلم (المبلغ - العمولة)
  - P&L: استلام العمولة (incoming)
  
  ## التغييرات
  
  - تحديد المبلغ الصافي لكل طرف بناءً على مستلم العمولة
  - إلغاء الاعتماد على BEFORE INSERT trigger للتحويلات الداخلية
  - حفظ original_amount بشكل صريح
*/

CREATE OR REPLACE FUNCTION create_internal_transfer(
  p_from_customer_id uuid,
  p_to_customer_id uuid,
  p_amount numeric,
  p_currency text,
  p_notes text DEFAULT NULL,
  p_commission numeric DEFAULT NULL,
  p_commission_currency text DEFAULT 'USD',
  p_commission_recipient_id uuid DEFAULT NULL
)
RETURNS TABLE(
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
  v_from_amount numeric;
  v_to_amount numeric;
BEGIN
  -- التحقق من صحة المدخلات
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

  -- تحديد نوع التحويل
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

  -- الحصول على أسماء العملاء
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

  -- حساب المبالغ الصافية بناءً على مستلم العمولة
  -- القاعدة الافتراضية: المبلغ الكامل
  v_from_amount := p_amount;
  v_to_amount := p_amount;

  -- إذا كانت هناك عمولة
  IF p_commission IS NOT NULL AND p_commission > 0 THEN
    IF p_commission_recipient_id IS NULL THEN
      -- الحالة 3: العمولة لـ P&L (الافتراضي)
      -- المُرسِل: يدفع المبلغ الكامل
      -- المستلم: يستلم (المبلغ - العمولة)
      v_to_amount := p_amount - p_commission;
    ELSIF p_commission_recipient_id = p_from_customer_id THEN
      -- الحالة 1: العمولة للمُرسِل
      -- المُرسِل: يدفع (المبلغ - العمولة)
      -- المستلم: يستلم المبلغ الكامل
      v_from_amount := p_amount - p_commission;
    ELSIF p_commission_recipient_id = p_to_customer_id THEN
      -- الحالة 2: العمولة للمستلم
      -- المُرسِل: يدفع المبلغ الكامل
      -- المستلم: يستلم (المبلغ + العمولة)
      v_to_amount := p_amount + p_commission;
    END IF;
  END IF;

  BEGIN
    IF v_transfer_direction = 'shop_to_customer' THEN
      v_to_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, original_amount, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_to_movement_number, p_to_customer_id, 'incoming', p_amount, v_to_amount, p_currency,
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
        movement_number, customer_id, movement_type, original_amount, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_from_movement_number, p_from_customer_id, 'outgoing', p_amount, v_from_amount, p_currency,
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

      -- حركة المُحوِّل
      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, original_amount, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_from_movement_number, p_from_customer_id, 'outgoing', p_amount, v_from_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id, p_to_customer_id, v_transfer_direction,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      -- حركة المستلم
      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, original_amount, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction, related_transfer_id,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_to_movement_number, p_to_customer_id, 'incoming', p_amount, v_to_amount, p_currency,
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

COMMENT ON FUNCTION create_internal_transfer IS 'إنشاء تحويل داخلي مع دعم الحالات الثلاث للعمولة: لصالح المُرسِل، المستلم، أو P&L';
