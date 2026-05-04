/*
  # إصلاح تكرار حركات العمولة

  ## المشكلة
  الـ trigger يسجل العمولة مرتين: مرة عند إدراج حركة المرسل ومرة عند إدراج حركة المستلم.

  ## الحل
  تسجيل العمولة فقط عند إدراج حركة المرسل (transfer_direction = 'sender').
*/

DROP TRIGGER IF EXISTS record_commission_for_profit_loss_trigger ON account_movements;
DROP FUNCTION IF EXISTS record_commission_for_profit_loss_only() CASCADE;

CREATE OR REPLACE FUNCTION record_commission_for_profit_loss_only()
RETURNS TRIGGER AS $$
DECLARE
  profit_loss_account_id UUID;
  commission_movement_id UUID;
  commission_notes TEXT;
  commission_movement_number TEXT;
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

  -- تسجيل العمولة فقط عند إدراج حركة المرسل
  IF NEW.transfer_direction != 'sender' THEN
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

  -- توليد رقم حركة للعمولة
  commission_movement_number := 'COM-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 8);

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
      movement_number,
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
      commission_movement_number,
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
      movement_number,
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
      commission_movement_number,
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

  -- تحديث related_commission_movement_id في الحركة الأصلية
  UPDATE account_movements
  SET related_commission_movement_id = commission_movement_id
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER record_commission_for_profit_loss_trigger
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_for_profit_loss_only();