/*
  # إصلاح اتجاه حركات العمولة في حساب الأرباح والخسائر
  
  ## المشكلة
  الـ trigger الحالي يسجل جميع حركات العمولة في حساب الأرباح والخسائر 
  كـ "outgoing" (دفع) بغض النظر عن قيمة commission_recipient_id
  
  ## الحل الصحيح
  
  **الحالة 1: commission_recipient_id IS NULL** (الافتراضي)
    - الأرباح والخسائر: incoming (تستلم العمولة)
    - لا يوجد حركة أخرى
  
  **الحالة 2: commission_recipient_id IS NOT NULL** (مستلم محدد)
    - الأرباح والخسائر: outgoing (تدفع العمولة)
    - المستلم المحدد: incoming (يستلم العمولة)
  
  ## التغييرات
  
  1. تحديث دالة record_commission_to_profit_loss لتطبق المنطق الصحيح
*/

-- 1. حذف الـ trigger والدالة الحالية
DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss();

-- 2. إنشاء دالة trigger محدّثة بالمنطق الصحيح
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
      created_at
    ) VALUES (
      profit_loss_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'incoming',  -- الأرباح تستلم
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
      'outgoing',  -- الأرباح تدفع
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
      'incoming',  -- المستلم يحصل
      next_movement_num_recipient,
      'عمولة من حركة رقم ' || NEW.movement_number,
      NEW.created_at
    );
  END IF;

  RETURN NEW;
END;
$$;

-- 3. إنشاء trigger جديد
CREATE TRIGGER trigger_record_commission
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss();

COMMENT ON FUNCTION record_commission_to_profit_loss IS 'تسجيل العمولات: NULL = الأرباح تستلم (incoming)، محدد = الأرباح تدفع (outgoing)';
