/*
  # إصلاح اتجاه حساب الرصيد في customer_balances_by_currency
  
  ## المشكلة
  
  الـ view الحالي يحسب الرصيد بطريقة معكوسة عن صفحة التفاصيل:
  - الـ view: balance = outgoing - incoming
  - صفحة التفاصيل: balance = incoming - outgoing
  
  هذا يسبب:
  - اختلاف في قيمة الرصيد (موجب في مكان وسالب في مكان آخر)
  - اختلاف في الألوان المعروضة
  - عدم توحيد تجربة المستخدم
  
  ## المفهوم الصحيح
  
  حسب التعليقات في migration السابق (20251228210519):
  - **رصيد موجب (+)**: "لنا عنده" = العميل مدين للمحل
  - **رصيد سالب (-)**: "له عندنا" = المحل مدين للعميل
  
  ### أنواع الحركات
  1. **تسليم للعميل** (incoming)
     - المحل يدفع للعميل
     - يزيد الرصيد (balance = balance + amount)
  
  2. **استلام من العميل** (outgoing)
     - العميل يدفع للمحل
     - يخفض الرصيد (balance = balance - amount)
  
  ## الحل
  
  تغيير صيغة حساب الرصيد في الـ view من:
  `balance = outgoing - incoming` (خاطئ)
  
  إلى:
  `balance = incoming - outgoing` (صحيح)
  
  ## النتائج المتوقعة
  
  - توحيد حساب الرصيد في كل مكان
  - الألوان الصحيحة: موجب = أخضر (لنا عنده)، سالب = أحمر (له عندنا)
  - تجربة مستخدم متسقة بين صفحة العملاء وصفحة التفاصيل
  
  ## الأمان
  
  - VIEW للقراءة فقط
  - لا يؤثر على البيانات المخزنة
  - يؤثر فقط على طريقة حساب وعرض الأرصدة
*/

-- حذف VIEW القديم
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

-- إنشاء VIEW جديد مع الحساب الصحيح
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
-- استبعاد حركات العمولة المنفصلة من الحساب
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
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
COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - balance = incoming - outgoing (موجب = لنا عنده، سالب = له عندنا)';
