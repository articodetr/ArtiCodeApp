/*
  # إصلاح حساب الأرصدة لتضمين حركات العمولات المستلمة
  
  ## المشكلة
  الـ view الحالي يستثني جميع حركات العمولة (is_commission_movement = true) من حساب أرصدة العملاء العاديين.
  هذا خطأ لأن العملاء الذين يستلمون عمولات يجب أن تُحسب في أرصدتهم.
  
  ## الحل
  - للعملاء العاديين: احسب جميع الحركات (بما فيها حركات العمولة التي يستلمونها)
  - لحساب الأرباح والخسائر: احسب حركات العمولة فقط (كما هو الآن)
  
  ## التفاصيل
  1. تحديث VIEW customer_balances
  2. تحديث VIEW customer_balances_by_currency
*/

-- تحديث VIEW customer_balances
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
  AND (
    -- للعملاء العاديين: تضمين جميع الحركات (حتى حركات العمولة المستلمة)
    (c.phone IS NULL OR c.phone <> 'PROFIT_LOSS_ACCOUNT')
    OR
    -- لحساب الأرباح والخسائر: تضمين حركات العمولة فقط
    (c.phone = 'PROFIT_LOSS_ACCOUNT' AND am.is_commission_movement = true)
  )
GROUP BY c.id, c.name, c.phone, am.currency;

ALTER VIEW customer_balances OWNER TO postgres;

COMMENT ON VIEW customer_balances IS 'أرصدة العملاء - يتضمن حساب الأرباح والخسائر مع حركات العمولات فقط، والعملاء العاديين مع جميع الحركات';

-- تحديث VIEW customer_balances_by_currency
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
  
  -- الرصيد الموحد
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
  AND (
    -- للعملاء العاديين: تضمين جميع الحركات
    (c.phone IS NULL OR c.phone <> 'PROFIT_LOSS_ACCOUNT')
    OR
    -- لحساب الأرباح والخسائر: تضمين حركات العمولة فقط
    (c.phone = 'PROFIT_LOSS_ACCOUNT' AND am.is_commission_movement = true)
  )
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

COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يتضمين جميع الحركات للعملاء العاديين وحركات العمولات فقط لحساب الأرباح';