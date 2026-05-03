/*
  # إصلاح trigger حساب المبلغ الصافي - استخدام الحقول الصحيحة
  
  ## المشكلة
  الـ trigger يستخدم حقل `is_internal_transfer` غير الموجود
  يجب استخدام `related_transfer_id` للتحقق من التحويلات الداخلية
  
  ## الحل
  تحديث الـ trigger لاستخدام الحقول الصحيحة
*/

-- حذف الـ trigger القديم
DROP TRIGGER IF EXISTS calculate_net_amount_trigger ON account_movements;
DROP FUNCTION IF EXISTS calculate_net_amount_before_insert() CASCADE;

-- إنشاء BEFORE INSERT trigger محدّث
CREATE OR REPLACE FUNCTION calculate_net_amount_before_insert()
RETURNS TRIGGER AS $$
DECLARE
  v_commission_value numeric(15,2);
BEGIN
  -- حفظ المبلغ الأصلي
  NEW.original_amount := NEW.amount;
  
  -- إذا لم يكن هناك عمولة، لا نفعل شيء
  IF NEW.commission IS NULL OR NEW.commission = 0 THEN
    RETURN NEW;
  END IF;
  
  -- إذا كانت حركة عمولة منفصلة، لا نُعدّل amount
  IF NEW.is_commission_movement = true THEN
    RETURN NEW;
  END IF;
  
  v_commission_value := NEW.commission;
  
  -- للحركات العادية (غير التحويل الداخلي)
  -- التحويل الداخلي يُحدد من خلال related_transfer_id
  IF NEW.related_transfer_id IS NULL THEN
    IF NEW.movement_type = 'outgoing' THEN
      -- استلام من العميل: الصافي = المبلغ - العمولة
      NEW.amount := NEW.amount - v_commission_value;
    ELSIF NEW.movement_type = 'incoming' THEN
      -- تسليم للعميل: الإجمالي = المبلغ + العمولة
      NEW.amount := NEW.amount + v_commission_value;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER calculate_net_amount_trigger
  BEFORE INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION calculate_net_amount_before_insert();

COMMENT ON FUNCTION calculate_net_amount_before_insert IS 'حساب المبلغ الصافي تلقائياً - outgoing: amount - commission, incoming: amount + commission';
