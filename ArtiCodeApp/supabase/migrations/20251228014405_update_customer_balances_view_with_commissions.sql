/*
  # تحديث View الأرصدة ليحسب العمولات بشكل منفصل

  ## التفاصيل
  
  ### 1. المشكلة
    - VIEW الحالي customer_balances_by_currency يحسب فقط مبالغ الحوالات
    - العمولات لا يتم حسابها بعملتها الخاصة
    - عندما تكون عملة العمولة مختلفة عن عملة الحوالة، لا يتم احتسابها بشكل صحيح
  
  ### 2. الحل
    - إعادة إنشاء VIEW ليحسب الحركات والعمولات بشكل منفصل
    - كل عملة تُحسب بشكل مستقل تماماً
    - العمولات تُضاف إلى الرصيد بعملتها الخاصة
  
  ### 3. آلية العمل
    - الجزء الأول: يحسب مبالغ الحوالات (amount) حسب عملتها
    - الجزء الثاني: يحسب العمولات (commission) حسب commission_currency
    - UNION ALL يجمع النتائج
    - GROUP BY النهائي يجمع كل عملة على حدة
  
  ## أمثلة
  
  مثال 1: حوالة دولار + عمولة دولار
  - سيتم جمعهما في رصيد الدولار
  
  مثال 2: حوالة دولار + عمولة ريال يمني
  - الدولار يُحسب في رصيد الدولار
  - الريال اليمني يُحسب في رصيد الريال اليمني
  
  ## الأمان
  - VIEW للقراءة فقط، لا يوجد مخاطر أمنية
*/

-- حذف VIEW القديم إذا كان موجوداً
DROP VIEW IF EXISTS customer_balances_by_currency;

-- إنشاء VIEW جديد يحسب الحوالات والعمولات بشكل منفصل
CREATE OR REPLACE VIEW customer_balances_by_currency AS
WITH movement_amounts AS (
  -- حساب مبالغ الحوالات حسب عملتها
  SELECT 
    c.id AS customer_id,
    c.name AS customer_name,
    am.currency,
    CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END as incoming_amount,
    CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END as outgoing_amount
  FROM customers c
  JOIN account_movements am ON c.id = am.customer_id
  
  UNION ALL
  
  -- حساب العمولات حسب عملتها الخاصة
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
  COALESCE(SUM(outgoing_amount) - SUM(incoming_amount), 0) as balance
FROM movement_amounts
GROUP BY customer_id, customer_name, currency
HAVING COALESCE(SUM(outgoing_amount) - SUM(incoming_amount), 0) <> 0
ORDER BY customer_name, ABS(COALESCE(SUM(outgoing_amount) - SUM(incoming_amount), 0)) DESC;
