/*
  # إصلاح ظهور حركات حساب الأرباح والخسائر

  ## المشكلة
  حساب الأرباح والخسائر لا يظهر في Views لأنه:
  1. مستثنى من customer_balances view (WHERE c.phone <> 'PROFIT_LOSS_ACCOUNT')
  2. حركاته (العمولات) لها is_commission_movement = true وهي مستثناة من الحساب
  
  ## الحل
  1. إزالة استثناء حساب الأرباح والخسائر من WHERE
  2. تضمين حركات العمولة فقط لحساب الأرباح والخسائر
  
  ## التأثير
  - حساب الأرباح والخسائر سيظهر في قائمة العملاء
  - رصيده سيتم حسابه من حركات العمولات فقط
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
    -- للعملاء العاديين: استثناء حركات العمولة
    (c.phone IS NULL OR c.phone <> 'PROFIT_LOSS_ACCOUNT') AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
    OR
    -- لحساب الأرباح والخسائر: تضمين حركات العمولة فقط
    (c.phone = 'PROFIT_LOSS_ACCOUNT' AND am.is_commission_movement = true)
  )
GROUP BY c.id, c.name, c.phone, am.currency;

ALTER VIEW customer_balances OWNER TO postgres;

COMMENT ON VIEW customer_balances IS 'أرصدة العملاء - يتضمن حساب الأرباح والخسائر مع حركات العمولات فقط';

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
    -- للعملاء العاديين: استثناء حركات العمولة
    (c.phone IS NULL OR c.phone <> 'PROFIT_LOSS_ACCOUNT') AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
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

COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يتضمن حساب الأرباح والخسائر مع حركات العمولات فقط';

-- تحديث VIEW customers_with_last_activity
DROP VIEW IF EXISTS customers_with_last_activity CASCADE;

CREATE OR REPLACE VIEW customers_with_last_activity AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.notes,
  c.created_at,
  MAX(am.created_at) as last_activity,
  (c.phone = 'PROFIT_LOSS_ACCOUNT') as is_profit_loss_account
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.notes, c.created_at
ORDER BY 
  (c.phone = 'PROFIT_LOSS_ACCOUNT') DESC,
  last_activity DESC NULLS LAST, 
  c.created_at DESC;

ALTER VIEW customers_with_last_activity OWNER TO postgres;

COMMENT ON VIEW customers_with_last_activity IS 'عرض جميع العملاء مع آخر نشاط - يتضمن حساب الأرباح والخسائر';
