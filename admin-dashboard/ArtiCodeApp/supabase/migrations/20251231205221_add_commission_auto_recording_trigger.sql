/*
  # إضافة trigger لتسجيل العمولات تلقائياً

  ## الوظيفة
  
  ### 1. Trigger على جدول account_movements
    - يتم تشغيله بعد insert حركة جديدة
    - إذا كانت الحركة تحتوي على عمولة > 0:
      - يتم إنشاء حركة إضافية في حساب الأرباح والخسائر
      - الحركة الإضافية تُسجل العمولة
  
  ### 2. تفاصيل الحركة المُنشأة للعمولة
    - party_id: معرف حساب الأرباح والخسائر
    - amount: مبلغ العمولة
    - commission: 0 (لأن هذه حركة العمولة نفسها)
    - currency: نفس عملة الحركة الأساسية
    - transaction_type: 'receive' (الأرباح والخسائر يستلم)
    - description: "عمولة من حركة رقم X"
  
  ### 3. ملاحظات مهمة
    - لا يتم تسجيل عمولة إذا كانت = 0
    - العمولة بنفس عملة الحركة الأساسية
    - يتم توليد movement_number تلقائياً
    - يتم ربط الحركة بنفس التاريخ
*/

-- دالة لتسجيل العمولة في حساب الأرباح والخسائر
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
    party_id,
    amount,
    commission,
    currency,
    transaction_type,
    movement_number,
    description,
    transaction_date,
    created_at
  ) VALUES (
    profit_loss_id,
    NEW.commission,
    0,
    NEW.commission_currency,
    'receive',
    next_movement_num,
    'عمولة من حركة رقم ' || NEW.movement_number,
    NEW.transaction_date,
    now()
  );

  RETURN NEW;
END;
$$;

-- إنشاء trigger على جدول account_movements
DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;

CREATE TRIGGER trigger_record_commission
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss();

COMMENT ON FUNCTION record_commission_to_profit_loss() IS 'دالة تلقائية لتسجيل العمولات في حساب الأرباح والخسائر';
COMMENT ON TRIGGER trigger_record_commission ON account_movements IS 'Trigger لتسجيل العمولات تلقائياً في حساب الأرباح والخسائر';
