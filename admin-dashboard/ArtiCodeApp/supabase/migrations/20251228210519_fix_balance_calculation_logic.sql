/*
  # إصلاح منطق حساب الأرصدة - توحيد المفاهيم
  
  ## المفهوم الأساسي الجديد
  
  ### تعريف الرصيد (Customer Balance)
  - **الرصيد** يمثل مديونية العميل للمحل
  - **رصيد موجب (+)**: "لنا عندك" = العميل مدين للمحل
  - **رصيد سالب (-)**: "لك عندنا" = المحل مدين للعميل
  
  ### أنواع الحركات
  1. **استلام من العميل** (RECEIVE_FROM_CUSTOMER)
     - النوع في الداتابيس: `movement_type = 'outgoing'`
     - المعنى: العميل دفع للمحل
     - التأثير: يُخصم من الرصيد (balance = balance - amount)
     - مثال: رصيد +1000 → استلام 300 → رصيد جديد +700
  
  2. **تسليم للعميل** (PAY_TO_CUSTOMER)
     - النوع في الداتابيس: `movement_type = 'incoming'`
     - المعنى: المحل دفع للعميل
     - التأثير: يُضيف للرصيد (balance = balance + amount)
     - مثال: رصيد +1000 → تسليم 200 → رصيد جديد +1200
  
  ## التغييرات الرئيسية
  
  ### 1. تحديث دالة حساب رصيد العميل
  - قلب المعادلة من: incoming - outgoing
  - إلى المعادلة الصحيحة: incoming - outgoing
  - مع incoming للتسليم (يضيف) و outgoing للاستلام (يخصم)
  
  ### 2. تحديث view الأرصدة حسب العملة
  - قلب حساب الرصيد ليتوافق مع المنطق الجديد
  - إضافة تعليقات توضيحية
  
  ### 3. تحديث trigger تحديث الرصيد
  - التأكد من استخدام نفس المنطق في كل مكان
  
  ## أمثلة واقعية
  
  ### مثال 1: عميل جديد (رصيد = 0)
  - المحل يسلم للعميل 500 دولار
  - الرصيد الجديد = 0 + 500 = +500 (لنا عنده)
  
  ### مثال 2: عميل برصيد موجب
  - الرصيد الحالي = +1000 (لنا عنده 1000)
  - العميل يستلم منه المحل 300
  - الرصيد الجديد = 1000 - 300 = +700 (لنا عنده 700)
  
  ### مثال 3: رصيد يصبح سالب
  - الرصيد الحالي = +200 (لنا عنده 200)
  - العميل يستلم منه المحل 500
  - الرصيد الجديد = 200 - 500 = -300 (له عندنا 300)
*/

-- 1. تحديث دالة حساب رصيد العميل
CREATE OR REPLACE FUNCTION calculate_customer_balance(p_customer_id uuid)
RETURNS TABLE (
  total_incoming decimal,
  total_outgoing decimal,
  net_balance decimal
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    -- incoming = تسليم للعميل (المحل دفع له)
    COALESCE(SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE 0 END), 0) as total_incoming,
    -- outgoing = استلام من العميل (العميل دفع للمحل)
    COALESCE(SUM(CASE WHEN movement_type = 'outgoing' THEN amount ELSE 0 END), 0) as total_outgoing,
    -- الرصيد = التسليم - الاستلام (incoming - outgoing)
    -- رصيد موجب يعني "لنا عنده"
    COALESCE(SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE -amount END), 0) as net_balance
  FROM account_movements
  WHERE customer_id = p_customer_id;
END;
$$ LANGUAGE plpgsql;

-- 2. تحديث view الحسابات الجارية
CREATE OR REPLACE VIEW customer_accounts AS
SELECT 
  c.id,
  c.name,
  c.phone,
  c.email,
  c.address,
  -- incoming = تسليم للعميل (يضيف للرصيد)
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) as total_incoming,
  -- outgoing = استلام من العميل (يخصم من الرصيد)
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) as total_outgoing,
  -- الرصيد = التسليم - الاستلام (رصيد موجب = لنا عنده)
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE -am.amount END), 0) as balance,
  COUNT(am.id) as total_movements,
  c.created_at,
  c.updated_at
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.created_at, c.updated_at;

-- 3. تحديث trigger تحديث رصيد العميل
CREATE OR REPLACE FUNCTION update_customer_balance()
RETURNS TRIGGER AS $$
DECLARE
  customer_balance decimal;
BEGIN
  -- حساب الرصيد الجديد
  -- incoming (تسليم) يضيف، outgoing (استلام) يخصم
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

-- 4. تحديث view الأرصدة حسب العملة
DROP VIEW IF EXISTS customer_balances_by_currency;

CREATE OR REPLACE VIEW customer_balances_by_currency AS
WITH movement_amounts AS (
  -- حساب مبالغ الحوالات حسب عملتها
  SELECT 
    c.id AS customer_id,
    c.name AS customer_name,
    am.currency,
    -- incoming = تسليم للعميل (يضيف للرصيد)
    CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END as incoming_amount,
    -- outgoing = استلام من العميل (يخصم من الرصيد)
    CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END as outgoing_amount
  FROM customers c
  JOIN account_movements am ON c.id = am.customer_id
  
  UNION ALL
  
  -- حساب العمولات حسب عملتها الخاصة
  -- العمولات دائماً تُخصم من رصيد العميل (outgoing)
  SELECT 
    c.id AS customer_id,
    c.name AS customer_name,
    am.commission_currency as currency,
    0 as incoming_amount,
    CASE 
      WHEN am.commission IS NOT NULL AND am.commission > 0 
      THEN am.commission 
      ELSE 0 
    END as outgoing_amount
  FROM customers c
  JOIN account_movements am ON c.id = am.customer_id
  WHERE am.commission IS NOT NULL AND am.commission > 0
)
SELECT 
  customer_id,
  customer_name,
  currency,
  COALESCE(SUM(incoming_amount), 0) as total_incoming,
  COALESCE(SUM(outgoing_amount), 0) as total_outgoing,
  -- الرصيد = التسليم - الاستلام
  -- رصيد موجب = "لنا عنده"، رصيد سالب = "له عندنا"
  COALESCE(SUM(incoming_amount) - SUM(outgoing_amount), 0) as balance
FROM movement_amounts
GROUP BY customer_id, customer_name, currency
HAVING COALESCE(SUM(incoming_amount) - SUM(outgoing_amount), 0) <> 0
ORDER BY customer_name, ABS(COALESCE(SUM(incoming_amount) - SUM(outgoing_amount), 0)) DESC;

-- 5. إعادة حساب جميع الأرصدة الحالية
-- هذا يضمن أن جميع الأرصدة محدثة حسب المنطق الجديد
DO $$
DECLARE
  customer_record RECORD;
  new_balance decimal;
BEGIN
  FOR customer_record IN SELECT id FROM customers LOOP
    SELECT COALESCE(SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE -amount END), 0)
    INTO new_balance
    FROM account_movements
    WHERE customer_id = customer_record.id;
    
    UPDATE customers
    SET balance = new_balance
    WHERE id = customer_record.id;
  END LOOP;
END $$;