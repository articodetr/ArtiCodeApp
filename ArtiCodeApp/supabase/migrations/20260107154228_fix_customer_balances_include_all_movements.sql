/*
  # إصلاح حساب أرصدة العملاء لتشمل جميع الحركات بما فيها العمولات

  ## المشكلة
  
  الـ View `customer_balances_by_currency` يستبعد حركات العمولة المنفصلة بسبب الشرط:
  `AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)`
  
  هذا يسبب اختلاف في الأرصدة:
  - صفحة العملاء تظهر رصيد مختلف عن صفحة تفاصيل العميل
  - مثال: جلال يظهر -5000 في صفحة العملاء و -4880 في صفحة التفاصيل
  
  ## السبب
  
  عند تحويل داخلي بعمولة:
  1. حركة outgoing للمحول (مثلاً جلال -5000)
  2. حركة incoming للعمولة (مثلاً جلال +120) **محددة كـ is_commission_movement = true**
  3. حركة incoming للمستلم (عماد +4880)
  
  الـ View الحالي يستبعد الحركة رقم 2، لذلك:
  - صفحة العملاء: 0 - 5000 = -5000
  - صفحة التفاصيل: 120 - 5000 = -4880
  
  ## الحل
  
  إزالة الشرط الذي يستبعد حركات العمولة من الـ View، لجعل الحساب متسق في كل مكان.
  
  ## النتيجة المتوقعة
  
  - تطابق كامل بين الأرقام في صفحة العملاء وصفحة التفاصيل
  - جميع الحركات (بما فيها العمولات) تُحسب في الرصيد النهائي
  
  ## الأمان
  
  - VIEW للقراءة فقط
  - لا يؤثر على البيانات المخزنة
  - يؤثر فقط على طريقة حساب وعرض الأرصدة
*/

-- حذف VIEW القديم
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

-- إنشاء VIEW جديد يشمل جميع الحركات
CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,
  -- إجمالي الوارد (تسليم للعميل - يزيد الرصيد)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_incoming,
  -- إجمالي الصادر (استلام من العميل - يخفض الرصيد)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,
  -- الرصيد = الوارد - الصادر (incoming - outgoing)
  -- رصيد موجب = "لنا عنده"، رصيد سالب = "له عندنا"
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
-- تضمين جميع الحركات (بما فيها حركات العمولة)
LEFT JOIN account_movements am
  ON c.id = am.customer_id
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, am.currency
HAVING COALESCE(
  SUM(
    CASE
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ), 0
) <> 0
ORDER BY c.name, ABS(COALESCE(
  SUM(
    CASE
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ), 0
)) DESC;

-- تعيين المالك
ALTER VIEW customer_balances_by_currency OWNER TO postgres;

-- إضافة تعليق توضيحي
COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يشمل جميع الحركات بما فيها العمولات - balance = incoming - outgoing (موجب = لنا عنده، سالب = له عندنا)';