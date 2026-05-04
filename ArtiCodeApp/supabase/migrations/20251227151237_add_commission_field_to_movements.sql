/*
  # Add Commission Field to Account Movements

  1. Changes
    - Add `commission` column to `account_movements` table
      - Type: numeric (decimal numbers)
      - Optional (nullable) - not all movements have commission
      - For display purposes only - does NOT affect balance calculations
  
  2. Notes
    - Commission is stored separately and not added to the amount
    - This field is optional and can be null
    - Used for money transfer commission tracking
*/

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'commission'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN commission numeric;
  END IF;
END $$;