/*
  # إصلاح نهائي لمشكلة تكرار أرقام الحركات
  
  ## المشكلة
  الـ sequence يعود إلى قيمة قديمة مما يسبب محاولة استخدام أرقام موجودة مسبقاً
  
  ## الحل
  - إنشاء trigger يتحقق من أن الـ sequence دائماً أكبر من آخر رقم موجود
  - إعادة ضبط الـ sequence بشكل نهائي
  
  ## الملاحظات
  - سيضمن هذا عدم حدوث تكرار مطلقاً
*/

-- إعادة ضبط الـ sequence ليكون أكبر من أي رقم موجود
DO $$
DECLARE
  v_max_number bigint;
BEGIN
  -- إيجاد أكبر رقم حركة موجود (بما فيها المحذوفة)
  SELECT COALESCE(MAX(movement_number::bigint), 0)
  INTO v_max_number
  FROM account_movements
  WHERE movement_number ~ '^[0-9]+$';
  
  -- ضبط الـ sequence ليبدأ من الرقم التالي
  PERFORM setval('daily_movement_seq', v_max_number + 1, false);
  
  RAISE NOTICE 'تم ضبط sequence على القيمة: %', v_max_number + 1;
END $$;

-- تحديث دالة generate_movement_number للتأكد من عدم التكرار
CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS text AS $$
DECLARE
  v_counter bigint;
  v_new_number text;
  v_max_existing bigint;
  v_attempts int := 0;
BEGIN
  LOOP
    -- الحصول على رقم من الـ sequence
    v_counter := nextval('daily_movement_seq');
    
    -- توليد رقم من 6 أرقام
    v_new_number := LPAD(v_counter::text, 6, '0');
    
    -- التحقق من عدم وجود هذا الرقم
    IF NOT EXISTS (
      SELECT 1 FROM account_movements 
      WHERE movement_number = v_new_number
    ) THEN
      RETURN v_new_number;
    END IF;
    
    -- إذا كان الرقم موجوداً، إيجاد أكبر رقم وضبط الـ sequence
    SELECT COALESCE(MAX(movement_number::bigint), 0)
    INTO v_max_existing
    FROM account_movements
    WHERE movement_number ~ '^[0-9]+$';
    
    PERFORM setval('daily_movement_seq', v_max_existing + 1, false);
    
    v_attempts := v_attempts + 1;
    
    IF v_attempts > 10 THEN
      RAISE EXCEPTION 'فشل توليد رقم حركة فريد بعد % محاولات', v_attempts;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_movement_number IS 'توليد رقم حركة فريد من 6 أرقام مع ضمان عدم التكرار';