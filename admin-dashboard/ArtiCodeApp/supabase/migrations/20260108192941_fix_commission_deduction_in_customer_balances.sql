/*
  # إصلاح خصم العمولة من رصيد العملاء

  ## المشكلة الحالية

  عند حساب أرصدة العملاء، يتم احتساب المبلغ الكامل (amount) بدون خصم العمولة (commission).

  ### مثال على المشكلة:

  **السيناريو:** استلام 5000 USD من جلال بعمولة 120 USD

  **ما يحدث حالياً:**
  - يتم إنشاء حركة outgoing بمبلغ 5000 USD للعميل جلال
  - يتم إنشاء حركة incoming منفصلة بمبلغ 120 USD لحساب الأرباح والخسائر (is_commission_movement = true)
  - رصيد جلال يُحسب كـ: -5000 USD (خطأ!)

  **ما يجب أن يحدث:**
  - رصيد جلال يجب أن يكون: -(5000 - 120) = -4880 USD
  - العمولة 120 USD تذهب لحساب الأرباح والخسائر

  ## الحل

  تعديل الـ VIEWs لحساب الرصيد الصافي بخصم العمولة من المبلغ:

  ### معادلة الرصيد الجديدة:

  ```
  للحركات incoming (تسليم للعميل):
    balance += (amount - COALESCE(commission, 0))

  للحركات outgoing (استلام من العميل):
    balance -= (amount - COALESCE(commission, 0))
  ```

  ### استبعاد حركات العمولة المنفصلة:

  - حركات العمولة المنفصلة (is_commission_movement = true) يجب استبعادها من حساب رصيد العملاء
  - لأن العمولة تم خصمها بالفعل من الحركة الأصلية
  - حركات العمولة المنفصلة تُحسب فقط في رصيد حساب الأرباح والخسائر

  ## أمثلة على النتائج المتوقعة

  ### مثال 1: استلام من عميل
  - جلال: استلام 5000 USD بعمولة 120 USD
  - النتيجة:
    - رصيد جلال = -4880 USD (له عندنا)
    - رصيد الأرباح والخسائر = +120 USD

  ### مثال 2: تسليم لعميل
  - عماد: تسليم 3000 USD بعمولة 50 USD
  - النتيجة:
    - رصيد عماد = +2950 USD (لنا عنده)
    - رصيد الأرباح والخسائر = +50 USD

  ### مثال 3: تحويل داخلي
  - جلال → عماد: 1000 USD بعمولة 30 USD (جلال يدفع العمولة)
  - النتيجة:
    - رصيد جلال = -970 USD (المبلغ المحول - العمولة)
    - رصيد عماد = +1000 USD (المبلغ المستلم كاملاً)
    - رصيد الأرباح والخسائر = +30 USD

  ## الفوائد

  1. رصيد العميل يعكس المبلغ الصافي الحقيقي
  2. العمولات مفصولة بوضوح في حساب الأرباح والخسائر
  3. لا حاجة لتعديل واجهة المستخدم أو منطق الإدراج
  4. توافق كامل مع جميع أنواع الحركات
  5. سهولة إعداد التقارير المالية

  ## الأمان

  - هذا التعديل على مستوى VIEWs فقط (للقراءة)
  - لا يؤثر على البيانات المخزنة
  - لا يؤثر على Triggers أو Functions
  - يؤثر فقط على طريقة حساب وعرض الأرصدة
*/

-- ==========================================
-- الجزء 1: تحديث customer_balances_by_currency
-- ==========================================

-- حذف VIEW القديم
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

-- إنشاء VIEW جديد مع خصم العمولة من الرصيد
CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  am.currency,

  -- إجمالي الوارد (تسليم للعميل - يزيد الرصيد)
  -- يتم طرح العمولة من كل حركة incoming
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
        THEN (am.amount - COALESCE(am.commission, 0))
        ELSE 0
      END
    ), 0
  ) AS total_incoming,

  -- إجمالي الصادر (استلام من العميل - يخفض الرصيد)
  -- يتم طرح العمولة من كل حركة outgoing
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing'
        THEN (am.amount - COALESCE(am.commission, 0))
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,

  -- الرصيد الصافي = (الوارد - العمولة) - (الصادر - العمولة)
  -- رصيد موجب = "لنا عنده"، رصيد سالب = "له عندنا"
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
  ) AS balance

FROM customers c

-- استبعاد حركات العمولة المنفصلة من حساب رصيد العملاء
-- لأن العمولة تم خصمها بالفعل من الحركة الأصلية
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)

WHERE am.currency IS NOT NULL

GROUP BY c.id, c.name, am.currency

-- عرض الأرصدة غير الصفرية، أو أي رصيد لحساب الأرباح والخسائر
HAVING
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
  ) <> 0
  OR c.phone = 'PROFIT_LOSS_ACCOUNT'

ORDER BY
  c.name,
  ABS(COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
        THEN (am.amount - COALESCE(am.commission, 0))
        WHEN am.movement_type = 'outgoing'
        THEN -(am.amount - COALESCE(am.commission, 0))
        ELSE 0
      END
    ), 0
  )) DESC;

-- تعيين المالك
ALTER VIEW customer_balances_by_currency OWNER TO postgres;

-- إضافة تعليق توضيحي
COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يخصم العمولة من كل حركة - balance = (incoming - commission) - (outgoing - commission)';

-- ==========================================
-- الجزء 2: تحديث customer_balances
-- ==========================================

-- حذف VIEW القديم
DROP VIEW IF EXISTS customer_balances CASCADE;

-- إنشاء VIEW جديد مع نفس المنطق
CREATE OR REPLACE VIEW customer_balances AS
SELECT
  c.id,
  c.name,
  c.phone,

  -- إجمالي الوارد (بعد خصم العمولة)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
        THEN (am.amount - COALESCE(am.commission, 0))
        ELSE 0
      END
    ), 0
  ) as total_incoming,

  -- إجمالي الصادر (بعد خصم العمولة)
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

-- استبعاد حركات العمولة المنفصلة
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)

WHERE
  c.phone != 'PROFIT_LOSS_ACCOUNT'
  OR c.phone IS NULL

GROUP BY c.id, c.name, c.phone, am.currency;

-- تعيين المالك
ALTER VIEW customer_balances OWNER TO postgres;

-- إضافة تعليق توضيحي
COMMENT ON VIEW customer_balances IS 'عرض أرصدة العملاء - يخصم العمولة من كل حركة - يستبعد حركات العمولة المنفصلة';

-- ==========================================
-- الجزء 3: إعادة إنشاء customers_with_last_activity
-- ==========================================

-- هذا VIEW يعتمد على customer_balances_by_currency، لذا يجب إعادة إنشائه

DROP VIEW IF EXISTS customers_with_last_activity CASCADE;

CREATE OR REPLACE VIEW customers_with_last_activity AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.notes,
  c.created_at,
  MAX(am.created_at) as last_activity
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
WHERE c.phone != 'PROFIT_LOSS_ACCOUNT' OR c.phone IS NULL
GROUP BY c.id, c.name, c.phone, c.notes, c.created_at
ORDER BY last_activity DESC NULLS LAST, c.created_at DESC;

-- تعيين المالك
ALTER VIEW customers_with_last_activity OWNER TO postgres;

-- إضافة تعليق توضيحي
COMMENT ON VIEW customers_with_last_activity IS 'عرض العملاء مع آخر نشاط - يستثني حساب الأرباح والخسائر';
