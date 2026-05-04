/*
  # تصحيح trigger تسجيل العمولات

  ## التغييرات
  
  ### 1. تعديل الـ trigger ليتماشى مع البنية الفعلية
    - استخدام customer_id بدلاً من party_id
    - استخدام movement_type بدلاً من transaction_type
    - استخدام الحقول الصحيحة من الجدول
  
  ### 2. منطق التسجيل
    - عند إنشاء حركة مع عمولة > 0
    - يتم إنشاء حركة incoming في حساب الأرباح والخسائر
    - الحركة تكون بمبلغ العمولة فقط
*/

-- حذف الـ trigger القديم
DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss();

-- إنشاء دالة جديدة متوافقة مع البنية الفعلية
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  profit_loss_id uuid;
  next_movement_num text;
BEGIN
  -- التحقق من وجود عمولة
  IF NEW.commission IS NULL OR NEW.commission = 0 THEN
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

  -- الحصول على رقم الحركة التالي
  SELECT 'MV-' || LPAD(
    (COALESCE(MAX(CAST(SUBSTRING(movement_number FROM 4) AS INTEGER)), 0) + 1)::TEXT,
    6,
    '0'
  ) INTO next_movement_num
  FROM account_movements;

  -- إنشاء حركة العمولة في حساب الأرباح والخسائر
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
    next_movement_num,
    'عمولة من حركة رقم ' || NEW.movement_number,
    NEW.created_at
  );

  RETURN NEW;
END;
$$;

-- إنشاء trigger جديد
CREATE TRIGGER trigger_record_commission
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss();

COMMENT ON FUNCTION record_commission_to_profit_loss() IS 'دالة تلقائية لتسجيل العمولات في حساب الأرباح والخسائر (متوافقة مع البنية الفعلية)';
