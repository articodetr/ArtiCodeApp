/*
  # توحيد حساب الأرصدة - تضمين جميع الحركات
  
  ## المشكلة
  
  هناك تناقض بين الأرقام المعروضة في:
  1. قائمة العملاء: يستخدم View يستبعد حركات العمولة المنفصلة
  2. تفاصيل العميل: يحسب جميع الحركات بما فيها حركات العمولة
  
  هذا يؤدي إلى أرقام مختلفة ومربكة للمستخدم.
  
  ## الحل
  
  تحديث الـ View ليشمل **جميع الحركات** بما فيها حركات العمولة المنفصلة.
  هذا يضمن:
  - اتساق الأرقام بين قائمة العملاء وتفاصيل كل عميل
  - شفافية كاملة في عرض جميع الحركات
  - موثوقية الأرقام المعروضة
  
  ## التغييرات
  
  1. إزالة شرط استبعاد حركات العمولة المنفصلة (is_commission_movement)
  2. الـ View سيشمل الآن جميع الحركات لكل العملاء
  3. عرض الأرصدة غير الصفرية فقط
  
  ## النتيجة المتوقعة
  
  - الرقم في قائمة العملاء = الرقم في تفاصيل العميل
  - عرض شفاف لكل الحركات المالية
  - تجربة مستخدم متسقة وموثوقة
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
-- JOIN مع جميع الحركات بدون استبعاد أي حركة
LEFT JOIN account_movements am
  ON c.id = am.customer_id
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, am.currency
-- عرض الأرصدة غير الصفرية فقط
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

-- منح الصلاحيات
GRANT SELECT ON customer_balances_by_currency TO authenticated;
GRANT SELECT ON customer_balances_by_currency TO anon;

-- تحديث التعليق التوضيحي
COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يشمل جميع الحركات بما فيها حركات العمولة المنفصلة لضمان الاتساق مع تفاصيل العميل';