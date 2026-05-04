/*
  # تحديث صيغة رقم الحركة

  ## التغييرات
  
  1. إنشاء sequence للأرقام التسلسلية
     - يبدأ من 26001
     - يزداد بمقدار 1 مع كل حركة
  
  2. تعديل دالة generate_movement_number
     - إرجاع رقم بسيط بدلاً من MOV-YYYYMMDD-####
     - مثال: 26001، 26002، 26003
  
  ## الملاحظات
  - الأرقام تكون تسلسلية وفريدة
  - لا يمكن تكرار الأرقام
*/

-- إنشاء sequence للأرقام التسلسلية
CREATE SEQUENCE IF NOT EXISTS movement_number_seq START WITH 26001;

-- تعديل دالة generate_movement_number لإرجاع رقم بسيط
CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS text AS $$
DECLARE
  new_number text;
  counter bigint;
BEGIN
  -- الحصول على الرقم التالي من sequence
  counter := nextval('movement_number_seq');
  
  -- توليد رقم بسيط
  new_number := counter::text;
  
  RETURN new_number;
END;
$$ LANGUAGE plpgsql;