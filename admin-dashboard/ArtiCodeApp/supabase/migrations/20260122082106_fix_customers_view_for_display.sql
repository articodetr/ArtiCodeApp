/*
  # إصلاح عرض العملاء
  
  ## التغييرات
  
  ### 1. إنشاء View: customers_with_last_activity
  - عرض يجمع بيانات العملاء مع آخر تاريخ نشاط
  - يستخدم آخر حركة من account_movements
  - إذا لم يكن هناك حركات، يستخدم تاريخ إنشاء العميل
  
  ### 2. إنشاء View: customer_balances_by_currency
  - عرض يحسب الأرصدة لكل عميل حسب العملة
  - من جدول account_movements
  
  ## الغرض
  - تمكين عرض قائمة العملاء بشكل صحيح
  - عرض الأرصدة حسب العملة لكل عميل
*/

-- إنشاء view للعملاء مع آخر نشاط
CREATE OR REPLACE VIEW customers_with_last_activity AS
SELECT 
  c.id,
  c.name,
  c.phone,
  c.email,
  c.address,
  c.balance,
  c.notes,
  c.created_at,
  c.updated_at,
  CASE 
    WHEN c.phone = 'PROFIT_LOSS_ACCOUNT' THEN true 
    ELSE false 
  END as is_profit_loss_account,
  COALESCE(MAX(am.created_at), c.created_at) as last_activity_date
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id 
  AND am.is_commission_movement = false
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.balance, 
         c.notes, c.created_at, c.updated_at;

-- إنشاء view للأرصدة حسب العملة
CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT 
  c.id as customer_id,
  am.currency,
  SUM(
    CASE 
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ) as balance
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
  AND am.is_commission_movement = false
WHERE am.currency IS NOT NULL
GROUP BY c.id, am.currency
HAVING SUM(
  CASE 
    WHEN am.movement_type = 'incoming' THEN am.amount
    WHEN am.movement_type = 'outgoing' THEN -am.amount
    ELSE 0
  END
) != 0;

-- منح الصلاحيات
GRANT SELECT ON customers_with_last_activity TO authenticated, anon;
GRANT SELECT ON customer_balances_by_currency TO authenticated, anon;
