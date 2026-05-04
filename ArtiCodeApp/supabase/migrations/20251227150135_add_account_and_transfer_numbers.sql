/*
  # إضافة رقم الحساب للعملاء ورقم الحوالة للحركات

  ## 1. التغييرات على جدول العملاء (customers)
    - إضافة حقل `account_number` (رقم حساب من 7 أرقام، فريد)
    - إنشاء دالة `generate_customer_account_number()` لتوليد أرقام حسابات عشوائية
    - توليد أرقام حسابات للعملاء الموجودين

  ## 2. التغييرات على جدول الحركات المالية (account_movements)
    - إضافة قيد UNIQUE على حقل `transfer_number` لمنع التكرار
    - إنشاء دالة `generate_transfer_number()` لتوليد أرقام حوالات عشوائية
    - إنشاء فهرس (index) على `transfer_number` لتسريع البحث

  ## 3. الأمان
    - جميع الدوال تتحقق من عدم تكرار الأرقام المولدة
    - استخدام قيود UNIQUE لضمان فرادة الأرقام

  ## 4. ملاحظات هامة
    - رقم الحساب يتكون من 7 أرقام عشوائية (مثال: 1234567)
    - رقم الحوالة يتكون من 7 أرقام عشوائية (مثال: 8901234)
    - كل رقم فريد ولا يتكرر في النظام
*/

-- 1. إنشاء دالة لتوليد رقم حساب عشوائي من 7 أرقام للعملاء
CREATE OR REPLACE FUNCTION generate_customer_account_number()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  new_account_number text;
  account_exists boolean;
BEGIN
  LOOP
    -- توليد رقم من 7 أرقام عشوائية (1000000 إلى 9999999)
    new_account_number := LPAD((FLOOR(RANDOM() * 9000000) + 1000000)::text, 7, '0');

    -- التحقق من عدم وجود الرقم مسبقاً
    SELECT EXISTS(
      SELECT 1 FROM customers WHERE account_number = new_account_number
    ) INTO account_exists;

    -- إذا لم يكن موجوداً، اخرج من الحلقة
    EXIT WHEN NOT account_exists;
  END LOOP;

  RETURN new_account_number;
END;
$$;

-- 2. إنشاء دالة لتوليد رقم حوالة عشوائي من 7 أرقام
CREATE OR REPLACE FUNCTION generate_transfer_number()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  new_transfer_number text;
  transfer_exists boolean;
BEGIN
  LOOP
    -- توليد رقم من 7 أرقام عشوائية (1000000 إلى 9999999)
    new_transfer_number := LPAD((FLOOR(RANDOM() * 9000000) + 1000000)::text, 7, '0');

    -- التحقق من عدم وجود الرقم مسبقاً
    SELECT EXISTS(
      SELECT 1 FROM account_movements WHERE transfer_number = new_transfer_number
    ) INTO transfer_exists;

    -- إذا لم يكن موجوداً، اخرج من الحلقة
    EXIT WHEN NOT transfer_exists;
  END LOOP;

  RETURN new_transfer_number;
END;
$$;

-- 3. إضافة حقل account_number إلى جدول customers
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'customers' AND column_name = 'account_number'
  ) THEN
    ALTER TABLE customers
    ADD COLUMN account_number text UNIQUE;

    -- إنشاء فهرس على account_number
    CREATE INDEX IF NOT EXISTS idx_customers_account_number
    ON customers(account_number);
  END IF;
END $$;

-- 4. توليد أرقام حسابات للعملاء الموجودين الذين ليس لديهم رقم حساب
DO $$
DECLARE
  customer_record RECORD;
BEGIN
  FOR customer_record IN
    SELECT id FROM customers WHERE account_number IS NULL
  LOOP
    UPDATE customers
    SET account_number = generate_customer_account_number()
    WHERE id = customer_record.id;
  END LOOP;
END $$;

-- 5. جعل حقل account_number إلزامياً بعد توليد الأرقام للعملاء الموجودين
ALTER TABLE customers
ALTER COLUMN account_number SET NOT NULL;

-- 6. إضافة قيد UNIQUE على transfer_number في جدول account_movements
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'account_movements_transfer_number_unique'
  ) THEN
    ALTER TABLE account_movements
    ADD CONSTRAINT account_movements_transfer_number_unique
    UNIQUE (transfer_number);
  END IF;
END $$;

-- 7. إنشاء فهرس على transfer_number لتسريع البحث
CREATE INDEX IF NOT EXISTS idx_account_movements_transfer_number
ON account_movements(transfer_number)
WHERE transfer_number IS NOT NULL;

-- 8. إنشاء trigger لتوليد رقم حساب تلقائياً عند إضافة عميل جديد
CREATE OR REPLACE FUNCTION auto_generate_account_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.account_number IS NULL THEN
    NEW.account_number := generate_customer_account_number();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_generate_account_number ON customers;
CREATE TRIGGER trigger_auto_generate_account_number
BEFORE INSERT ON customers
FOR EACH ROW
EXECUTE FUNCTION auto_generate_account_number();
