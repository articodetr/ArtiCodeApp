/*
  # توحيد منطق حساب الرصيد في VIEW مع ملف PDF
  
  ## المشكلة
  
  VIEW الحالي يستخدم المنطق:
  - balance = outgoing - incoming
  - outgoing موجب = "لنا عنده"
  - incoming سالب = "له عندنا"
  
  لكن ملف PDF يستخدم المنطق:
  - balance = incoming - outgoing
  - موجب = "له عندنا" (العميل دائن)
  - سالب = "عليه" (العميل مدين)
  
  ## مثال على جلال
  
  في VIEW الحالي:
  - جلال: outgoing = 4880, incoming = 0
  - balance = 4880 - 0 = +4880 (موجب = أخضر = "لنا عنده")
  
  في PDF:
  - incoming = 0, outgoing = 4880
  - balance = 0 - 4880 = -4880 (سالب = "عليه")
  
  ## الحل
  
  عكس المعادلة في VIEW لتصبح:
  - balance = incoming - outgoing
  - موجب = "له عندنا" (أحمر)
  - سالب = "عليه" (أخضر)
  
  هذا يوحد المنطق في جميع أجزاء التطبيق.
*/

CREATE OR REPLACE VIEW customer_balances AS
SELECT
  c.id,
  c.name,
  c.phone,
  
  -- إجمالي التسليمات (للعرض فقط)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_incoming,
  
  -- إجمالي الاستلامات (للعرض فقط)
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
  -- الآن balance = incoming - outgoing (متطابق مع ملف PDF)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ), 0
  ) AS balance,
  
  am.currency,
  MAX(am.created_at) AS last_activity
  
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
WHERE c.phone <> 'PROFIT_LOSS_ACCOUNT' OR c.phone IS NULL
GROUP BY c.id, c.name, c.phone, am.currency;

ALTER VIEW customer_balances OWNER TO postgres;

COMMENT ON VIEW customer_balances IS 'أرصدة العملاء - موحد مع منطق ملف PDF حيث balance = incoming - outgoing';
