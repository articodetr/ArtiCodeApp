/*
  # إضافة عمود is_profit_loss_account إلى جدول customers

  ## المشكلة
  عمود is_profit_loss_account غير موجود في جدول customers رغم أنه مطلوب.

  ## الحل
  1. إضافة عمود is_profit_loss_account إلى جدول customers
  2. تحديث حساب "الأرباح والخسائر" ليكون هو الحساب الوحيد مع is_profit_loss_account = true
  3. إضافة constraint لضمان وجود حساب واحد فقط
*/

-- إضافة العمود
ALTER TABLE customers ADD COLUMN IF NOT EXISTS is_profit_loss_account boolean DEFAULT false;

-- تحديث حساب الأرباح والخسائر
UPDATE customers 
SET is_profit_loss_account = true 
WHERE name = 'الأرباح والخسائر';

-- إضافة constraint لضمان وجود حساب واحد فقط
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'only_one_profit_loss_account'
  ) THEN
    ALTER TABLE customers
    ADD CONSTRAINT only_one_profit_loss_account
    EXCLUDE USING btree (is_profit_loss_account WITH =)
    WHERE (is_profit_loss_account = true);
  END IF;
END $$;

-- إضافة index
CREATE INDEX IF NOT EXISTS idx_customers_profit_loss 
ON customers(is_profit_loss_account) 
WHERE is_profit_loss_account = true;