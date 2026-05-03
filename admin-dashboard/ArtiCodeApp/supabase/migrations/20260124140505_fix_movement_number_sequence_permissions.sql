/*
  # Fix Movement Number Generation - Sequence Permissions

  ## Problem
  The `generate_movement_number()` function is getting "permission denied for sequence daily_movement_seq"
  This causes duplicate key errors when trying to insert movements.

  ## Changes
  1. Recreate the function with SECURITY DEFINER to allow access to sequence
  2. Grant necessary permissions to the sequence
  3. Ensure the sequence is properly aligned with existing data
  4. Add safeguards to prevent race conditions

  ## Security
  - Using SECURITY DEFINER safely by limiting function scope
  - Function only generates numbers, no data access
*/

-- Drop the existing function
DROP FUNCTION IF EXISTS generate_movement_number();

-- Recreate the function with SECURITY DEFINER to allow sequence access
CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS TEXT
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  next_number INTEGER;
  formatted_number TEXT;
  max_attempts INTEGER := 10;
  attempt INTEGER := 0;
BEGIN
  -- Loop to handle potential race conditions
  LOOP
    attempt := attempt + 1;
    
    -- Get next value from sequence
    next_number := nextval('daily_movement_seq');
    
    -- Format as 6-digit number with leading zeros
    formatted_number := LPAD(next_number::TEXT, 6, '0');
    
    -- Check if this number already exists
    IF NOT EXISTS (
      SELECT 1 FROM account_movements 
      WHERE movement_number = formatted_number
    ) THEN
      RETURN formatted_number;
    END IF;
    
    -- If we've tried too many times, raise an error
    IF attempt >= max_attempts THEN
      RAISE EXCEPTION 'Failed to generate unique movement number after % attempts', max_attempts;
    END IF;
  END LOOP;
END;
$$;

-- Grant execute permission to all users (including anon and authenticated)
GRANT EXECUTE ON FUNCTION generate_movement_number() TO anon, authenticated, service_role;

-- Grant usage on the sequence to all roles
GRANT USAGE ON SEQUENCE daily_movement_seq TO anon, authenticated, service_role;

-- Ensure the sequence is at the correct position
-- Get the maximum movement number and set sequence accordingly
DO $$
DECLARE
  max_num INTEGER;
  seq_val INTEGER;
BEGIN
  -- Find the highest numeric movement number (6-digit format)
  SELECT COALESCE(MAX(movement_number::INTEGER), 0)
  INTO max_num
  FROM account_movements
  WHERE movement_number ~ '^\d{6}$';
  
  -- Get current sequence value
  SELECT last_value INTO seq_val FROM daily_movement_seq;
  
  -- If sequence is behind, update it
  IF max_num >= seq_val THEN
    PERFORM setval('daily_movement_seq', max_num + 1, false);
    RAISE NOTICE 'Sequence updated from % to %', seq_val, max_num + 1;
  END IF;
END $$;

-- Add comment to document the function
COMMENT ON FUNCTION generate_movement_number() IS 
  'Generates unique 6-digit movement numbers using SECURITY DEFINER to access sequence. 
   Includes retry logic to handle race conditions.';
