/*
  # إنشاء نظام إدارة الحوالات المالية - قاعدة بيانات جديدة
  
  ## الجداول الجديدة
  
  ### 1. customers (العملاء)
  - جدول العملاء الأساسي
  
  ### 2. transactions (الحوالات)
  - جدول الحوالات المالية
  
  ### 3. debts (الديون)
  - جدول الديون
  
  ### 4. exchange_rates (أسعار الصرف)
  - جدول أسعار الصرف
  
  ### 5. receipts (السندات)
  - جدول السندات
  
  ### 6. app_settings (إعدادات التطبيق)
  - جدول الإعدادات
  
  ## الأمان
  - تفعيل RLS على جميع الجداول
  - سياسات للسماح بجميع العمليات
*/

-- إنشاء جدول العملاء
CREATE TABLE IF NOT EXISTS customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  phone text NOT NULL,
  email text,
  address text,
  balance decimal(15, 2) DEFAULT 0,
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- إنشاء جدول الحوالات
CREATE TABLE IF NOT EXISTS transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_number text UNIQUE NOT NULL,
  customer_id uuid REFERENCES customers(id) ON DELETE CASCADE,
  amount_sent decimal(15, 2) NOT NULL,
  currency_sent text NOT NULL,
  amount_received decimal(15, 2) NOT NULL,
  currency_received text NOT NULL,
  exchange_rate decimal(15, 6) NOT NULL,
  status text DEFAULT 'completed',
  notes text,
  created_at timestamptz DEFAULT now()
);

-- إنشاء جدول الديون
CREATE TABLE IF NOT EXISTS debts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid REFERENCES customers(id) ON DELETE CASCADE,
  amount decimal(15, 2) NOT NULL,
  currency text NOT NULL,
  reason text,
  status text DEFAULT 'pending',
  paid_amount decimal(15, 2) DEFAULT 0,
  due_date date,
  created_at timestamptz DEFAULT now(),
  paid_at timestamptz
);

-- إنشاء جدول أسعار الصرف
CREATE TABLE IF NOT EXISTS exchange_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_currency text NOT NULL,
  to_currency text NOT NULL,
  rate decimal(15, 6) NOT NULL,
  source text DEFAULT 'api',
  created_at timestamptz DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS exchange_rates_currencies_idx 
  ON exchange_rates(from_currency, to_currency);

-- إنشاء جدول السندات
CREATE TABLE IF NOT EXISTS receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid REFERENCES transactions(id) ON DELETE CASCADE,
  receipt_number text UNIQUE NOT NULL,
  pdf_url text,
  created_at timestamptz DEFAULT now()
);

-- إنشاء جدول إعدادات التطبيق
CREATE TABLE IF NOT EXISTS app_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_name text DEFAULT 'محل الحوالات المالية',
  shop_logo text,
  shop_phone text,
  shop_address text,
  pin_code text DEFAULT '1234',
  updated_at timestamptz DEFAULT now()
);

INSERT INTO app_settings (shop_name, pin_code)
VALUES ('محل الحوالات المالية', '1234')
ON CONFLICT DO NOTHING;

-- تفعيل RLS
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE debts ENABLE ROW LEVEL SECURITY;
ALTER TABLE exchange_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

-- سياسات RLS
CREATE POLICY "Allow all operations on customers"
  ON customers FOR ALL
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow all operations on transactions"
  ON transactions FOR ALL
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow all operations on debts"
  ON debts FOR ALL
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow all operations on exchange_rates"
  ON exchange_rates FOR ALL
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow all operations on receipts"
  ON receipts FOR ALL
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow all operations on app_settings"
  ON app_settings FOR ALL
  USING (true)
  WITH CHECK (true);

-- دالة لتحديث updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_customers_updated_at
  BEFORE UPDATE ON customers
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_app_settings_updated_at
  BEFORE UPDATE ON app_settings
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- دالة لإنشاء رقم حوالة
CREATE OR REPLACE FUNCTION generate_transaction_number()
RETURNS text AS $$
DECLARE
  new_number text;
  counter int;
BEGIN
  SELECT COUNT(*) INTO counter FROM transactions WHERE created_at::date = CURRENT_DATE;
  new_number := 'TXN-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-' || LPAD((counter + 1)::text, 4, '0');
  RETURN new_number;
END;
$$ LANGUAGE plpgsql;

-- View للإحصائيات
CREATE OR REPLACE VIEW customer_statistics AS
SELECT 
  c.id,
  c.name,
  c.phone,
  c.balance,
  COUNT(DISTINCT t.id) as total_transactions,
  COALESCE(SUM(t.amount_sent), 0) as total_sent,
  COALESCE(SUM(d.amount - d.paid_amount), 0) as total_debt
FROM customers c
LEFT JOIN transactions t ON c.id = t.customer_id
LEFT JOIN debts d ON c.id = d.customer_id AND d.status != 'paid'
GROUP BY c.id, c.name, c.phone, c.balance;