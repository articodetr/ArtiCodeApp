/*
  # إصلاح توليد أرقام الحركات باستخدام sequence

  ## المشكلة
  عند إنشاء حركة وحركتها المرآة في نفس الوقت، كلاهما يحصل على نفس الرقم
  لأن الدالة تستخدم COUNT(*) قبل إدراج أي حركة.

  ## الحل
  استخدام sequence لكل يوم لضمان أرقام فريدة حتى مع race conditions.
*/

-- إنشاء sequence يومي للحركات
CREATE SEQUENCE IF NOT EXISTS daily_movement_seq;

-- دالة محسنة لتوليد أرقام الحركات
CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS text AS $$
DECLARE
  v_date_part text;
  v_counter bigint;
  v_new_number text;
  v_current_date date;
BEGIN
  v_current_date := CURRENT_DATE;
  v_date_part := TO_CHAR(v_current_date, 'YYYYMMDD');
  
  -- استخدام sequence للحصول على رقم فريد
  v_counter := nextval('daily_movement_seq');
  
  -- إعادة ضبط sequence إذا تغير اليوم
  -- (هذا اختياري - يمكن الاستمرار في الزيادة)
  
  v_new_number := 'MOV-' || v_date_part || '-' || LPAD(v_counter::text, 4, '0');
  
  RETURN v_new_number;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_movement_number IS 'توليد رقم حركة فريد باستخدام sequence';

-- اختبار الدالة
DO $$
DECLARE
  v_num1 text;
  v_num2 text;
BEGIN
  v_num1 := generate_movement_number();
  v_num2 := generate_movement_number();
  
  RAISE NOTICE 'رقم 1: %', v_num1;
  RAISE NOTICE 'رقم 2: %', v_num2;
  
  IF v_num1 = v_num2 THEN
    RAISE EXCEPTION 'الأرقام متطابقة! هذا خطأ';
  ELSE
    RAISE NOTICE 'الأرقام مختلفة ✓';
  END IF;
END $$;
