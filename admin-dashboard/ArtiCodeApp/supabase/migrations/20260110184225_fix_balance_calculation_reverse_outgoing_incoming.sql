/*
  # إصلاح منطق حساب الأرصدة (عكس الإشارة)

  ## المشكلة
  الرصيد يُحسب بشكل معكوس:
  - عندما يكون outgoing (صادر/عليه) يظهر كرصيد موجب (+)
  - عندما يكون incoming (وارد/له) يظهر كرصيد سالب (-)

  ## الحل
  عكس منطق الحساب:
  - incoming (له): موجب (+)
  - outgoing (عليه): سالب (-)

  هذا يتماشى مع المنطق الصحيح:
  - إذا العميل "له" (incoming) = رصيد موجب (نحن ندين له)
  - إذا كان "عليه" (outgoing) = رصيد سالب (هو مدين لنا)
*/

-- حذف الـ view القديم
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

-- إعادة إنشاء الـ view بالمنطق الصحيح
CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,
  -- إجمالي المبالغ الواردة (incoming = له)
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  -- إجمالي المبالغ الصادرة (outgoing = عليه = يدفع)
  COALESCE(SUM(
    CASE 
      WHEN am.movement_type = 'outgoing' THEN am.amount
      ELSE 0
    END
  ), 0) AS total_outgoing,
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
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, am.currency
HAVING COALESCE(sum(
    CASE
      WHEN am.movement_type = 'outgoing' THEN am.amount
      WHEN am.movement_type = 'incoming' THEN -am.amount
      ELSE 0
    END
  ), 0) <> 0
ORDER BY c.name, abs(COALESCE(sum(
    CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        WHEN am.movement_type = 'incoming' THEN -am.amount
        ELSE 0
    END), 0)) DESC;
