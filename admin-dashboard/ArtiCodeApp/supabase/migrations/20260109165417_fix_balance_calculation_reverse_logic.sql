/*
  # إصلاح منطق حساب الرصيد (عكس الاتجاه)
  
  ## المشكلة
  
  المنطق الحالي معكوس:
  - incoming (تسليم للعميل) → يزيد الرصيد → موجب ❌
  - outgoing (استلام من العميل) → ينقص الرصيد → سالب ❌
  
  ## المنطق الصحيح
  
  - incoming (تسليم للعميل) → العميل له عندنا (دائن) → رصيد سالب ✓
  - outgoing (استلام من العميل) → لنا عند العميل (مدين) → رصيد موجب ✓
  
  ## الحل
  
  عكس إشارات الحساب في VIEW
*/

DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,
  
  -- إجمالي التسليمات (incoming) - للعرض فقط
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_incoming,
  
  -- إجمالي الاستلامات (outgoing) - للعرض فقط
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,
  
  -- الرصيد الصحيح:
  -- outgoing (استلام من العميل) = لنا عنده = موجب (+)
  -- incoming (تسليم للعميل) = له عندنا = سالب (-)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        WHEN am.movement_type = 'incoming' THEN -am.amount
        ELSE 0
      END
    ), 0
  ) AS balance
  
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, am.currency
HAVING 
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        WHEN am.movement_type = 'incoming' THEN -am.amount
        ELSE 0
      END
    ), 0
  ) <> 0
  OR c.phone = 'PROFIT_LOSS_ACCOUNT'
ORDER BY c.name, ABS(
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        WHEN am.movement_type = 'incoming' THEN -am.amount
        ELSE 0
      END
    ), 0
  )
) DESC;

ALTER VIEW customer_balances_by_currency OWNER TO postgres;

COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - outgoing (استلام) = موجب، incoming (تسليم) = سالب';
