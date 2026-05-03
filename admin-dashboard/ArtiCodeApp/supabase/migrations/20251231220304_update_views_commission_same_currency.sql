/*
  # تحديث views لخصم العمولة فقط عندما تكون بنفس عملة الحوالة

  ## التغييرات

  ### 1. تحديث customer_balances view
    - خصم العمولة من حساب العميل فقط إذا كانت بنفس عملة الحوالة
    - العمولات بعملة مختلفة لا تؤثر على حساب العميل (تُسجَّل مباشرة في الأرباح والخسائر)

  ### 2. المنطق الجديد
    - للحركات الواردة (incoming): يُضاف amount (كامل المبلغ)
    - للحركات الصادرة (outgoing): يُخصم (amount + commission) فقط إذا كانت commission_currency = currency
    - إذا كانت العمولة بعملة مختلفة، تُسجَّل تلقائياً في حساب الأرباح والخسائر عبر الـ trigger
*/

-- حذف الـ views القديمة
DROP VIEW IF EXISTS total_balances_by_currency CASCADE;
DROP VIEW IF EXISTS customer_balances CASCADE;

-- إعادة إنشاء customer_balances مع المنطق الصحيح
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
LEFT JOIN account_movements am ON c.id = am.customer_id
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

COMMENT ON VIEW customer_balances IS 'عرض أرصدة العملاء: العمولة تُخصم فقط إذا كانت بنفس عملة الحوالة';
COMMENT ON VIEW total_balances_by_currency IS 'عرض الأرصدة الإجمالية حسب العملة';
