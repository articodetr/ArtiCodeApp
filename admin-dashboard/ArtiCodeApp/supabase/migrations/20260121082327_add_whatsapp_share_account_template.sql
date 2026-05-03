/*
  # Add WhatsApp Share Account Template Field

  ## Changes
  1. Add new column to app_settings table:
    - `whatsapp_share_account_template` (text, nullable)
      - Stores customizable template for detailed account share messages
      - Allows users to customize the format of account statement reports sent via WhatsApp
      - Supports template variables like {customer_name}, {date}, {balances}, etc.
  
  ## Notes
    - Field is nullable to allow using default template if not customized
    - No default value set - will use application-level default template
*/

-- Add whatsapp_share_account_template column to app_settings
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_share_account_template'
  ) THEN
    ALTER TABLE app_settings 
    ADD COLUMN whatsapp_share_account_template TEXT;
  END IF;
END $$;