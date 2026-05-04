/*
  # تهيئة أزواج الحسابات الموجودة

  ## الوصف
  إنشاء pairs للحسابات المرتبطة الموجودة حالياً في النظام
  وتحديد last_receipt_number بناءً على الحركات الموجودة
*/

-- إنشاء pairs للحسابات المرتبطة الموجودة
INSERT INTO linked_account_pairs (
  user_id_1,
  user_id_2,
  customer_id_1,
  customer_id_2,
  last_receipt_number
)
SELECT DISTINCT
  LEAST(c1.user_id, c2.user_id) as user_id_1,
  GREATEST(c1.user_id, c2.user_id) as user_id_2,
  CASE 
    WHEN c1.user_id < c2.user_id THEN c1.id 
    ELSE c2.id 
  END as customer_id_1,
  CASE 
    WHEN c1.user_id < c2.user_id THEN c2.id 
    ELSE c1.id 
  END as customer_id_2,
  -- حساب أعلى رقم سند موجود بين الحسابين
  COALESCE((
    SELECT MAX(CAST(receipt_number AS integer))
    FROM account_movements
    WHERE (customer_id = c1.id OR customer_id = c2.id)
      AND receipt_number IS NOT NULL
      AND receipt_number ~ '^\d+$'
  ), 0) as last_receipt_number
FROM customers c1
INNER JOIN customers c2 
  ON c1.linked_user_id = c2.user_id 
  AND c2.linked_user_id = c1.user_id
WHERE c1.linked_user_id IS NOT NULL
  AND c1.user_id < c2.user_id  -- لتجنب التكرار
ON CONFLICT (user_id_1, user_id_2) DO UPDATE
SET 
  last_receipt_number = EXCLUDED.last_receipt_number,
  updated_at = now();

-- عرض الـ pairs المنشأة
SELECT 
  lap.id,
  u1.user_name as user_1,
  u2.user_name as user_2,
  lap.last_receipt_number,
  lap.created_at
FROM linked_account_pairs lap
JOIN app_security u1 ON lap.user_id_1 = u1.id
JOIN app_security u2 ON lap.user_id_2 = u2.id
ORDER BY lap.created_at DESC;
