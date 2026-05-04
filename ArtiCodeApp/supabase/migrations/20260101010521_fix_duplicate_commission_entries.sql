/*
  # إصلاح مشكلة تكرار حركات العمولة
  
  ## المشكلة
  عند التحويل بين عميلين، الـ trigger ينشئ حركات عمولة مرتين:
    - مرة عند insert الحركة الأولى (من المُحوِّل)
    - مرة عند insert الحركة الثانية (إلى المُحوَّل إليه)
  
  ## الحل
  تعديل الـ trigger ليعمل فقط على:
    - الحركات التي movement_type = 'outgoing' في حالة customer_to_customer
    - الحركات في حالات shop_to_customer و customer_to_shop
    - الحركات التي لا تحتوي على transfer_direction
  
  ببساطة: لا تعمل على الحركة الثانية في customer_to_customer
*/

-- حذف الـ trigger والدالة القديمة
DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss();

-- إنشاء دالة trigger محدّثة مع منع التكرار
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  profit_loss_id uuid;
  next_movement_num_profit text;
  next_movement_num_recipient text;
BEGIN
  -- التحقق من وجود عمولة
  IF NEW.commission IS NULL OR NEW.commission = 0 THEN
    RETURN NEW;
  END IF;

  -- منع التكرار: لا تعمل على الحركة الثانية في customer_to_customer
  -- الحركة الثانية هي التي movement_type = 'incoming' و transfer_direction = 'customer_to_customer'
  IF NEW.transfer_direction = 'customer_to_customer' AND NEW.movement_type = 'incoming' THEN
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

    -- إنشاء حركة incoming للأرباح والخسائر
    INSERT INTO account_movements (
      customer_id,
      amount,
      commission,
      currency,
      commission_currency,
      movement_type,
      movement_number,
      notes,
      created_at
    ) VALUES (
      profit_loss_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'incoming',
      next_movement_num_profit,
      'عمولة من حركة رقم ' || NEW.movement_number,
      NEW.created_at
    );

  -- الحالة 2: تم اختيار مستلم - الأرباح تدفع العمولة للمستلم
  ELSE
    -- الحصول على أرقام الحركات
    SELECT generate_movement_number() INTO next_movement_num_profit;
    SELECT generate_movement_number() INTO next_movement_num_recipient;

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
      created_at
    ) VALUES (
      profit_loss_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'outgoing',
      next_movement_num_profit,
      'دفع عمولة لحركة رقم ' || NEW.movement_number,
      NEW.created_at
    );

    -- إنشاء حركة incoming للمستلم المختار (يحصل على العمولة)
    INSERT INTO account_movements (
      customer_id,
      amount,
      commission,
      currency,
      commission_currency,
      movement_type,
      movement_number,
      notes,
      created_at
    ) VALUES (
      NEW.commission_recipient_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'incoming',
      next_movement_num_recipient,
      'عمولة من حركة رقم ' || NEW.movement_number,
      NEW.created_at
    );
  END IF;

  RETURN NEW;
END;
$$;

-- إنشاء trigger جديد
CREATE TRIGGER trigger_record_commission
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss();

COMMENT ON FUNCTION record_commission_to_profit_loss IS 'دالة تلقائية لتسجيل العمولات مع منع التكرار في customer_to_customer';