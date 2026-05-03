/*
  # إصلاح مشكلة race condition في دالة generate_movement_number
  
  ## المشكلة
  عند إنشاء تحويل داخلي، يتم استدعاء generate_movement_number مرتين
  في نفس الوقت (مرة للمُحوِّل ومرة للمستلم)، مما يؤدي إلى إنشاء
  نفس الرقم مرتين وحدوث duplicate key error.
  
  ## الحل
  استخدام LOCK TABLE لضمان أن كل استدعاء للدالة يحصل على رقم فريد.
*/

CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS text AS $$
DECLARE
  new_number text;
  counter int;
  max_attempts int := 100;
  attempt int := 0;
BEGIN
  -- قفل الجدول لمنع race condition
  LOCK TABLE account_movements IN SHARE ROW EXCLUSIVE MODE;
  
  -- الحصول على العدد الحالي من الحركات لهذا اليوم
  SELECT COUNT(*) INTO counter 
  FROM account_movements 
  WHERE DATE(created_at) = CURRENT_DATE;
  
  -- توليد رقم جديد مع حماية من التكرار
  LOOP
    counter := counter + 1;
    attempt := attempt + 1;
    
    -- حماية من infinite loop
    IF attempt > max_attempts THEN
      RAISE EXCEPTION 'فشل في توليد رقم حركة فريد بعد % محاولة', max_attempts;
    END IF;
    
    new_number := 'MOV-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-' || LPAD(counter::text, 4, '0');
    
    -- التحقق من عدم وجود الرقم
    EXIT WHEN NOT EXISTS (SELECT 1 FROM account_movements WHERE movement_number = new_number);
  END LOOP;
  
  RETURN new_number;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_movement_number IS 'توليد رقم حركة فريد مع حماية من race condition';
