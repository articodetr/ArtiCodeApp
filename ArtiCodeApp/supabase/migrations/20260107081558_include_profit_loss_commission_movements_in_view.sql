/*
  # تضمين حركات العمولة لحساب الأرباح والخسائر في الـ view
  
  ## المشكلة
  
  الـ view الحالي يستبعد حركات العمولة المنفصلة باستخدام:
  `AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)`
  
  المشكلة أن **كل** حركات حساب الأرباح والخسائر هي حركات عمولة، لأن العمولات يتم تسجيلها تلقائياً في حسابه.
  
  هذا يعني أن حساب الأرباح والخسائر لا يظهر له أي أرصدة في الـ view، رغم أن له حركات فعلية.
  
  ## الحل
  
  تعديل الـ view ليشمل حركات حساب الأرباح والخسائر **حتى لو كانت حركات عمولة**، مع الاستمرار في استبعاد حركات العمولة المنفصلة للعملاء العاديين.
  
  الشرط الجديد:
  - العملاء العاديين: استبعاد حركات العمولة المنفصلة
  - حساب الأرباح والخسائر: تضمين كل الحركات (بما فيها حركات العمولة)
  
  ## النتيجة المتوقعة
  
  - حساب الأرباح والخسائر سيظهر أرصدته الفعلية في صفحة العملاء
  - المستخدم سيتمكن من رؤية إجمالي العمولات المتراكمة
  - العملاء العاديون سيستمرون في عدم عرض حركات العمولة المنفصلة
*/

-- حذف VIEW القديم
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

-- إنشاء VIEW جديد مع تضمين حركات العمولة لحساب الأرباح والخسائر
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
-- JOIN مع الحركات، مع معالجة خاصة لحساب الأرباح والخسائر
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  -- شرط مركب: استبعاد حركات العمولة للعملاء العاديين فقط
  -- حساب الأرباح والخسائر يتضمن كل الحركات
  AND (
    c.is_profit_loss_account = true
    OR am.is_commission_movement IS NULL 
    OR am.is_commission_movement = false
  )
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
COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يشمل جميع حركات حساب الأرباح والخسائر بما فيها العمولات';
