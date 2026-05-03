/*
  # إعادة الحركات الموجودة للاتجاه الصحيح
  
  ## التصحيح
  
  إعادة ما تم عكسه سابقًا:
  - المحول: من incoming إلى outgoing
  - المستلم: من outgoing إلى incoming
*/

-- تحديث حركات المُحوِّل (من incoming إلى outgoing)
UPDATE account_movements
SET movement_type = 'outgoing'
WHERE transfer_direction = 'customer_to_customer'
  AND customer_id = from_customer_id
  AND movement_type = 'incoming'
  AND (is_commission_movement IS NULL OR is_commission_movement = false);

-- تحديث حركات المستلم (من outgoing إلى incoming)
UPDATE account_movements
SET movement_type = 'incoming'
WHERE transfer_direction = 'customer_to_customer'
  AND customer_id = to_customer_id
  AND movement_type = 'outgoing'
  AND (is_commission_movement IS NULL OR is_commission_movement = false);

COMMENT ON TABLE account_movements IS 'جدول حركات الحسابات - المنطق الصحيح: المحول=outgoing (مدين)، المستلم=incoming (دائن)';
