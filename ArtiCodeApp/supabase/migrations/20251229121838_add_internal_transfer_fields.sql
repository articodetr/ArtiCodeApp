/*
  # إضافة حقول التحويل الداخلي بين العملاء

  ## التغييرات

  ### 1. إضافة حقول جديدة إلى جدول account_movements
  - `transfer_group_id` (uuid): معرف مجموعة التحويل لربط الحركتين
  - `is_internal_transfer` (boolean): علامة تحدد أن الحركة تحويل داخلي بين عملاء

  ### 2. تحديث view customer_balances
  - إعادة إنشاء الـ view لتطبيق منطق خيار B بشكل صحيح
  - outgoing = العميل دفع للمحل (ينقص الرصيد/الدين)
  - incoming = المحل دفع للعميل (يزيد الرصيد/الدين)
  - الرصيد الموجب = لنا عندك (مديونية على العميل)
  - الرصيد السالب = لك عندنا (دائنية للعميل)

  ## الملاحظات
  - الحقول الجديدة nullable بشكل افتراضي
  - لا تؤثر على البيانات الموجودة
  - التحويلات الداخلية تؤثر فقط على أرصدة العملاء، لا على إحصاءات المحل
*/

-- إضافة حقول التحويل الداخلي
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'transfer_group_id'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN transfer_group_id uuid;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'is_internal_transfer'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN is_internal_transfer boolean DEFAULT false;
  END IF;
END $$;

-- إضافة index على transfer_group_id لتحسين الأداء
CREATE INDEX IF NOT EXISTS idx_account_movements_transfer_group_id 
ON account_movements(transfer_group_id) 
WHERE transfer_group_id IS NOT NULL;

-- إعادة إنشاء view customer_balances مع المنطق الصحيح
-- منطق خيار B: outgoing يقلل الدين، incoming يزيد الدين
-- الرصيد الموجب = لنا عندك، الرصيد السالب = لك عندنا
DROP VIEW IF EXISTS customer_balances CASCADE;

CREATE VIEW customer_balances AS
SELECT 
  c.id AS customer_id,
  c.name AS customer_name,
  c.phone AS customer_phone,
  c.account_number,
  am.currency,
  COALESCE(
    SUM(
      CASE 
        -- incoming = المحل دفع للعميل (يزيد دين العميل على المحل)
        WHEN am.movement_type = 'incoming' THEN am.amount
        -- outgoing = العميل دفع للمحل (ينقص دين العميل)
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ), 0
  ) AS balance,
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_incoming,
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ), 0
  ) AS total_outgoing,
  COALESCE(
    SUM(
      CASE 
        WHEN am.commission IS NOT NULL AND am.commission > 0 
        THEN am.commission
        ELSE 0
      END
    ), 0
  ) AS total_commission,
  COUNT(am.id) AS movement_count,
  MAX(am.created_at) AS last_movement_date
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.account_number, am.currency;

-- إعادة إنشاء view total_balances_by_currency
DROP VIEW IF EXISTS total_balances_by_currency CASCADE;

CREATE VIEW total_balances_by_currency AS
SELECT 
  currency,
  SUM(balance) AS total_balance,
  SUM(total_incoming) AS total_incoming,
  SUM(total_outgoing) AS total_outgoing,
  SUM(total_commission) AS total_commission,
  COUNT(DISTINCT customer_id) AS customer_count
FROM customer_balances
GROUP BY currency;
