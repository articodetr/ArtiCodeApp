/*
  # إصلاح VIEW customer_balances_by_currency - استبعاد حركات العمولة المنفصلة

  ## المشكلة

  VIEW الحالي `customer_balances_by_currency` يحسب العمولات بشكل مستقل باستخدام UNION ALL،
  مما يؤدي إلى حساب العمولات مرتين ويسبب اختلاف الأرصدة بين:
  - صفحة العملاء (تستخدم هذا الـ VIEW)
  - صفحة تفاصيل العميل (تحسب يدوياً)

  **مثال:** جلال يظهر برصيد -5120$ في صفحة العملاء و -5000$ في التفاصيل
  (الفرق = 120$ عمولة محسوبة مرتين)

  ## الحل

  1. حذف VIEW القديم نهائياً
  2. إنشاء VIEW جديد بمنطق صحيح:
     - استبعاد جميع الحركات التي `is_commission_movement = true`
     - هذه الحركات تُنشأ تلقائياً بواسطة trigger وتظهر في حساب الأرباح والخسائر فقط
     - الحركة الأساسية تحتوي على حقل `commission` للعرض فقط
     - الرصيد يُحسب من `amount` فقط بدون محاولة إعادة حساب العمولات

  ## النتائج المتوقعة

  - الأرصدة متطابقة في صفحة العملاء وصفحة التفاصيل
  - العمولات ظاهرة في الحركة الأساسية (حقل commission)
  - حركات العمولة تظهر فقط في حساب الأرباح والخسائر
  - لا تكرار في الحسابات

  ## الأمان

  - VIEW للقراءة فقط
  - لا يؤثر على البيانات الحالية
  - يؤثر فقط على كيفية عرض الأرصدة
*/

-- حذف VIEW القديم
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

-- إنشاء VIEW جديد مع استبعاد حركات العمولة المنفصلة
CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,
  -- إجمالي الوارد (الحركات الواردة فقط، بدون حركات العمولة المنفصلة)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_incoming,
  -- إجمالي الصادر (الحركات الصادرة فقط، بدون حركات العمولة المنفصلة)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,
  -- الرصيد = الصادر - الوارد
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
-- استبعاد حركات العمولة المنفصلة من الحساب
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, am.currency
HAVING COALESCE(
  SUM(
    CASE
      WHEN am.movement_type = 'outgoing' THEN am.amount
      WHEN am.movement_type = 'incoming' THEN -am.amount
      ELSE 0
    END
  ), 0
) <> 0
ORDER BY c.name, ABS(COALESCE(
  SUM(
    CASE
      WHEN am.movement_type = 'outgoing' THEN am.amount
      WHEN am.movement_type = 'incoming' THEN -am.amount
      ELSE 0
    END
  ), 0
)) DESC;

-- تعيين المالك
ALTER VIEW customer_balances_by_currency OWNER TO postgres;

-- إضافة تعليق توضيحي
COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يستبعد حركات العمولة المنفصلة (is_commission_movement = true) لتجنب الحساب المزدوج';