/*
  # إصلاح trigger لتجاهل التحويلات الداخلية
  
  ## المشكلة
  
  الـ BEFORE INSERT trigger يُعدّل المبلغ حتى للتحويلات الداخلية
  مما يسبب حساب خاطئ لأن الـ function تحسب المبلغ بالفعل
  
  ## الحل
  
  تحديث الـ trigger لتجاهل الحركات التي:
  - لها from_customer_id أو to_customer_id (علامة على تحويل داخلي)
  - لها related_transfer_id (الحركة الثانية من التحويل)
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
  -- حفظ المبلغ الأصلي إذا لم يكن موجوداً
  IF NEW.original_amount IS NULL THEN
    NEW.original_amount := NEW.amount;
  END IF;
  
  -- إذا لم يكن هناك عمولة، لا نفعل شيء
  IF NEW.commission IS NULL OR NEW.commission = 0 THEN
    RETURN NEW;
  END IF;
  
  -- إذا كانت حركة عمولة منفصلة، لا نُعدّل amount
  IF NEW.is_commission_movement = true THEN
    RETURN NEW;
  END IF;
  
  -- إذا كانت حركة تحويل داخلي (لها from_customer_id أو to_customer_id)، لا نُعدّل amount
  -- لأن الـ function تحسب المبلغ بالفعل
  IF NEW.from_customer_id IS NOT NULL OR NEW.to_customer_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  
  -- إذا كانت الحركة الثانية من تحويل داخلي (لها related_transfer_id)، لا نُعدّل amount
  IF NEW.related_transfer_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  
  v_commission_value := NEW.commission;
  
  -- للحركات العادية فقط (غير التحويل الداخلي)
  IF NEW.movement_type = 'outgoing' THEN
    -- استلام من العميل: الصافي = المبلغ - العمولة
    NEW.amount := NEW.amount - v_commission_value;
  ELSIF NEW.movement_type = 'incoming' THEN
    -- تسليم للعميل: الإجمالي = المبلغ + العمولة
    NEW.amount := NEW.amount + v_commission_value;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER calculate_net_amount_trigger
  BEFORE INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION calculate_net_amount_before_insert();

COMMENT ON FUNCTION calculate_net_amount_before_insert IS 'حساب المبلغ الصافي للحركات العادية فقط - يتجاهل التحويلات الداخلية';
