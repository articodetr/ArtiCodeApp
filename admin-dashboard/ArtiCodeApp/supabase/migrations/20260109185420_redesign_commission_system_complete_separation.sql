/*
  # إعادة تصميم نظام العمولات - فصل كامل عن حسابات العملاء

  ## المبدأ الأساسي
  العمولة لا تظهر أبداً في حسابات العملاء العاديين، فقط في حساب الأرباح والخسائر.

  ## السيناريوهات الثلاثة

  ### السيناريو 1: العمولة للمرسل
  مثال: جلال → عماد، مبلغ 5000، عمولة 120 لجلال
  - جلال: يُخصم منه 4880 فقط (5000 - 120)
  - عماد: يصله 5000
  - الأرباح والخسائر: يدفع 120 (حركة outgoing)

  ### السيناريو 2: العمولة للمستلم
  مثال: جلال → عماد، مبلغ 5000، عمولة 120 لعماد
  - جلال: يُخصم منه 5000
  - عماد: يصله 5120 (5000 + 120)
  - الأرباح والخسائر: يدفع 120 (حركة outgoing)

  ### السيناريو 3: العمولة للأرباح والخسائر
  مثال: جلال → عماد، مبلغ 5000، عمولة 120 للأرباح
  - جلال: يُخصم منه 5000
  - عماد: يصله 4880 (5000 - 120)
  - الأرباح والخسائر: يستلم 120 (حركة incoming)

  ## التغييرات
  1. حذف الـ trigger القديم للعمولات
  2. إنشاء trigger جديد يسجل العمولة فقط في حساب الأرباح والخسائر
  3. تحديث دالة create_internal_transfer
  4. تحديث الـ views لعرض المبالغ الصحيحة
*/

-- ===================================
-- Step 1: حذف الـ trigger والدوال القديمة
-- ===================================
DROP TRIGGER IF EXISTS record_commission_movement_trigger ON account_movements;
DROP TRIGGER IF EXISTS record_commission_for_profit_loss_trigger ON account_movements;
DROP FUNCTION IF EXISTS record_commission_movement() CASCADE;
DROP FUNCTION IF EXISTS record_commission_for_profit_loss_only() CASCADE;
DROP FUNCTION IF EXISTS create_internal_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, UUID) CASCADE;

-- ===================================
-- Step 2: إنشاء trigger جديد للعمولات
-- ===================================
CREATE OR REPLACE FUNCTION record_commission_for_profit_loss_only()
RETURNS TRIGGER AS $$
DECLARE
  profit_loss_account_id UUID;
  commission_movement_id UUID;
  commission_notes TEXT;
BEGIN
  -- تحقق من وجود عمولة
  IF NEW.commission IS NULL OR NEW.commission = 0 THEN
    RETURN NEW;
  END IF;

  -- تجاهل حركات العمولة المنفصلة
  IF NEW.is_commission_movement = true THEN
    RETURN NEW;
  END IF;

  -- تجاهل التحديثات
  IF TG_OP = 'UPDATE' THEN
    RETURN NEW;
  END IF;

  -- الحصول على حساب الأرباح والخسائر
  SELECT id INTO profit_loss_account_id
  FROM customers
  WHERE is_profit_loss_account = true
  LIMIT 1;

  IF profit_loss_account_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- تحديد نوع الحركة والملاحظات حسب متلقي العمولة
  IF NEW.commission_recipient_id = profit_loss_account_id THEN
    -- العمولة تذهب للأرباح والخسائر (incoming)
    commission_notes := format(
      'عمولة من تحويل %s → %s بمبلغ %s %s',
      COALESCE(NEW.sender_name, 'غير محدد'),
      COALESCE(NEW.beneficiary_name, 'غير محدد'),
      NEW.commission,
      NEW.commission_currency
    );

    INSERT INTO account_movements (
      customer_id,
      movement_type,
      amount,
      currency,
      notes,
      is_commission_movement,
      related_commission_movement_id,
      commission,
      commission_currency
    ) VALUES (
      profit_loss_account_id,
      'incoming',
      NEW.commission,
      NEW.commission_currency,
      commission_notes,
      true,
      NEW.id,
      0,
      NEW.commission_currency
    ) RETURNING id INTO commission_movement_id;

  ELSE
    -- العمولة تذهب للمرسل أو المستلم (outgoing من الأرباح)
    commission_notes := format(
      'دفع عمولة لـ %s من تحويل %s → %s بمبلغ %s %s',
      CASE 
        WHEN NEW.commission_recipient_id = NEW.from_customer_id THEN COALESCE(NEW.sender_name, 'المرسل')
        WHEN NEW.commission_recipient_id = NEW.to_customer_id THEN COALESCE(NEW.beneficiary_name, 'المستلم')
        ELSE 'غير محدد'
      END,
      COALESCE(NEW.sender_name, 'غير محدد'),
      COALESCE(NEW.beneficiary_name, 'غير محدد'),
      NEW.commission,
      NEW.commission_currency
    );

    INSERT INTO account_movements (
      customer_id,
      movement_type,
      amount,
      currency,
      notes,
      is_commission_movement,
      related_commission_movement_id,
      commission,
      commission_currency
    ) VALUES (
      profit_loss_account_id,
      'outgoing',
      NEW.commission,
      NEW.commission_currency,
      commission_notes,
      true,
      NEW.id,
      0,
      NEW.commission_currency
    ) RETURNING id INTO commission_movement_id;
  END IF;

  -- حفظ معرف حركة العمولة
  NEW.related_commission_movement_id := commission_movement_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- إنشاء الـ trigger الجديد
CREATE TRIGGER record_commission_for_profit_loss_trigger
  BEFORE INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_for_profit_loss_only();

-- ===================================
-- Step 3: إنشاء دالة التحويل الداخلي الجديدة
-- ===================================
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

  -- توليد رقم التحويل
  v_transfer_number := 'TR-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 8);

  -- حساب المبالغ حسب متلقي العمولة
  IF v_final_commission_recipient = p_from_customer_id THEN
    -- العمولة للمرسل: يُخصم منه المبلغ بعد خصم العمولة
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

  -- حركة المرسل (outgoing)
  INSERT INTO account_movements (
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
    p_from_customer_id,
    'outgoing',
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

  -- حركة المستلم (incoming)
  INSERT INTO account_movements (
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
    p_to_customer_id,
    'incoming',
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