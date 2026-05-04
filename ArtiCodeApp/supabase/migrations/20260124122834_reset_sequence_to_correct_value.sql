/*
  # إعادة ضبط sequence ليبدأ من الرقم الصحيح

  ## المشكلة
  الـ sequence قد يبدأ من رقم أقل من آخر رقم حركة موجود مما يسبب تعارض.

  ## الحل
  إعادة ضبط sequence ليبدأ من آخر رقم حركة + 1.
*/

DO $$
DECLARE
  v_max_counter int;
  v_next_value bigint;
BEGIN
  -- الحصول على أعلى رقم حركة لليوم الحالي
  SELECT COALESCE(
    MAX(
      CAST(
        SUBSTRING(movement_number FROM '[0-9]+$') 
        AS int
      )
    ), 
    0
  ) INTO v_max_counter
  FROM account_movements
  WHERE movement_number LIKE 'MOV-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-%';

  -- إعادة ضبط sequence للبدء من الرقم الصحيح
  v_next_value := v_max_counter + 1;
  PERFORM setval('daily_movement_seq', v_next_value, false);
  
  RAISE NOTICE 'تم إعادة ضبط sequence ليبدأ من: %', v_next_value;
  RAISE NOTICE 'آخر رقم حركة اليوم: MOV-% -%', TO_CHAR(CURRENT_DATE, 'YYYYMMDD'), LPAD(v_max_counter::text, 4, '0');
  RAISE NOTICE 'الرقم التالي سيكون: MOV-% -%', TO_CHAR(CURRENT_DATE, 'YYYYMMDD'), LPAD(v_next_value::text, 4, '0');
END $$;

-- اختبار توليد رقم جديد
DO $$
DECLARE
  v_new_number text;
BEGIN
  v_new_number := generate_movement_number();
  RAISE NOTICE 'رقم تجريبي جديد: %', v_new_number;
END $$;
