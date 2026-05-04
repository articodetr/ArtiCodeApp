/*
  # إصلاح عرض حساب الأرباح والخسائر في VIEWs

  ## المشكلة

  بعد تطبيق التعديل السابق، حساب الأرباح والخسائر لا يظهر في customer_balances_by_currency
  لأن جميع حركاته محددة كـ is_commission_movement = true، والـ view يستبعدها.

  ## الحل

  تعديل شرط الـ JOIN ليكون:
  - للعملاء العاديين: استبعاد حركات العمولة المنفصلة (is_commission_movement = false)
  - لحساب الأرباح والخسائر: تضمين جميع الحركات (بما فيها حركات العمولة)

  ## المنطق الجديد

  ```sql
  LEFT JOIN account_movements am
    ON c.id = am.customer_id
    AND (
      -- للعملاء العاديين: استبعاد حركات العمولة المنفصلة
      (c.phone != 'PROFIT_LOSS_ACCOUNT' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false))
      OR
      -- لحساب الأرباح والخسائر: تضمين جميع الحركات
      c.phone = 'PROFIT_LOSS_ACCOUNT'
    )
  ```

  ## النتيجة المتوقعة

  - العملاء العاديين: يتم حساب رصيدهم بخصم العمولة من كل حركة، واستبعاد حركات العمولة المنفصلة
  - حساب الأرباح والخسائر: يظهر بشكل صحيح مع حركات العمولة
*/

-- ==========================================
-- تحديث customer_balances_by_currency
-- ==========================================

DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,

  -- إجمالي الوارد (تسليم للعميل - يزيد الرصيد)
  -- يتم طرح العمولة من كل حركة incoming للعملاء العاديين فقط
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN
          CASE
            -- للعملاء العاديين: طرح العمولة
            WHEN c.phone != 'PROFIT_LOSS_ACCOUNT' THEN (am.amount - COALESCE(am.commission, 0))
            -- لحساب الأرباح والخسائر: المبلغ كامل
            ELSE am.amount
          END
        ELSE 0
      END
    ), 0
  ) AS total_incoming,

  -- إجمالي الصادر (استلام من العميل - يخفض الرصيد)
  -- يتم طرح العمولة من كل حركة outgoing للعملاء العاديين فقط
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN
          CASE
            -- للعملاء العاديين: طرح العمولة
            WHEN c.phone != 'PROFIT_LOSS_ACCOUNT' THEN (am.amount - COALESCE(am.commission, 0))
            -- لحساب الأرباح والخسائر: المبلغ كامل
            ELSE am.amount
          END
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,

  -- الرصيد الصافي
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN
          CASE
            WHEN c.phone != 'PROFIT_LOSS_ACCOUNT' THEN (am.amount - COALESCE(am.commission, 0))
            ELSE am.amount
          END
        WHEN am.movement_type = 'outgoing' THEN
          CASE
            WHEN c.phone != 'PROFIT_LOSS_ACCOUNT' THEN -(am.amount - COALESCE(am.commission, 0))
            ELSE -am.amount
          END
        ELSE 0
      END
    ), 0
  ) AS balance

FROM customers c

LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND (
    -- للعملاء العاديين: استبعاد حركات العمولة المنفصلة
    (c.phone != 'PROFIT_LOSS_ACCOUNT' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false))
    OR
    -- لحساب الأرباح والخسائر: تضمين جميع الحركات
    c.phone = 'PROFIT_LOSS_ACCOUNT'
  )

WHERE am.currency IS NOT NULL

GROUP BY c.id, c.name, am.currency

-- عرض الأرصدة غير الصفرية، أو أي رصيد لحساب الأرباح والخسائر
HAVING
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN
          CASE
            WHEN c.phone != 'PROFIT_LOSS_ACCOUNT' THEN (am.amount - COALESCE(am.commission, 0))
            ELSE am.amount
          END
        WHEN am.movement_type = 'outgoing' THEN
          CASE
            WHEN c.phone != 'PROFIT_LOSS_ACCOUNT' THEN -(am.amount - COALESCE(am.commission, 0))
            ELSE -am.amount
          END
        ELSE 0
      END
    ), 0
  ) <> 0
  OR c.phone = 'PROFIT_LOSS_ACCOUNT'

ORDER BY
  c.name,
  ABS(COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN
          CASE
            WHEN c.phone != 'PROFIT_LOSS_ACCOUNT' THEN (am.amount - COALESCE(am.commission, 0))
            ELSE am.amount
          END
        WHEN am.movement_type = 'outgoing' THEN
          CASE
            WHEN c.phone != 'PROFIT_LOSS_ACCOUNT' THEN -(am.amount - COALESCE(am.commission, 0))
            ELSE -am.amount
          END
        ELSE 0
      END
    ), 0
  )) DESC;

ALTER VIEW customer_balances_by_currency OWNER TO postgres;

COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء - العملاء العاديين: يخصم العمولة - حساب الأرباح والخسائر: يشمل حركات العمولة كاملة';

-- ==========================================
-- تحديث customer_balances
-- ==========================================

DROP VIEW IF EXISTS customer_balances CASCADE;

CREATE OR REPLACE VIEW customer_balances AS
SELECT
  c.id,
  c.name,
  c.phone,

  -- إجمالي الوارد (بعد خصم العمولة للعملاء العاديين)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
        THEN (am.amount - COALESCE(am.commission, 0))
        ELSE 0
      END
    ), 0
  ) as total_incoming,

  -- إجمالي الصادر (بعد خصم العمولة للعملاء العاديين)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing'
        THEN (am.amount - COALESCE(am.commission, 0))
        ELSE 0
      END
    ), 0
  ) as total_outgoing,

  -- الرصيد الصافي
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
        THEN (am.amount - COALESCE(am.commission, 0))
        WHEN am.movement_type = 'outgoing'
        THEN -(am.amount - COALESCE(am.commission, 0))
        ELSE 0
      END
    ), 0
  ) as balance,

  am.currency,
  MAX(am.created_at) as last_activity

FROM customers c

-- استبعاد حركات العمولة المنفصلة للعملاء العاديين فقط
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)

WHERE
  c.phone != 'PROFIT_LOSS_ACCOUNT'
  OR c.phone IS NULL

GROUP BY c.id, c.name, c.phone, am.currency;

ALTER VIEW customer_balances OWNER TO postgres;

COMMENT ON VIEW customer_balances IS 'عرض أرصدة العملاء العاديين فقط - يخصم العمولة من كل حركة';
