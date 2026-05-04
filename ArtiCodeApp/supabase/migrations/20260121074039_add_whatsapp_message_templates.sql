/*
  # إضافة قوالب رسائل الواتساب القابلة للتخصيص

  1. التغييرات
    - إضافة عمود `whatsapp_account_statement_template` لحفظ قالب رسالة كشف الحساب
    - إضافة عمود `whatsapp_transaction_template` لحفظ قالب رسالة تفاصيل الحوالة

  2. القيم الافتراضية
    - قالب كشف الحساب يحتوي على: اسم العميل، رقم الحساب، التاريخ، والرصيد
    - قالب تفاصيل الحوالة يحتوي على: اسم العميل، رقم الحوالة، المبلغ المرسل والمستلم، واسم المحل

  3. المتغيرات المتاحة
    - {customer_name} - اسم العميل
    - {account_number} - رقم الحساب
    - {date} - التاريخ الحالي
    - {balance} - الرصيد الحالي
    - {shop_name} - اسم المحل
    - {shop_phone} - رقم هاتف المحل
    - {transaction_number} - رقم الحوالة
    - {amount_sent} - المبلغ المرسل
    - {amount_received} - المبلغ المستلم
    - {currency_sent} - عملة الإرسال
    - {currency_received} - عملة الاستلام
*/

-- إضافة عمود قالب رسالة كشف الحساب
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_account_statement_template'
  ) THEN
    ALTER TABLE app_settings
    ADD COLUMN whatsapp_account_statement_template text DEFAULT 'مرحباً {customer_name}،
رقم الحساب: {account_number}
التاريخ: {date}

{balance}';
  END IF;
END $$;

-- إضافة عمود قالب رسالة تفاصيل الحوالة
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_transaction_template'
  ) THEN
    ALTER TABLE app_settings
    ADD COLUMN whatsapp_transaction_template text DEFAULT 'مرحباً {customer_name}،

سند الحوالة رقم: {transaction_number}

المبلغ المرسل: {amount_sent} {currency_sent}
المبلغ المستلم: {amount_received} {currency_received}

شكراً لثقتكم بنا
{shop_name}';
  END IF;
END $$;

-- تحديث السجل الموجود بالقيم الافتراضية (إذا كانت القيم NULL)
UPDATE app_settings
SET 
  whatsapp_account_statement_template = COALESCE(whatsapp_account_statement_template, 'مرحباً {customer_name}،
رقم الحساب: {account_number}
التاريخ: {date}

{balance}'),
  whatsapp_transaction_template = COALESCE(whatsapp_transaction_template, 'مرحباً {customer_name}،

سند الحوالة رقم: {transaction_number}

المبلغ المرسل: {amount_sent} {currency_sent}
المبلغ المستلم: {amount_received} {currency_received}

شكراً لثقتكم بنا
{shop_name}')
WHERE id IS NOT NULL;