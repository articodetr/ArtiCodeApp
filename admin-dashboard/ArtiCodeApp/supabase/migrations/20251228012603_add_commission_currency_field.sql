/*
  # Add Commission Currency Field to Account Movements

  ## 1. Changes
    - Add `commission_currency` column to `account_movements` table
      - Type: text (currency code)
      - Default: 'IQD' (Iraqi Dinar)
      - Optional (nullable) - inherits from default value
      - Allows tracking which currency the commission is charged in

  ## 2. Notes
    - Commission currency can be different from transaction currency
    - Default is IQD (Iraqi Dinar) but can be set to any currency
    - This allows flexibility in charging commissions in different currencies
*/

-- Add commission_currency column to account_movements table
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'commission_currency'
  ) THEN
    ALTER TABLE account_movements
    ADD COLUMN commission_currency text DEFAULT 'IQD';
  END IF;
END $$;