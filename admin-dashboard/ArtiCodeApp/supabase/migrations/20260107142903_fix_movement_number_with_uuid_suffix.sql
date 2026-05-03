/*
  # إصلاح توليد رقم الحركة باستخدام UUID suffix
  
  ## المشكلة
  عند إنشاء تحويل داخلي، يتم توليد رقمين في نفس الوقت
  مما يسبب تكرار في الأرقام.
  
  ## الحل
  إضافة suffix فريد من UUID لضمان عدم التكرار
*/

CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS text AS $$
DECLARE
  new_number text;
  date_part text;
  unique_suffix text;
BEGIN
  -- جزء التاريخ
  date_part := TO_CHAR(CURRENT_DATE, 'YYYYMMDD');
  
  -- suffix فريد من UUID (آخر 8 أحرف)
  unique_suffix := UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 25 FOR 8));
  
  -- تكوين الرقم النهائي
  new_number := 'MOV-' || date_part || '-' || unique_suffix;
  
  RETURN new_number;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_movement_number IS 'توليد رقم حركة فريد باستخدام UUID suffix';
