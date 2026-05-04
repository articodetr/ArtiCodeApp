/*
  # إضافة الحقول المفقودة وتحديث Views
  
  ## التغييرات
  
  ### 1. إضافة حقول لجدول customers
  - `account_number` - رقم الحساب الفريد
  - `is_profit_loss_account` - علامة حساب الأرباح والخسائر
  
  ### 2. تحديث View: customer_balances_by_currency
  - إضافة customer_name
  - إضافة total_incoming و total_outgoing
  - الترتيب حسب الاسم والرصيد
  
  ### 3. تحديث View: customers_with_last_activity
  - إضافة account_number
  - إضافة movements_count
  - تحديث الترتيب
  
  ## الغرض
  - مطابقة قاعدة البيانات مع المشروع السابق
*/

-- 1. إضافة الحقول المفقودة لجدول customers
DO $$
BEGIN
  -- إضافة account_number
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'customers' AND column_name = 'account_number'
  ) THEN
    ALTER TABLE customers ADD COLUMN account_number text;
    
    -- إنشاء index فريد
    CREATE UNIQUE INDEX IF NOT EXISTS customers_account_number_idx 
      ON customers(account_number) WHERE account_number IS NOT NULL;
  END IF;

  -- إضافة is_profit_loss_account
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'customers' AND column_name = 'is_profit_loss_account'
  ) THEN
    ALTER TABLE customers ADD COLUMN is_profit_loss_account boolean DEFAULT false;
  END IF;
END $$;

-- 2. تحديث حساب الأرباح والخسائر
UPDATE customers 
SET 
  is_profit_loss_account = true,
  account_number = 'P&L-ACCOUNT'
WHERE phone = 'PROFIT_LOSS_ACCOUNT';

-- 3. توليد أرقام حسابات للعملاء الموجودين (إن لم تكن موجودة)
DO $$
DECLARE
  customer_record RECORD;
  counter int := 1000;
BEGIN
  FOR customer_record IN 
    SELECT id FROM customers 
    WHERE account_number IS NULL 
    AND phone != 'PROFIT_LOSS_ACCOUNT'
  LOOP
    UPDATE customers 
    SET account_number = 'ACC-' || LPAD(counter::text, 6, '0')
    WHERE id = customer_record.id;
    
    counter := counter + 1;
  END LOOP;
END $$;

-- 4. تحديث View: customer_balances_by_currency
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;
CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) AS balance
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
  AND am.is_commission_movement = false
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, am.currency
HAVING COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) <> 0
ORDER BY c.name, abs(COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ),
    0
  )) DESC;

-- 5. تحديث View: customers_with_last_activity
DROP VIEW IF EXISTS customers_with_last_activity CASCADE;
CREATE OR REPLACE VIEW customers_with_last_activity AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.email,
  c.address,
  c.notes,
  c.created_at,
  c.account_number,
  c.is_profit_loss_account,
  MAX(am.created_at) as last_activity_date,
  COUNT(am.id) as movements_count
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
  AND am.is_commission_movement = false
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.notes, 
         c.created_at, c.account_number, c.is_profit_loss_account
ORDER BY c.is_profit_loss_account DESC, last_activity_date DESC NULLS LAST;

-- 6. منح الصلاحيات
GRANT SELECT ON customer_balances_by_currency TO authenticated, anon;
GRANT SELECT ON customers_with_last_activity TO authenticated, anon;
