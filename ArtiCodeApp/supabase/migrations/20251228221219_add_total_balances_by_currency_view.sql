/*
  # إضافة VIEW لحساب إجمالي المبالغ لكل عملة

  ## الوصف
  
  هذا الـ VIEW يحسب إجمالي جميع المبالغ (الواردة والصادرة) لكل عملة من جدول account_movements
  لعرض مطابقة شاملة لجميع الأموال في النظام.

  ### 1. الهدف
    - حساب إجمالي المبالغ الواردة (incoming) لكل عملة
    - حساب إجمالي المبالغ الصادرة (outgoing) لكل عملة
    - حساب إجمالي العمولات حسب عملتها
    - حساب الفارق الصافي (outgoing - incoming)
  
  ### 2. الاستخدام
    - يستخدم في صفحة الإحصاءات لعرض ملخص المبالغ لكل عملة
    - يساعد في معرفة إجمالي الأموال "عندي" و"لي" لكل عملة
  
  ### 3. آلية العمل
    - الجزء الأول: جمع مبالغ الحوالات حسب نوعها (incoming/outgoing)
    - الجزء الثاني: جمع العمولات حسب عملتها وإضافتها للصادر
    - GROUP BY لتجميع النتائج حسب العملة
  
  ## مثال على النتائج
  
  | currency | total_incoming | total_outgoing | balance    |
  |----------|---------------|----------------|------------|
  | USD      | 50000         | 45000          | -5000      |
  | SAR      | 20000         | 25000          | 5000       |
  | YER      | 0             | 15000          | 15000      |
  
  - USD: عندك 5000 دولار (سالب = المبالغ الواردة أكثر)
  - SAR: لك 5000 ريال (موجب = المبالغ الصادرة أكثر)
  - YER: لك 15000 ريال يمني (كله عمولات صادرة)
  
  ## الأمان
  - VIEW للقراءة فقط
  - لا توجد مخاطر أمنية
*/

-- إنشاء VIEW لحساب إجمالي المبالغ لكل عملة
CREATE OR REPLACE VIEW total_balances_by_currency AS
WITH all_currency_movements AS (
  -- حساب مبالغ الحوالات حسب عملتها
  SELECT 
    am.currency,
    CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END as incoming_amount,
    CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END as outgoing_amount
  FROM account_movements am
  
  UNION ALL
  
  -- حساب العمولات حسب عملتها الخاصة وإضافتها للصادر
  SELECT 
    am.commission_currency as currency,
    0 as incoming_amount,
    CASE 
      WHEN am.commission IS NOT NULL AND am.commission > 0 
      THEN am.commission 
      ELSE 0 
    END as outgoing_amount
  FROM account_movements am
  WHERE am.commission IS NOT NULL AND am.commission > 0
)
SELECT 
  currency,
  COALESCE(SUM(incoming_amount), 0) as total_incoming,
  COALESCE(SUM(outgoing_amount), 0) as total_outgoing,
  COALESCE(SUM(outgoing_amount) - SUM(incoming_amount), 0) as balance
FROM all_currency_movements
GROUP BY currency
ORDER BY currency;