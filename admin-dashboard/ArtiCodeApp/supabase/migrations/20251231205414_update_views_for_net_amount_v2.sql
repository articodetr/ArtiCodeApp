/*
  # تحديث views لحساب الصافي بعد خصم العمولة (v2)

  ## التغييرات
  
  ### 1. حذف وإعادة إنشاء customer_balances view
    - حساب الرصيد بالصافي (بعد خصم العمولة)
    - للحركات الواردة (incoming): يُضاف (amount - commission)
    - للحركات الصادرة (outgoing): يُخصم amount (كامل)
    - إضافة حقل is_profit_loss_account لتمييز حساب الأرباح والخسائر
  
  ### 2. تحديث total_balances_by_currency view
    - حساب الأرصدة الإجمالية بالصافي
    - يشمل جميع الحسابات بما فيها الأرباح والخسائر
*/

-- حذف الـ views القديمة
DROP VIEW IF EXISTS total_balances_by_currency CASCADE;
DROP VIEW IF EXISTS customer_balances CASCADE;

-- إعادة إنشاء customer_balances مع الحسابات الصحيحة
CREATE VIEW customer_balances AS
SELECT 
  c.id AS customer_id,
  c.name AS customer_name,
  c.phone AS customer_phone,
  c.account_number,
  c.is_profit_loss_account,
  am.currency,
  -- حساب الرصيد الصافي (بعد خصم العمولة من المستفيد)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN (am.amount - COALESCE(am.commission, 0))
        WHEN am.movement_type = 'outgoing' THEN -(am.amount)
        ELSE 0
      END
    ), 0
  ) AS balance,
  -- إجمالي الوارد (الصافي بعد العمولة)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN (am.amount - COALESCE(am.commission, 0))
        ELSE 0
      END
    ), 0
  ) AS total_incoming,
  -- إجمالي الصادر (كامل المبلغ)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,
  -- إجمالي العمولات (للتوضيح)
  COALESCE(
    SUM(
      CASE
        WHEN am.commission IS NOT NULL AND am.commission > 0 THEN am.commission
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
  -- إجمالي الأرصدة (الصافي)
  COALESCE(SUM(cb.balance), 0) AS total_balance,
  -- إجمالي الوارد (الصافي)
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

COMMENT ON VIEW customer_balances IS 'عرض أرصدة العملاء بالصافي (بعد خصم العمولة من المستفيد فقط)';
COMMENT ON VIEW total_balances_by_currency IS 'عرض الأرصدة الإجمالية حسب العملة (بالصافي)';
