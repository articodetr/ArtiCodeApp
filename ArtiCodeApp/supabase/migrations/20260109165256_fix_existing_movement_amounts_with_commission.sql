/*
  # إصلاح المبالغ في الحركات الموجودة
  
  ## المشكلة
  
  بعض الحركات قد تحتوي على amount = original_amount بدون خصم العمولة
  
  ## الحل
  
  تحديث amount لتكون المبلغ الصافي بعد العمولة:
  - للمحول الذي يستلم العمولة: amount = original_amount - commission
  - للمستلم العادي: amount = original_amount
  - للمستلم الذي يستلم عمولة إضافية: amount = original_amount + commission
*/

-- تحديث حركات المُحوِّل عندما تذهب العمولة له
-- amount يجب أن يكون = original_amount - commission
UPDATE account_movements
SET amount = COALESCE(original_amount, amount) - COALESCE(commission, 0)
WHERE transfer_direction = 'customer_to_customer'
  AND customer_id = from_customer_id
  AND commission_recipient_id = from_customer_id
  AND commission IS NOT NULL
  AND commission > 0
  AND (is_commission_movement IS NULL OR is_commission_movement = false)
  AND amount != (COALESCE(original_amount, amount) - COALESCE(commission, 0));

-- تحديث حركات المستلم عندما تذهب العمولة له
-- amount يجب أن يكون = original_amount + commission
UPDATE account_movements
SET amount = COALESCE(original_amount, amount) + COALESCE(commission, 0)
WHERE transfer_direction = 'customer_to_customer'
  AND customer_id = to_customer_id
  AND commission_recipient_id = to_customer_id
  AND commission IS NOT NULL
  AND commission > 0
  AND (is_commission_movement IS NULL OR is_commission_movement = false)
  AND amount != (COALESCE(original_amount, amount) + COALESCE(commission, 0));

-- تحديث حركات المستلم عندما تذهب العمولة لـ P&L (الافتراضي)
-- amount يجب أن يكون = original_amount - commission
UPDATE account_movements
SET amount = COALESCE(original_amount, amount) - COALESCE(commission, 0)
WHERE transfer_direction = 'customer_to_customer'
  AND customer_id = to_customer_id
  AND (commission_recipient_id IS NULL OR commission_recipient_id NOT IN (from_customer_id, to_customer_id))
  AND commission IS NOT NULL
  AND commission > 0
  AND (is_commission_movement IS NULL OR is_commission_movement = false)
  AND amount != (COALESCE(original_amount, amount) - COALESCE(commission, 0));

-- إضافة تعليق
COMMENT ON TABLE account_movements IS 'جدول حركات الحسابات - تم تصحيح المبالغ الصافية بعد العمولة';
