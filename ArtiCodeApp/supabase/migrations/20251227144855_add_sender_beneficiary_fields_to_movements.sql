/*
  # إضافة حقول المرسل والمستفيد ورقم الحوالة

  1. التغييرات
    - إضافة حقل `sender_name` (اسم المرسل) إلى جدول `account_movements`
    - إضافة حقل `beneficiary_name` (اسم المستفيد) إلى جدول `account_movements`
    - إضافة حقل `transfer_number` (رقم الحوالة) إلى جدول `account_movements`
    - القيمة الافتراضية لـ `sender_name` هي "علي هادي علي الرازحي"
    - جميع الحقول اختيارية (nullable)

  2. الهدف
    - تمكين تخصيص اسم المرسل لكل حركة مالية
    - تمكين إضافة اسم المستفيد
    - تمكين إضافة رقم حوالة مخصص
*/

-- إضافة حقل اسم المرسل مع قيمة افتراضية
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'sender_name'
  ) THEN
    ALTER TABLE account_movements 
    ADD COLUMN sender_name text DEFAULT 'علي هادي علي الرازحي';
  END IF;
END $$;

-- إضافة حقل اسم المستفيد
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'beneficiary_name'
  ) THEN
    ALTER TABLE account_movements 
    ADD COLUMN beneficiary_name text;
  END IF;
END $$;

-- إضافة حقل رقم الحوالة
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'transfer_number'
  ) THEN
    ALTER TABLE account_movements 
    ADD COLUMN transfer_number text;
  END IF;
END $$;