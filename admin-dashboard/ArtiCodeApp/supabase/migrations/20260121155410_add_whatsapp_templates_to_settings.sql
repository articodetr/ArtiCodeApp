/*
  # Add WhatsApp Templates to App Settings

  1. Changes
    - Add `whatsapp_account_statement_template` column for quick account statement messages
    - Add `whatsapp_share_account_template` column for full account sharing messages

  2. Details
    - Both columns are TEXT type with default Arabic templates
    - Templates support variables that can be replaced dynamically
    - Account statement template variables: {customer_name}, {account_number}, {date}, {balance}
    - Share account template variables: {customer_name}, {account_number}, {date}, {balances}, {movements}, {shop_name}
*/

-- Add WhatsApp template columns to app_settings
DO $$
BEGIN
  -- Add account statement template column
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

  -- Add share account template column
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
