/*
  # إصلاح منطق عرض حركات العمولة

  ## المشكلة الحالية
  عندما جلال يحول 5000 لعماد والعمولة 120 لصالح عماد، النظام ينشئ:
  - حركة 5000 + 120 = 5120 incoming لعماد (الحركة الأساسية)
  - حركة 120 outgoing من الأرباح (حركة عمولة)
  - حركة 120 incoming لعماد (حركة عمولة إضافية - غير مطلوبة)
  
  هذا يؤدي إلى أن عماد يظهر رصيده 5240 بدلاً من 5120

  ## الحل
  عندما يكون المستلم (`commission_recipient_id`) هو نفسه المستلم في الحركة (`to_customer_id`):
  - فقط ننشئ حركة outgoing من الأرباح والخسائر
  - لا ننشئ حركة incoming منفصلة للمستلم لأن المبلغ الكامل (5120) موجود في الحركة الأساسية
  
  عندما يكون المستلم (`commission_recipient_id`) هو المرسل (`from_customer_id`):
  - ننشئ حركة outgoing من الأرباح والخسائر
  - ننشئ حركة incoming للمرسل

  ## التغييرات
  1. تحديث دالة `record_commission_to_profit_loss` لتحقق من نوع المستلم
  2. إذا كان المستلم هو `to_customer_id`: فقط حركة outgoing من الأرباح
  3. إذا كان المستلم هو `from_customer_id`: حركة outgoing من الأرباح + incoming للمرسل
*/

-- 1. حذف الـ trigger والدالة الحالية
DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss();

-- 2. إنشاء دالة trigger محدّثة
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  profit_loss_id uuid;
  next_movement_num_profit text;
  next_movement_num_recipient text;
  profit_movement_id uuid;
BEGIN
  -- التحقق من وجود عمولة
  IF NEW.commission IS NULL OR NEW.commission = 0 THEN
    RETURN NEW;
  END IF;

  -- منع التكرار: لا تعمل على الحركة الثانية في customer_to_customer
  IF NEW.transfer_direction = 'customer_to_customer' AND NEW.movement_type = 'incoming' THEN
    RETURN NEW;
  END IF;

  -- منع العمل على حركات العمولة نفسها (تجنب التكرار اللانهائي)
  IF NEW.is_commission_movement = true THEN
    RETURN NEW;
  END IF;

  -- الحصول على معرف حساب الأرباح والخسائر
  SELECT id INTO profit_loss_id
  FROM customers
  WHERE is_profit_loss_account = true
  LIMIT 1;

  -- التحقق من وجود الحساب
  IF profit_loss_id IS NULL THEN
    RAISE EXCEPTION 'حساب الأرباح والخسائر غير موجود';
  END IF;

  -- الحالة 1: لم يتم اختيار مستلم (NULL) - الأرباح تستلم العمولة
  IF NEW.commission_recipient_id IS NULL THEN
    -- الحصول على رقم الحركة التالي
    SELECT generate_movement_number() INTO next_movement_num_profit;

    -- إنشاء حركة incoming للأرباح والخسائر (تستلم)
    INSERT INTO account_movements (
      customer_id,
      amount,
      commission,
      currency,
      commission_currency,
      movement_type,
      movement_number,
      notes,
      created_at,
      is_commission_movement,
      related_commission_movement_id
    ) VALUES (
      profit_loss_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'incoming',
      next_movement_num_profit,
      'عمولة من حركة رقم ' || NEW.movement_number,
      NEW.created_at,
      true,
      NEW.id
    );

  -- الحالة 2: تم اختيار مستلم - نتحقق من نوع المستلم
  ELSE
    -- الحصول على رقم الحركة للأرباح
    SELECT generate_movement_number() INTO next_movement_num_profit;

    -- إنشاء حركة outgoing من الأرباح والخسائر (تدفع العمولة)
    INSERT INTO account_movements (
      customer_id,
      amount,
      commission,
      currency,
      commission_currency,
      movement_type,
      movement_number,
      notes,
      created_at,
      is_commission_movement,
      related_commission_movement_id
    ) VALUES (
      profit_loss_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'outgoing',
      next_movement_num_profit,
      'دفع عمولة لحركة رقم ' || NEW.movement_number,
      NEW.created_at,
      true,
      NEW.id
    ) RETURNING id INTO profit_movement_id;

    -- فقط إذا كان المستلم هو المرسل (from_customer_id): ننشئ حركة incoming له
    -- إذا كان المستلم هو to_customer_id: لا ننشئ حركة إضافية (المبلغ الكامل موجود في الحركة الأساسية)
    IF NEW.commission_recipient_id = NEW.from_customer_id THEN
      -- الحصول على رقم الحركة للمستلم
      SELECT generate_movement_number() INTO next_movement_num_recipient;

      -- إنشاء حركة incoming للمرسل (يحصل على العمولة)
      INSERT INTO account_movements (
        customer_id,
        amount,
        commission,
        currency,
        commission_currency,
        movement_type,
        movement_number,
        notes,
        created_at,
        is_commission_movement,
        related_commission_movement_id
      ) VALUES (
        NEW.commission_recipient_id,
        NEW.commission,
        0,
        NEW.commission_currency,
        NEW.commission_currency,
        'incoming',
        next_movement_num_recipient,
        'عمولة من حركة رقم ' || NEW.movement_number,
        NEW.created_at,
        true,
        NEW.id
      );
    END IF;
    -- إذا كان المستلم هو to_customer_id: لا ننشئ أي حركة إضافية
    -- لأن المبلغ الكامل (amount + commission) موجود في الحركة الأساسية
  END IF;

  RETURN NEW;
END;
$$;

-- 3. إنشاء trigger جديد
CREATE TRIGGER trigger_record_commission
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss();

COMMENT ON FUNCTION record_commission_to_profit_loss IS 'تسجيل العمولات: عندما المستلم هو to_customer_id فقط حركة outgoing من الأرباح، عندما المستلم هو from_customer_id حركة outgoing من الأرباح + incoming للمرسل';