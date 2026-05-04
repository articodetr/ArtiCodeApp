/*
  # إصلاح VIEW لاستخدام المبالغ الصافية مباشرة
  
  ## المشكلة
  
  الـ VIEW يقوم بخصم العمولة من المبلغ:
  `am.amount - COALESCE(am.commission, 0::numeric)`
  
  لكن بعد التحديثات الجديدة، `am.amount` هو بالفعل المبلغ الصافي
  (محسوب بعد العمولة)، لذلك يتم خصم العمولة مرتين.
  
  ## الحل
  
  استخدام `am.amount` مباشرة بدون خصم العمولة
  لأن الـ triggers تحسب المبلغ الصافي تلقائياً
*/

-- حذف VIEW القديم
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

-- إنشاء VIEW جديد يستخدم المبالغ الصافية مباشرة
CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,
  -- إجمالي الوارد (incoming)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_incoming,
  -- إجمالي الصادر (outgoing)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,
  -- الرصيد = incoming - outgoing
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ), 0
  ) AS balance
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
  -- استبعاد حركات العمولة المنفصلة (is_commission_movement = true)
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, am.currency
HAVING 
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ), 0
  ) <> 0
  OR c.phone = 'PROFIT_LOSS_ACCOUNT'
ORDER BY c.name, ABS(
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ), 0
  )
) DESC;

-- تعيين المالك
ALTER VIEW customer_balances_by_currency OWNER TO postgres;

-- إضافة تعليق توضيحي
COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يستخدم المبالغ الصافية (amount) مباشرة لأنها محسوبة بعد العمولة';
