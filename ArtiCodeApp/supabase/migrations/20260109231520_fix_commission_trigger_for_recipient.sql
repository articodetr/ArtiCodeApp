/*
  # إصلاح تسجيل عمولات المستلم
  
  ## المشكلة
  الـ trigger الحالي يسجل العمولة فقط عند حركة المرسل (transfer_direction = 'sender').
  هذا يعمل بشكل صحيح عندما تكون العمولة للمرسل أو لحساب الأرباح والخسائر.
  لكن عندما تكون العمولة للمستلم، لا يتم تسجيلها!
  
  ## الحل
  تعديل المنطق ليكون:
  - إذا كانت العمولة لحساب الأرباح والخسائر: سجل عند المرسل فقط (لتجنب التكرار)
  - إذا كانت العمولة للمرسل: سجل عند حركة المرسل
  - إذا كانت العمولة للمستلم: سجل عند حركة المستلم
  
  ## التفاصيل
  1. حذف الـ trigger القديم
  2. إنشاء دالة جديدة بمنطق محسّن
  3. إنشاء الـ trigger الجديد
*/

DROP TRIGGER IF EXISTS record_commission_for_profit_loss_trigger ON account_movements;
DROP FUNCTION IF EXISTS record_commission_for_profit_loss_only() CASCADE;

CREATE OR REPLACE FUNCTION record_commission_for_profit_loss_smart()
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

  -- الحصول على حساب الأرباح والخسائر
  SELECT id INTO profit_loss_account_id
  FROM customers
  WHERE is_profit_loss_account = true
  LIMIT 1;

  IF profit_loss_account_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- منطق التسجيل الذكي:
  -- 1. إذا كانت العمولة لحساب الأرباح: سجل عند المرسل فقط (لتجنب التكرار)
  -- 2. إذا كانت العمولة للمرسل: سجل عند حركة المرسل
  -- 3. إذا كانت العمولة للمستلم: سجل عند حركة المستلم
  
  IF NEW.commission_recipient_id = profit_loss_account_id THEN
    -- حالة 1: العمولة لحساب الأرباح - سجل عند المرسل فقط
    IF NEW.transfer_direction != 'sender' THEN
      RETURN NEW;
    END IF;
  ELSIF NEW.commission_recipient_id = NEW.from_customer_id THEN
    -- حالة 2: العمولة للمرسل - سجل عند حركة المرسل
    IF NEW.transfer_direction != 'sender' THEN
      RETURN NEW;
    END IF;
  ELSIF NEW.commission_recipient_id = NEW.to_customer_id THEN
    -- حالة 3: العمولة للمستلم - سجل عند حركة المستلم
    IF NEW.transfer_direction != 'recipient' THEN
      RETURN NEW;
    END IF;
  ELSE
    -- حالة غير متوقعة - لا تسجل
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
    -- العمولة تذهب للمرسل أو المستلم
    -- تحديد اتجاه الحركة بناءً على من يحصل على العمولة
    DECLARE
      recipient_name TEXT;
      commission_movement_type TEXT;
    BEGIN
      IF NEW.commission_recipient_id = NEW.from_customer_id THEN
        -- العمولة للمرسل
        recipient_name := COALESCE(NEW.sender_name, 'المرسل');
        commission_movement_type := 'incoming'; -- المرسل يستلم العمولة
      ELSE
        -- العمولة للمستلم
        recipient_name := COALESCE(NEW.beneficiary_name, 'المستلم');
        commission_movement_type := 'incoming'; -- المستلم يستلم العمولة
      END IF;

      commission_notes := format(
        'عمولة لـ %s من تحويل %s → %s بمبلغ %s %s',
        recipient_name,
        COALESCE(NEW.sender_name, 'غير محدد'),
        COALESCE(NEW.beneficiary_name, 'غير محدد'),
        NEW.commission,
        NEW.commission_currency
      );

      -- تسجيل حركة دفع من الأرباح
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

      -- تسجيل حركة استلام للعميل
      commission_movement_number := 'COM-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 8);
      
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
        NEW.commission_recipient_id,
        commission_movement_type,
        NEW.commission,
        NEW.commission_currency,
        commission_notes,
        true,
        NEW.id,
        0,
        NEW.commission_currency
      );
    END;
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
  EXECUTE FUNCTION record_commission_for_profit_loss_smart();