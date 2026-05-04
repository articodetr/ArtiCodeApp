/*
  # تحديث نظام رقم السند ليكون خاص بكل عميل

  ## التغييرات

  ### 1. إضافة حقل last_receipt_number للعملاء
    - حقل `last_receipt_number` (integer) لتتبع آخر رقم سند لكل عميل
    - القيمة الافتراضية: 0

  ### 2. تحديث دالة توليد رقم السند
    - دالة `generate_customer_receipt_number(customer_id)` جديدة
    - تولد رقم سند خاص بكل عميل يبدأ من 00001
    - تستخدم SELECT FOR UPDATE لمنع Race Conditions
    - ترجع رقم من 5 خانات (00001، 00002، إلخ)

  ### 3. تحديث Trigger توليد السند
    - تعديل `auto_generate_receipt_number()` لاستخدام الدالة الجديدة
    - حفظ الرقم القديم في حقل `old_receipt_number` للرجوع إليه

  ### 4. ترحيل البيانات الموجودة
    - إعادة ترقيم السندات الموجودة لكل عميل
    - تحديث `last_receipt_number` لكل عميل
    - حفظ الأرقام القديمة

  ## الأمان
    - استخدام SELECT FOR UPDATE لمنع التعارضات
    - الاحتفاظ بـ UNIQUE constraint على (customer_id, receipt_number)
    - معالجة حالة عدم وجود العميل
*/

-- 1. إضافة حقل old_receipt_number للاحتفاظ بالأرقام القديمة
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'old_receipt_number'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN old_receipt_number text;
  END IF;
END $$;

-- 2. حفظ الأرقام القديمة قبل التحديث
UPDATE account_movements
SET old_receipt_number = receipt_number
WHERE receipt_number IS NOT NULL AND old_receipt_number IS NULL;

-- 3. إضافة حقل last_receipt_number إلى جدول العملاء
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'customers' AND column_name = 'last_receipt_number'
  ) THEN
    ALTER TABLE customers ADD COLUMN last_receipt_number integer DEFAULT 0 NOT NULL;

    -- إنشاء فهرس على الحقل
    CREATE INDEX IF NOT EXISTS idx_customers_last_receipt_number
    ON customers(last_receipt_number);
  END IF;
END $$;

-- 4. إزالة UNIQUE constraint القديم من receipt_number
DO $$
BEGIN
  -- البحث عن اسم الـ constraint
  DECLARE
    constraint_name text;
  BEGIN
    SELECT tc.constraint_name INTO constraint_name
    FROM information_schema.table_constraints tc
    WHERE tc.table_name = 'account_movements'
      AND tc.constraint_type = 'UNIQUE'
      AND tc.constraint_name LIKE '%receipt_number%';

    -- حذف الـ constraint إذا وُجد
    IF constraint_name IS NOT NULL THEN
      EXECUTE 'ALTER TABLE account_movements DROP CONSTRAINT IF EXISTS ' || constraint_name;
    END IF;
  END;
END $$;

-- 5. إنشاء UNIQUE constraint جديد على (customer_id, receipt_number)
-- هذا يسمح بنفس رقم السند لعملاء مختلفين
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'account_movements_customer_receipt_unique'
  ) THEN
    ALTER TABLE account_movements
    ADD CONSTRAINT account_movements_customer_receipt_unique
    UNIQUE (customer_id, receipt_number);
  END IF;
END $$;

-- 6. إنشاء دالة جديدة لتوليد رقم سند خاص بالعميل
CREATE OR REPLACE FUNCTION generate_customer_receipt_number(p_customer_id uuid)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_next_number integer;
  v_receipt_number text;
BEGIN
  -- التحقق من وجود العميل
  IF NOT EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id) THEN
    RAISE EXCEPTION 'Customer not found: %', p_customer_id;
  END IF;

  -- قفل الصف وقراءة آخر رقم سند + 1
  -- استخدام FOR UPDATE لمنع Race Conditions
  UPDATE customers
  SET last_receipt_number = last_receipt_number + 1
  WHERE id = p_customer_id
  RETURNING last_receipt_number INTO v_next_number;

  -- تنسيق الرقم بصيغة 5 خانات (00001، 00002، إلخ)
  v_receipt_number := LPAD(v_next_number::text, 5, '0');

  RETURN v_receipt_number;
END;
$$;

-- 7. تحديث trigger function لاستخدام الدالة الجديدة
CREATE OR REPLACE FUNCTION auto_generate_receipt_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- توليد رقم السند فقط إذا لم يكن موجوداً
  IF NEW.receipt_number IS NULL THEN
    -- التحقق من وجود customer_id
    IF NEW.customer_id IS NULL THEN
      RAISE EXCEPTION 'Cannot generate receipt number without customer_id';
    END IF;

    -- توليد رقم السند الخاص بالعميل
    NEW.receipt_number := generate_customer_receipt_number(NEW.customer_id);
    NEW.receipt_generated_at := now();
  END IF;

  RETURN NEW;
END;
$$;

-- 8. إعادة ترقيم السندات الموجودة لكل عميل
DO $$
DECLARE
  customer_record RECORD;
  movement_record RECORD;
  counter integer;
BEGIN
  -- التكرار على كل عميل
  FOR customer_record IN
    SELECT DISTINCT customer_id
    FROM account_movements
    WHERE customer_id IS NOT NULL
    ORDER BY customer_id
  LOOP
    counter := 0;

    -- التكرار على حركات العميل مرتبة بتاريخ الإنشاء
    FOR movement_record IN
      SELECT id
      FROM account_movements
      WHERE customer_id = customer_record.customer_id
      ORDER BY created_at, id
    LOOP
      counter := counter + 1;

      -- تحديث رقم السند
      UPDATE account_movements
      SET receipt_number = LPAD(counter::text, 5, '0')
      WHERE id = movement_record.id;
    END LOOP;

    -- تحديث last_receipt_number للعميل
    UPDATE customers
    SET last_receipt_number = counter
    WHERE id = customer_record.customer_id;
  END LOOP;

  RAISE NOTICE 'تم إعادة ترقيم السندات بنجاح';
END $$;

-- 9. التحقق من صحة البيانات
DO $$
DECLARE
  duplicate_count integer;
BEGIN
  -- التحقق من عدم وجود تكرار في (customer_id, receipt_number)
  SELECT COUNT(*) INTO duplicate_count
  FROM (
    SELECT customer_id, receipt_number, COUNT(*) as cnt
    FROM account_movements
    WHERE customer_id IS NOT NULL AND receipt_number IS NOT NULL
    GROUP BY customer_id, receipt_number
    HAVING COUNT(*) > 1
  ) duplicates;

  IF duplicate_count > 0 THEN
    RAISE EXCEPTION 'Found % duplicate receipt numbers after migration', duplicate_count;
  END IF;

  RAISE NOTICE 'التحقق من البيانات: لا توجد سندات مكررة ✓';
END $$;
