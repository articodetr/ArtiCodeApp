/*
  # إصلاح VIEW customer_balances - عدم خصم العمولة مرة أخرى
  
  ## المشكلة
  
  VIEW الحالي يخصم العمولة من المبالغ:
  ```sql
  am.amount - COALESCE(am.commission, 0)
  ```
  
  لكن حقل `amount` بالفعل يحتوي على المبلغ الصحيح بعد معالجة العمولة!
  
  مثال:
  - التحويل: 5000 USD مع عمولة 120 USD لجلال
  - جلال outgoing: amount = 4880 (مطروح منه العمولة بالفعل)
  - عماد incoming: amount = 5000 (المبلغ الكامل)
  
  VIEW الحالي يحسب:
  - جلال: 4880 - 120 = 4760 ❌
  - عماد: 5000 - 120 = 4880 ❌
  
  ## الحل الصحيح
  
  استخدام حقل `amount` مباشرة بدون خصم العمولة:
  - جلال: outgoing = 4880 (لنا عنده) ✓
  - عماد: incoming = -5000 (له عندنا) ✓
  
  حقل `commission` موجود فقط للمرجع والعرض، ولا يجب خصمه من الرصيد!
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
  
  -- الرصيد الصحيح:
  -- outgoing (استلام من العميل) = لنا عنده = موجب (+)
  -- incoming (تسليم للعميل) = له عندنا = سالب (-)
  -- لا نخصم العمولة لأن amount يحتوي بالفعل على المبلغ الصحيح
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN -am.amount
        WHEN am.movement_type = 'outgoing' THEN am.amount
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

COMMENT ON VIEW customer_balances IS 'أرصدة العملاء - يستخدم حقل amount مباشرة (بدون خصم العمولة) لأن amount يحتوي بالفعل على المبلغ الصحيح';
