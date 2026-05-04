/*
  # توحيد منطق حساب الرصيد في customer_balances_by_currency
  
  ## المشكلة
  
  VIEW customer_balances_by_currency يستخدم المنطق القديم:
  - balance = outgoing - incoming
  - outgoing موجب = "لنا عنده"
  - incoming سالب = "له عندنا"
  
  لكن VIEW customer_balances و ملف PDF يستخدمان المنطق الجديد:
  - balance = incoming - outgoing
  - موجب = "له عندنا"
  - سالب = "عليه"
  
  ## مثال على جلال
  
  في VIEW الحالي (customer_balances_by_currency):
  - جلال: outgoing = 4880, incoming = 0
  - balance = 4880 - 0 = +4880 (موجب = أخضر = "لنا عنده")
  
  في VIEW الجديد (customer_balances) و PDF:
  - جلال: outgoing = 4880, incoming = 0
  - balance = 0 - 4880 = -4880 (سالب = أخضر = "عليه")
  
  ## الحل
  
  تحديث VIEW customer_balances_by_currency ليستخدم نفس المنطق الموحد:
  - balance = incoming - outgoing
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
  
  -- الرصيد الموحد:
  -- incoming (تسليم للعميل) = له عندنا = موجب (+)
  -- outgoing (استلام من العميل) = عليه = سالب (-)
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

ALTER VIEW customer_balances_by_currency OWNER TO postgres;

COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - موحد مع customer_balances و PDF حيث balance = incoming - outgoing';
