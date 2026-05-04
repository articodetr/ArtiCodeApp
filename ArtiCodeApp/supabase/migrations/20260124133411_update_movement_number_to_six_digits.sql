/*
  # تحديث أرقام الحركات إلى 6 أرقام فقط

  ## التغييرات
  1. تعديل دالة `generate_movement_number()` لاستخدام 6 أرقام بدلاً من التنسيق الطويل
  2. الحفاظ على استخدام sequence لضمان أرقام فريدة
  3. التنسيق الجديد: أرقام متسلسلة من 6 أرقام (مثال: 000001, 000002, ...)

  ## الملاحظات
  - سيتم إعادة استخدام sequence الموجود
  - الأرقام ستكون أبسط وأسهل في القراءة
*/

-- تحديث دالة توليد أرقام الحركات
CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS text AS $$
DECLARE
  v_counter bigint;
  v_new_number text;
BEGIN
  -- استخدام sequence للحصول على رقم فريد
  v_counter := nextval('daily_movement_seq');
  
  -- توليد رقم من 6 أرقام
  v_new_number := LPAD(v_counter::text, 6, '0');
  
  RETURN v_new_number;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_movement_number IS 'توليد رقم حركة فريد من 6 أرقام';
