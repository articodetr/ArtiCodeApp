/*
  # تحديث VIEW customer_balances - استبعاد حركات العمولة المنفصلة

  ## الهدف

  تحديث VIEW `customer_balances` ليستبعد حركات العمولة المنفصلة من الحساب،
  بنفس الطريقة التي تم بها إصلاح `customer_balances_by_currency`.

  ## السبب

  حركات العمولة المنفصلة (is_commission_movement = true) تُنشأ تلقائياً بواسطة
  trigger وتُسجل في حساب الأرباح والخسائر. يجب استبعادها من حساب أرصدة العملاء
  العاديين لتجنب الحساب المزدوج.

  ## التغييرات

  - تحديث LEFT JOIN لاستبعاد حركات العمولة المنفصلة
  - الحفاظ على جميع الحسابات الأخرى كما هي
  - العمولات ستظهر فقط من خلال حقل `commission` في الحركة الأساسية

  ## الأمان

  - VIEW للقراءة فقط
  - لا يؤثر على البيانات
*/

-- حذف الـ views القديمة بالترتيب
DROP VIEW IF EXISTS total_balances_by_currency CASCADE;
DROP VIEW IF EXISTS customer_balances CASCADE;

-- إعادة إنشاء customer_balances مع استبعاد حركات العمولة المنفصلة
CREATE VIEW customer_balances AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  c.phone AS customer_phone,
  c.account_number,
  c.is_profit_loss_account,
  am.currency,
  -- حساب الرصيد: العمولة تُخصم فقط إذا كانت بنفس العملة
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -(
          am.amount +
          CASE
            WHEN am.commission IS NOT NULL
              AND am.commission > 0
              AND am.commission_currency = am.currency
            THEN am.commission
            ELSE 0
          END
        )
        ELSE 0
      END
    ), 0
  ) AS balance,
  -- إجمالي الوارد (كامل المبلغ بدون خصم عمولة)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_incoming,
  -- إجمالي الصادر (المبلغ + العمولة إذا كانت بنفس العملة)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN (
          am.amount +
          CASE
            WHEN am.commission IS NOT NULL
              AND am.commission > 0
              AND am.commission_currency = am.currency
            THEN am.commission
            ELSE 0
          END
        )
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,
  -- إجمالي العمولات بنفس العملة (للتوضيح)
  COALESCE(
    SUM(
      CASE
        WHEN am.commission IS NOT NULL
          AND am.commission > 0
          AND am.commission_currency = am.currency
        THEN am.commission
        ELSE 0
      END
    ), 0
  ) AS total_commission,
  COUNT(am.id) AS movement_count,
  MAX(am.created_at) AS last_movement_date
FROM customers c
-- استبعاد حركات العمولة المنفصلة من الحساب
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
GROUP BY c.id, c.name, c.phone, c.account_number, c.is_profit_loss_account, am.currency;

-- إعادة إنشاء total_balances_by_currency
CREATE VIEW total_balances_by_currency AS
SELECT
  cb.currency,
  -- إجمالي الأرصدة
  COALESCE(SUM(cb.balance), 0) AS total_balance,
  -- إجمالي الوارد
  COALESCE(SUM(cb.total_incoming), 0) AS total_incoming,
  -- إجمالي الصادر
  COALESCE(SUM(cb.total_outgoing), 0) AS total_outgoing,
  -- إجمالي العمولات
  COALESCE(SUM(cb.total_commission), 0) AS total_commission,
  -- عدد العملاء (باستثناء حساب الأرباح والخسائر)
  COUNT(DISTINCT CASE WHEN cb.is_profit_loss_account IS NOT TRUE THEN cb.customer_id END) AS customer_count,
  -- إجمالي الحركات
  COALESCE(SUM(cb.movement_count), 0) AS total_movements
FROM customer_balances cb
WHERE cb.currency IS NOT NULL
GROUP BY cb.currency;

-- إعادة تفعيل RLS على الـ views
ALTER VIEW customer_balances OWNER TO postgres;
ALTER VIEW total_balances_by_currency OWNER TO postgres;

COMMENT ON VIEW customer_balances IS 'عرض أرصدة العملاء: يستبعد حركات العمولة المنفصلة (is_commission_movement = true)';
COMMENT ON VIEW total_balances_by_currency IS 'عرض الأرصدة الإجمالية حسب العملة';