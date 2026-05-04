/*
  # إصلاح اتجاه التحويل الداخلي

  ## المشكلة
  المنطق الحالي معكوس:
  - المرسل: outgoing (خطأ)
  - المستلم: incoming (خطأ)

  ## الحل الصحيح
  من وجهة نظر المحل:
  - المرسل يدفع للمحل = incoming (استلام)
  - المحل يدفع للمستلم = outgoing (تسليم)

  ## مثال
  - لنا عند جلال 5000 دولار
  - نحول 5000 من جلال إلى عماد
  - النتيجة: لنا عند جلال 10000 دولار (استلمنا منه 5000)
*/

DROP FUNCTION IF EXISTS create_internal_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, UUID) CASCADE;

CREATE OR REPLACE FUNCTION create_internal_transfer(
  p_from_customer_id UUID,
  p_to_customer_id UUID,
  p_amount NUMERIC,
  p_currency TEXT,
  p_notes TEXT DEFAULT NULL,
  p_commission NUMERIC DEFAULT 0,
  p_commission_currency TEXT DEFAULT 'USD',
  p_commission_recipient_id UUID DEFAULT NULL
)
RETURNS TABLE (
  sender_movement_id UUID,
  recipient_movement_id UUID
) AS $$
DECLARE
  v_sender_movement_id UUID;
  v_recipient_movement_id UUID;
  v_sender_name TEXT;
  v_recipient_name TEXT;
  v_transfer_number TEXT;
  v_sender_movement_number TEXT;
  v_recipient_movement_number TEXT;
  v_sender_amount NUMERIC;
  v_recipient_amount NUMERIC;
  v_profit_loss_account_id UUID;
  v_final_commission_recipient UUID;
BEGIN
  -- الحصول على أسماء العملاء
  SELECT name INTO v_sender_name FROM customers WHERE id = p_from_customer_id;
  SELECT name INTO v_recipient_name FROM customers WHERE id = p_to_customer_id;
  
  -- الحصول على حساب الأرباح والخسائر
  SELECT id INTO v_profit_loss_account_id
  FROM customers
  WHERE is_profit_loss_account = true
  LIMIT 1;

  -- تحديد متلقي العمولة (افتراضياً: الأرباح والخسائر)
  v_final_commission_recipient := COALESCE(p_commission_recipient_id, v_profit_loss_account_id);

  -- توليد رقم التحويل وأرقام الحركات
  v_transfer_number := 'TR-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 8);
  v_sender_movement_number := 'MOV-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 8);
  v_recipient_movement_number := 'MOV-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 8);

  -- حساب المبالغ حسب متلقي العمولة
  IF v_final_commission_recipient = p_from_customer_id THEN
    -- العمولة للمرسل: يستلم المبلغ بعد خصم العمولة
    v_sender_amount := p_amount - COALESCE(p_commission, 0);
    v_recipient_amount := p_amount;
  ELSIF v_final_commission_recipient = p_to_customer_id THEN
    -- العمولة للمستلم: يصله المبلغ + العمولة
    v_sender_amount := p_amount;
    v_recipient_amount := p_amount + COALESCE(p_commission, 0);
  ELSE
    -- العمولة للأرباح والخسائر
    v_sender_amount := p_amount;
    v_recipient_amount := p_amount - COALESCE(p_commission, 0);
  END IF;

  -- حركة المرسل (incoming) - المحل يستلم من المرسل
  INSERT INTO account_movements (
    movement_number,
    customer_id,
    movement_type,
    amount,
    currency,
    notes,
    transfer_direction,
    from_customer_id,
    to_customer_id,
    sender_name,
    beneficiary_name,
    transfer_number,
    commission,
    commission_currency,
    commission_recipient_id,
    is_commission_movement
  ) VALUES (
    v_sender_movement_number,
    p_from_customer_id,
    'incoming',
    v_sender_amount,
    p_currency,
    COALESCE(p_notes, format('تحويل داخلي: %s → %s', v_sender_name, v_recipient_name)),
    'sender',
    p_from_customer_id,
    p_to_customer_id,
    v_sender_name,
    v_recipient_name,
    v_transfer_number,
    COALESCE(p_commission, 0),
    p_commission_currency,
    v_final_commission_recipient,
    false
  ) RETURNING id INTO v_sender_movement_id;

  -- حركة المستلم (outgoing) - المحل يسلم للمستلم
  INSERT INTO account_movements (
    movement_number,
    customer_id,
    movement_type,
    amount,
    currency,
    notes,
    transfer_direction,
    from_customer_id,
    to_customer_id,
    related_transfer_id,
    sender_name,
    beneficiary_name,
    transfer_number,
    commission,
    commission_currency,
    commission_recipient_id,
    is_commission_movement
  ) VALUES (
    v_recipient_movement_number,
    p_to_customer_id,
    'outgoing',
    v_recipient_amount,
    p_currency,
    COALESCE(p_notes, format('تحويل داخلي: %s → %s', v_sender_name, v_recipient_name)),
    'recipient',
    p_from_customer_id,
    p_to_customer_id,
    v_sender_movement_id,
    v_sender_name,
    v_recipient_name,
    v_transfer_number,
    COALESCE(p_commission, 0),
    p_commission_currency,
    v_final_commission_recipient,
    false
  ) RETURNING id INTO v_recipient_movement_id;

  -- تحديث related_transfer_id للمرسل
  UPDATE account_movements
  SET related_transfer_id = v_recipient_movement_id
  WHERE id = v_sender_movement_id;

  RETURN QUERY SELECT v_sender_movement_id, v_recipient_movement_id;
END;
$$ LANGUAGE plpgsql;
