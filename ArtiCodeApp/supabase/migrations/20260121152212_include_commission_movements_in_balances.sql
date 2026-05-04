/*
  # إصلاح عرض حركات العمولة في صفحة العملاء

  ## المشكلة
  - الـ view `customer_balances_by_currency` يستبعد حركات العمولة
  - السطر: `AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)`
  - هذا يمنع عرض العمولات في صفحة العملاء

  ## الحل
  - إزالة الشرط الذي يستبعد حركات العمولة
  - حركات العمولة يجب أن تُحسب في الأرصدة لأنها جزء من حساب الأرباح والخسائر
*/

DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,
  -- إجمالي المبالغ الواردة (incoming = له)
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  -- إجمالي المبالغ الصادرة (outgoing = عليه)
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  -- الرصيد النهائي: incoming موجب، outgoing سالب
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
