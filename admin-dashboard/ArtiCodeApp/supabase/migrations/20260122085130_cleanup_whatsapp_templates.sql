/*
  # تنظيف وتوحيد قوالب الواتساب

  ## المشكلة
  يوجد تضارب في أسماء الحقول بين migrations مختلفة:
  - whatsapp_message_template (من migration قديم)
  - whatsapp_transaction_template (من migration قديم)
  - whatsapp_account_statement_template (المستخدم في الكود)
  - whatsapp_share_account_template (المستخدم في الكود)

  ## الحل
  - الإبقاء على الحقول المستخدمة في الكود فقط
  - إزالة الحقول القديمة غير المستخدمة
  - التأكد من وجود قيم افتراضية للحقول المستخدمة

  ## التغييرات
  1. حذف whatsapp_message_template إذا كان موجوداً
  2. حذف whatsapp_transaction_template إذا كان موجوداً
  3. التأكد من وجود whatsapp_account_statement_template مع قيمة افتراضية
  4. التأكد من وجود whatsapp_share_account_template مع قيمة افتراضية
*/

-- 1. حذف الحقول القديمة غير المستخدمة
DO $$
BEGIN
  -- حذف whatsapp_message_template إذا كان موجوداً
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_message_template'
  ) THEN
    ALTER TABLE app_settings DROP COLUMN whatsapp_message_template;
  END IF;

  -- حذف whatsapp_transaction_template إذا كان موجوداً
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_transaction_template'
  ) THEN
    ALTER TABLE app_settings DROP COLUMN whatsapp_transaction_template;
  END IF;
END $$;

-- 2. التأكد من وجود whatsapp_account_statement_template مع قيمة افتراضية
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_account_statement_template'
  ) THEN
    ALTER TABLE app_settings ADD COLUMN whatsapp_account_statement_template TEXT DEFAULT 'مرحباً {customer_name}،

كشف حساب رقم: {account_number}
التاريخ: {date}

الأرصدة:
{balance}

شكراً لك';
  END IF;
END $$;

-- 3. التأكد من وجود whatsapp_share_account_template مع قيمة افتراضية
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_share_account_template'
  ) THEN
    ALTER TABLE app_settings ADD COLUMN whatsapp_share_account_template TEXT DEFAULT 'مرحباً {customer_name}،

كشف حساب تفصيلي
رقم الحساب: {account_number}
التاريخ: {date}

{balances}

الحركات المالية:
{movements}

{shop_name}';
  END IF;
END $$;

-- 4. تحديث السجل الموجود بالقيم الافتراضية إذا كانت NULL
UPDATE app_settings
SET
  whatsapp_account_statement_template = COALESCE(
    whatsapp_account_statement_template,
    'مرحباً {customer_name}،

كشف حساب رقم: {account_number}
التاريخ: {date}

الأرصدة:
{balance}

شكراً لك'
  ),
  whatsapp_share_account_template = COALESCE(
    whatsapp_share_account_template,
    'مرحباً {customer_name}،

كشف حساب تفصيلي
رقم الحساب: {account_number}
التاريخ: {date}

{balances}

الحركات المالية:
{movements}

{shop_name}'
  )
WHERE id IS NOT NULL;