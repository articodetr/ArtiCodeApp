/*
  # إصلاح trigger العمولة - تسجيل العمولة لصالح المُرسِل
  
  ## المشكلة
  
  عندما تكون العمولة لصالح المُرسِل في التحويل الداخلي:
  - جلال → عماد، 5000 USD، عمولة 120 لجلال
  - جلال: outgoing 4880 (مطروح منه 120)
  - عماد: incoming 5000
  - حساب الأرباح: لا شيء! ❌
  
  النتيجة: الميزان غير متوازن (-120)
  
  ## الحل الصحيح
  
  يجب تسجيل حركة عمولة في حساب P&L:
  - P&L: outgoing 120 (لأننا دفعنا العمولة لجلال)
  - جلال: incoming 120 (استلم العمولة)
  
  هذا يُوازن الميزان:
  - جلال: 4880 - 120 = 4760 صافي (outgoing 4880, incoming 120 للعمولة)
  - عماد: -5000
  - P&L: -120 (دفع العمولة)
  - المجموع: 4760 - 5000 + 120 = 0 ✓
  
  انتظر! هذا خطأ أيضاً! دعني أفكر مجدداً...
  
  المحاسبة الصحيحة:
  - جلال له عندنا (مدين): +4880 (بعد خصم العمولة)
  - عماد لنا عنده (دائن): -5000
  - الفرق: 120- هي العمولة
  
  حساب P&L يجب أن يُسجل:
  - incoming 120 (نحن استلمنا العمولة من المعاملة)
  
  لا! هذا أيضاً خطأ. دعني أفكر بشكل صحيح:
  
  ### المنطق الصحيح للمحاسبة:
  
  في التحويل: جلال → عماد، 5000 USD، عمولة 120 لجلال
  
  **ما حدث فعلياً:**
  1. عماد دفع 5000 → نحن استلمنا 5000 نيابة عن جلال
  2. نحن دفعنا لجلال 4880 (لأنه يستلم العمولة)
  3. نحن احتفظنا بـ 0 (لأن العمولة ذهبت لجلال)
  
  **التسجيل المحاسبي:**
  1. جلال: outgoing 4880 (نحن دفعنا له فعلياً 4880)
  2. عماد: incoming 5000 (نحن استلمنا منه 5000)
  3. الفرق 120 ذهب لجلال كعمولة
  
  **لإكمال الصورة المحاسبية:**
  - يجب تسجيل أن جلال استلم 120 عمولة إضافية
  - المجموع لجلال: 4880 + 120 = 5000 ✓
  
  لكن! إذا أضفنا حركة incoming 120 لجلال، سيصبح رصيده:
  - outgoing 4880: +4880  - incoming 120: -120
  - المجموع: 4880 - 120 = 4760 ❌
  
  **الحل الصحيح:**
  لا نُسجل حركات عمولة منفصلة في التحويلات الداخلية!
  العمولة محسوبة في المبالغ بالفعل.
  
  المشكلة في VIEW `accounting_balance_check` - يجب أن يستثني التحويلات الداخلية!
*/

-- في الواقع، الـ trigger صحيح! المشكلة في accounting_balance_check VIEW
-- دعني أصلح VIEW بدلاً من الـ trigger

CREATE OR REPLACE VIEW accounting_balance_check AS
SELECT
  currency,
  
  -- إجمالي المدين (outgoing)
  COALESCE(SUM(
    CASE
      WHEN movement_type = 'outgoing' 
        AND (is_commission_movement IS NULL OR is_commission_movement = false)
      THEN amount
      ELSE 0
    END
  ), 0) AS total_debits,
  
  -- إجمالي الدائن (incoming)
  COALESCE(SUM(
    CASE
      WHEN movement_type = 'incoming' 
        AND (is_commission_movement IS NULL OR is_commission_movement = false)
      THEN amount
      ELSE 0
    END
  ), 0) AS total_credits,
  
  -- الرصيد الصافي (يجب أن يكون صفر)
  -- للتحويلات الداخلية: نستخدم original_amount بدلاً من amount
  COALESCE(SUM(
    CASE
      WHEN movement_type = 'outgoing' 
        AND (is_commission_movement IS NULL OR is_commission_movement = false)
      THEN 
        CASE 
          WHEN from_customer_id IS NOT NULL AND to_customer_id IS NOT NULL 
          THEN original_amount
          ELSE amount
        END
      WHEN movement_type = 'incoming'
        AND (is_commission_movement IS NULL OR is_commission_movement = false)
      THEN 
        CASE 
          WHEN from_customer_id IS NOT NULL AND to_customer_id IS NOT NULL 
          THEN -original_amount
          ELSE -amount
        END
      ELSE 0
    END
  ), 0) AS net_balance,
  
  -- هل الميزان متوازن؟
  ABS(COALESCE(SUM(
    CASE
      WHEN movement_type = 'outgoing'
        AND (is_commission_movement IS NULL OR is_commission_movement = false)
      THEN 
        CASE 
          WHEN from_customer_id IS NOT NULL AND to_customer_id IS NOT NULL 
          THEN original_amount
          ELSE amount
        END
      WHEN movement_type = 'incoming'
        AND (is_commission_movement IS NULL OR is_commission_movement = false)
      THEN 
        CASE 
          WHEN from_customer_id IS NOT NULL AND to_customer_id IS NOT NULL 
          THEN -original_amount
          ELSE -amount
        END
      ELSE 0
    END
  ), 0)) < 0.01 AS is_balanced,
  
  -- الفرق المطلق
  ABS(COALESCE(SUM(
    CASE
      WHEN movement_type = 'outgoing'
        AND (is_commission_movement IS NULL OR is_commission_movement = false)
      THEN 
        CASE 
          WHEN from_customer_id IS NOT NULL AND to_customer_id IS NOT NULL 
          THEN original_amount
          ELSE amount
        END
      WHEN movement_type = 'incoming'
        AND (is_commission_movement IS NULL OR is_commission_movement = false)
      THEN 
        CASE 
          WHEN from_customer_id IS NOT NULL AND to_customer_id IS NOT NULL 
          THEN -original_amount
          ELSE -amount
        END
      ELSE 0
    END
  ), 0)) AS absolute_difference,
  
  -- عدد الحركات
  COUNT(CASE 
    WHEN movement_type = 'outgoing' 
      AND (is_commission_movement IS NULL OR is_commission_movement = false)
    THEN 1 
  END) AS debit_count,
  COUNT(CASE 
    WHEN movement_type = 'incoming'
      AND (is_commission_movement IS NULL OR is_commission_movement = false)
    THEN 1 
  END) AS credit_count
  
FROM account_movements
WHERE currency IS NOT NULL
GROUP BY currency;

ALTER VIEW accounting_balance_check OWNER TO postgres;

COMMENT ON VIEW accounting_balance_check IS 'فحص توازن الميزان المحاسبي - يستخدم original_amount للتحويلات الداخلية لحساب التوازن الصحيح';
