/*
  # تحديث trigger العمولات لتمييز وربط حركات العمولة

  ## الهدف
  تحديث trigger تسجيل العمولات لوضع علامة على حركات العمولة وربطها بالحركة الأساسية

  ## التغييرات

  1. حركات العمولة التي يتم إنشاؤها تُوضع عليها علامة `is_commission_movement = true`
  2. حركات العمولة تُربط بالحركة الأساسية عبر `related_commission_movement_id`
  3. هذا يسمح للواجهة بإخفاء حركات العمولة ودمجها مع الحركة الأساسية في العرض

  ## السلوك

  **الحالة 1: commission_recipient_id IS NULL** (الأرباح تستلم)
    - الأرباح: incoming (عمولة) - مُعلّمة كـ commission movement

  **الحالة 2: commission_recipient_id IS NOT NULL** (مستلم محدد)
    - الأرباح: outgoing (دفع عمولة) - مُعلّمة كـ commission movement
    - المستلم: incoming (استلام عمولة) - مُعلّمة كـ commission movement وربطها بالحركة الأساسية
*/

-- 1. حذف الـ trigger والدالة الحالية
DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss();

-- 2. إنشاء دالة trigger محدّثة مع التمييز والربط
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
      'incoming',  -- الأرباح تستلم
      next_movement_num_profit,
      'عمولة من حركة رقم ' || NEW.movement_number,
      NEW.created_at,
      true,  -- هذه حركة عمولة
      NEW.id  -- ربطها بالحركة الأساسية
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
      created_at,
      is_commission_movement,
      related_commission_movement_id
    ) VALUES (
      profit_loss_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'outgoing',  -- الأرباح تدفع
      next_movement_num_profit,
      'دفع عمولة لحركة رقم ' || NEW.movement_number,
      NEW.created_at,
      true,  -- هذه حركة عمولة
      NEW.id  -- ربطها بالحركة الأساسية
    ) RETURNING id INTO profit_movement_id;

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
      created_at,
      is_commission_movement,
      related_commission_movement_id
    ) VALUES (
      NEW.commission_recipient_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'incoming',  -- المستلم يحصل
      next_movement_num_recipient,
      'عمولة من حركة رقم ' || NEW.movement_number,
      NEW.created_at,
      true,  -- هذه حركة عمولة
      NEW.id  -- ربطها بالحركة الأساسية
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

COMMENT ON FUNCTION record_commission_to_profit_loss IS 'تسجيل العمولات مع التمييز والربط: حركات العمولة تُعلّم بـ is_commission_movement=true وتُربط بالحركة الأساسية';