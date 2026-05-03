/*
  # إظهار أرصدة حساب الأرباح والخسائر حتى لو كانت صفر
  
  ## المشكلة
  
  الـ view الحالي `customer_balances_by_currency` يستبعد الأرصدة التي تساوي صفر باستخدام:
  `HAVING balance <> 0`
  
  هذا يعني أن حساب الأرباح والخسائر لا يظهر له أرصدة إذا كان رصيده صفر، مما يسبب ظهور كلمة "متساوي" بدلاً من الرصيد.
  
  ## الحل
  
  تعديل شرط HAVING ليستثني حساب الأرباح والخسائر، بحيث:
  - العملاء العاديين: يتم استبعاد الأرصدة الصفرية
  - حساب الأرباح والخسائر: يتم عرض جميع الأرصدة حتى لو كانت صفر
  
  ## النتيجة المتوقعة
  
  - حساب الأرباح والخسائر سيظهر أرصدته دائماً في صفحة العملاء
  - العملاء العاديين الذين رصيدهم صفر سيظهرون بكلمة "متساوي"
  - تجربة مستخدم أفضل لمتابعة حساب الأرباح والخسائر
*/

-- حذف VIEW القديم
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

-- إنشاء VIEW جديد مع استثناء حساب الأرباح والخسائر من شرط balance <> 0
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
-- عرض الأرصدة غير الصفرية، أو أي رصيد لحساب الأرباح والخسائر
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
  OR c.is_profit_loss_account = true
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
COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يعرض أرصدة حساب الأرباح والخسائر حتى لو كانت صفر';
