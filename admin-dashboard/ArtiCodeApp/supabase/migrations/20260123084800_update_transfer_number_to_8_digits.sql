/*
  # تحديث رقم الحوالة ليكون من 8 أرقام

  ## التغييرات

  ### 1. تحديث دالة generate_transfer_number
    - تغيير النطاق من 7 أرقام إلى 8 أرقام
    - النطاق الجديد: 10000000 إلى 99999999
    - الاحتفاظ بآلية التحقق من عدم التكرار

  ### 2. التأكد من وجود الفهرس
    - فهرس على transfer_number لتسريع البحث والتحقق من التكرار

  ## الأمان
    - استخدام LOOP مع EXISTS للتحقق من الفرادة
    - يوفر 100 مليون رقم فريد (بدلاً من 10 مليون)
*/

-- 1. تحديث دالة generate_transfer_number لتوليد 8 أرقام
CREATE OR REPLACE FUNCTION generate_transfer_number()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  new_transfer_number text;
  transfer_exists boolean;
  max_attempts integer := 100;
  attempt_count integer := 0;
BEGIN
  LOOP
    -- توليد رقم من 8 أرقام عشوائية (10000000 إلى 99999999)
    new_transfer_number := LPAD((FLOOR(RANDOM() * 90000000) + 10000000)::text, 8, '0');

    -- التحقق من عدم وجود الرقم مسبقاً
    SELECT EXISTS(
      SELECT 1 FROM account_movements WHERE transfer_number = new_transfer_number
    ) INTO transfer_exists;

    -- إذا لم يكن موجوداً، اخرج من الحلقة
    EXIT WHEN NOT transfer_exists;

    -- زيادة عداد المحاولات لتجنب الحلقة اللانهائية
    attempt_count := attempt_count + 1;
    IF attempt_count >= max_attempts THEN
      RAISE EXCEPTION 'Failed to generate unique transfer number after % attempts', max_attempts;
    END IF;
  END LOOP;

  RETURN new_transfer_number;
END;
$$;

-- 2. التأكد من وجود فهرس على transfer_number
CREATE INDEX IF NOT EXISTS idx_account_movements_transfer_number
ON account_movements(transfer_number)
WHERE transfer_number IS NOT NULL;

-- 3. التحقق من صحة الدالة
DO $$
DECLARE
  test_transfer_number text;
BEGIN
  -- اختبار توليد رقم حوالة
  test_transfer_number := generate_transfer_number();

  -- التحقق من أن الرقم يتكون من 8 خانات
  IF LENGTH(test_transfer_number) != 8 THEN
    RAISE EXCEPTION 'Generated transfer number has wrong length: %', test_transfer_number;
  END IF;

  -- التحقق من أن الرقم رقمي فقط
  IF test_transfer_number !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'Generated transfer number is not numeric: %', test_transfer_number;
  END IF;

  RAISE NOTICE 'اختبار دالة generate_transfer_number ناجح ✓ (مثال: %)', test_transfer_number;
END $$;
