/*
  # إضافة VIEW للمطابقة المحاسبية (Accounting Balance Check)

  ## الهدف
  توفير آلية فحص تلقائي للتأكد من توازن القيود المحاسبية في النظام

  ## المبدأ المحاسبي
  في أي نظام محاسبي صحيح، يجب أن يكون:
  **مجموع المدين (Debits) = مجموع الدائن (Credits)**

  ## التطبيق في نظامنا

  ### مثال: تحويل 6000$ من جلال إلى عماد مع عمولة 150$

  **القيود:**
  1. جلال (outgoing): -6000$ ← مدين
  2. عماد (incoming): +5850$ ← دائن
  3. الأرباح والخسائر (incoming): +150$ ← دائن

  **المطابقة:**
  - المدين: 6000$
  - الدائن: 5850$ + 150$ = 6000$
  - النتيجة: متوازن ✓

  ## VIEW Structure

  - `currency`: العملة
  - `total_debits`: إجمالي المدين (outgoing)
  - `total_credits`: إجمالي الدائن (incoming)
  - `net_balance`: الفرق (يجب أن يكون 0)
  - `is_balanced`: حالة التوازن (true/false)
  - `absolute_difference`: القيمة المطلقة للفرق

  ## الملاحظات
  - يستبعد حركات العمولة المنفصلة (is_commission_movement = true)
  - يشمل جميع العملاء بما فيهم حساب الأرباح والخسائر
  - يعمل على المبالغ الصافية (net amounts)
*/

-- إنشاء VIEW للمطابقة المحاسبية
CREATE OR REPLACE VIEW accounting_balance_check AS
SELECT
  am.currency,
  -- إجمالي المدين (Debits): الحركات الصادرة
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_debits,
  -- إجمالي الدائن (Credits): الحركات الواردة
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_credits,
  -- الفرق (يجب أن يكون 0 في نظام متوازن)
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ), 0
  ) - COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS net_balance,
  -- حالة التوازن (true إذا كان الفرق = 0)
  (
    COALESCE(
      SUM(
        CASE
          WHEN am.movement_type = 'outgoing' THEN am.amount
          ELSE 0
        END
      ), 0
    ) - COALESCE(
      SUM(
        CASE
          WHEN am.movement_type = 'incoming' THEN am.amount
          ELSE 0
        END
      ), 0
    )
  ) = 0 AS is_balanced,
  -- القيمة المطلقة للفرق (للعرض)
  ABS(
    COALESCE(
      SUM(
        CASE
          WHEN am.movement_type = 'outgoing' THEN am.amount
          ELSE 0
        END
      ), 0
    ) - COALESCE(
      SUM(
        CASE
          WHEN am.movement_type = 'incoming' THEN am.amount
          ELSE 0
        END
      ), 0
    )
  ) AS absolute_difference,
  -- عدد الحركات المدينة
  COUNT(
    CASE
      WHEN am.movement_type = 'outgoing' THEN 1
    END
  ) AS debit_count,
  -- عدد الحركات الدائنة
  COUNT(
    CASE
      WHEN am.movement_type = 'incoming' THEN 1
    END
  ) AS credit_count
FROM account_movements am
WHERE
  -- استبعاد حركات العمولة المنفصلة
  (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
  AND am.currency IS NOT NULL
GROUP BY am.currency
ORDER BY am.currency;

-- تعيين المالك
ALTER VIEW accounting_balance_check OWNER TO postgres;

-- إضافة تعليق توضيحي
COMMENT ON VIEW accounting_balance_check IS 'فحص المطابقة المحاسبية: التحقق من توازن القيود المدينة والدائنة لكل عملة';

-- إنشاء دالة مساعدة للحصول على ملخص المطابقة
CREATE OR REPLACE FUNCTION get_accounting_balance_summary()
RETURNS TABLE(
  total_currencies integer,
  balanced_currencies integer,
  unbalanced_currencies integer,
  overall_status text
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(*)::integer AS total_currencies,
    SUM(CASE WHEN is_balanced THEN 1 ELSE 0 END)::integer AS balanced_currencies,
    SUM(CASE WHEN NOT is_balanced THEN 1 ELSE 0 END)::integer AS unbalanced_currencies,
    CASE
      WHEN SUM(CASE WHEN NOT is_balanced THEN 1 ELSE 0 END) = 0 THEN 'متوازن ✓'
      ELSE 'غير متوازن ⚠'
    END AS overall_status
  FROM accounting_balance_check;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_accounting_balance_summary() IS 'ملخص سريع لحالة المطابقة المحاسبية في جميع العملات';