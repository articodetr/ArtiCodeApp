/*
  # تبسيط النظام إلى حسابات جارية

  ## التغييرات الرئيسية
  
  ### 1. جدول جديد: account_movements (حركات الحساب)
  - `id` (uuid) - المعرف الفريد
  - `movement_number` (text) - رقم الحركة التلقائي
  - `customer_id` (uuid) - معرف العميل
  - `movement_type` (text) - نوع الحركة (incoming وارد / outgoing صادر)
  - `amount` (decimal) - المبلغ
  - `currency` (text) - العملة
  - `notes` (text) - ملاحظات اختيارية
  - `created_at` (timestamptz) - تاريخ الإنشاء
  
  ### 2. دالة لحساب رصيد العميل
  - حساب إجمالي الوارد والصادر
  - حساب الرصيد الصافي
  
  ### 3. دالة لإنشاء رقم الحركة التلقائي
  - صيغة: MOV-YYYYMMDD-####
  
  ### 4. View للحسابات الجارية
  - عرض ملخص لكل عميل
  - إجمالي الوارد، الصادر، والرصيد
  
  ## الأمان
  - تفعيل RLS
  - سياسات للوصول الكامل (تطبيق مستخدم واحد)
*/

-- إنشاء جدول حركات الحساب
CREATE TABLE IF NOT EXISTS account_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  movement_number text UNIQUE NOT NULL,
  customer_id uuid REFERENCES customers(id) ON DELETE CASCADE,
  movement_type text NOT NULL CHECK (movement_type IN ('incoming', 'outgoing')),
  amount decimal(15, 2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'USD',
  notes text,
  created_at timestamptz DEFAULT now()
);

-- إنشاء فهرس للأداء
CREATE INDEX IF NOT EXISTS account_movements_customer_id_idx ON account_movements(customer_id);
CREATE INDEX IF NOT EXISTS account_movements_created_at_idx ON account_movements(created_at DESC);
CREATE INDEX IF NOT EXISTS account_movements_type_idx ON account_movements(movement_type);

-- دالة لإنشاء رقم حركة تلقائي
CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS text AS $$
DECLARE
  new_number text;
  counter int;
BEGIN
  -- الحصول على العدد الحالي من الحركات لهذا اليوم
  SELECT COUNT(*) INTO counter FROM account_movements WHERE DATE(created_at) = CURRENT_DATE;
  
  -- توليد رقم جديد
  LOOP
    counter := counter + 1;
    new_number := 'MOV-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-' || LPAD(counter::text, 4, '0');
    
    -- التحقق من عدم وجود الرقم
    EXIT WHEN NOT EXISTS (SELECT 1 FROM account_movements WHERE movement_number = new_number);
  END LOOP;
  
  RETURN new_number;
END;
$$ LANGUAGE plpgsql;

-- دالة لحساب رصيد عميل
CREATE OR REPLACE FUNCTION calculate_customer_balance(p_customer_id uuid)
RETURNS TABLE (
  total_incoming decimal,
  total_outgoing decimal,
  net_balance decimal
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COALESCE(SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE 0 END), 0) as total_incoming,
    COALESCE(SUM(CASE WHEN movement_type = 'outgoing' THEN amount ELSE 0 END), 0) as total_outgoing,
    COALESCE(SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE -amount END), 0) as net_balance
  FROM account_movements
  WHERE customer_id = p_customer_id;
END;
$$ LANGUAGE plpgsql;

-- View للحسابات الجارية
CREATE OR REPLACE VIEW customer_accounts AS
SELECT 
  c.id,
  c.name,
  c.phone,
  c.email,
  c.address,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) as total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) as total_outgoing,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE -am.amount END), 0) as balance,
  COUNT(am.id) as total_movements,
  c.created_at,
  c.updated_at
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.created_at, c.updated_at;

-- Trigger لتحديث رصيد العميل تلقائياً في جدول customers
CREATE OR REPLACE FUNCTION update_customer_balance()
RETURNS TRIGGER AS $$
DECLARE
  customer_balance decimal;
BEGIN
  -- حساب الرصيد الجديد
  SELECT COALESCE(SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE -amount END), 0)
  INTO customer_balance
  FROM account_movements
  WHERE customer_id = COALESCE(NEW.customer_id, OLD.customer_id);
  
  -- تحديث رصيد العميل
  UPDATE customers
  SET balance = customer_balance
  WHERE id = COALESCE(NEW.customer_id, OLD.customer_id);
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- إضافة Trigger على جدول account_movements
DROP TRIGGER IF EXISTS update_balance_on_movement ON account_movements;
CREATE TRIGGER update_balance_on_movement
  AFTER INSERT OR UPDATE OR DELETE ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION update_customer_balance();

-- تفعيل RLS
ALTER TABLE account_movements ENABLE ROW LEVEL SECURITY;

-- سياسات RLS (السماح بجميع العمليات)
CREATE POLICY "Allow all operations on account_movements"
  ON account_movements FOR ALL
  USING (true)
  WITH CHECK (true);