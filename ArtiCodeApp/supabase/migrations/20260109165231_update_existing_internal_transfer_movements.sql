/*
  # تحديث الحركات الموجودة بالفعل لعكس اتجاهها
  
  ## المشكلة
  
  الـ migration السابق يطبق فقط على الحركات الجديدة.
  البيانات الموجودة بالفعل لا تزال بالاتجاه القديم الخاطئ.
  
  ## الحل
  
  تحديث جميع الحركات الموجودة من نوع customer_to_customer:
  - عكس movement_type من outgoing إلى incoming (للمحول)
  - عكس movement_type من incoming إلى outgoing (للمستلم)
*/

-- تحديث حركات المُحوِّل (من outgoing إلى incoming)
UPDATE account_movements
SET movement_type = 'incoming'
WHERE transfer_direction = 'customer_to_customer'
  AND customer_id = from_customer_id
  AND movement_type = 'outgoing'
  AND (is_commission_movement IS NULL OR is_commission_movement = false);

-- تحديث حركات المستلم (من incoming إلى outgoing)
UPDATE account_movements
SET movement_type = 'outgoing'
WHERE transfer_direction = 'customer_to_customer'
  AND customer_id = to_customer_id
  AND movement_type = 'incoming'
  AND (is_commission_movement IS NULL OR is_commission_movement = false);

-- إضافة تعليق
COMMENT ON TABLE account_movements IS 'جدول حركات الحسابات - تم عكس اتجاه التحويلات الداخلية: المحول=incoming، المستلم=outgoing';
