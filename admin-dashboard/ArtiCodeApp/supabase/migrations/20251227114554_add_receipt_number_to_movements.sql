/*
  # Add Receipt Number to Account Movements

  1. Changes
    - Add `receipt_number` column to `account_movements` table
      - Unique 6-digit number for each movement
      - Used for generating receipt documents
    - Add `receipt_generated_at` column to track when receipt was generated
    - Create function to generate unique receipt numbers
    - Create trigger to auto-generate receipt numbers

  2. Security
    - No changes to RLS policies
*/

-- Add receipt_number column if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'receipt_number'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN receipt_number text UNIQUE;
  END IF;
END $$;

-- Add receipt_generated_at column if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'receipt_generated_at'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN receipt_generated_at timestamptz;
  END IF;
END $$;

-- Create or replace function to generate receipt number
CREATE OR REPLACE FUNCTION generate_receipt_number()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  new_number text;
  max_number integer;
BEGIN
  -- Get the maximum existing receipt number
  SELECT COALESCE(MAX(CAST(receipt_number AS integer)), 100000)
  INTO max_number
  FROM account_movements
  WHERE receipt_number ~ '^[0-9]+$';
  
  -- Generate next number
  new_number := (max_number + 1)::text;
  
  -- Ensure it's at least 6 digits
  WHILE LENGTH(new_number) < 6 LOOP
    new_number := '0' || new_number;
  END LOOP;
  
  RETURN new_number;
END;
$$;

-- Create or replace trigger function to auto-generate receipt number
CREATE OR REPLACE FUNCTION auto_generate_receipt_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.receipt_number IS NULL THEN
    NEW.receipt_number := generate_receipt_number();
    NEW.receipt_generated_at := now();
  END IF;
  RETURN NEW;
END;
$$;

-- Drop trigger if exists and create new one
DROP TRIGGER IF EXISTS trigger_auto_generate_receipt_number ON account_movements;
CREATE TRIGGER trigger_auto_generate_receipt_number
  BEFORE INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION auto_generate_receipt_number();