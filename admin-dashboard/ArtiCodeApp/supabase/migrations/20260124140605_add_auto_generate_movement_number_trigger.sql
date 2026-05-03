/*
  # Add Auto-Generate Movement Number Trigger

  ## Problem
  The movement_number field is not being populated automatically when inserting movements.
  This causes NULL constraint violations.

  ## Solution
  Create a BEFORE INSERT trigger that automatically generates movement_number using the 
  generate_movement_number() function.

  ## Changes
  1. Create trigger function to auto-generate movement numbers
  2. Add BEFORE INSERT trigger on account_movements table
*/

-- Create the trigger function
CREATE OR REPLACE FUNCTION auto_generate_movement_number()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  -- Only generate if movement_number is NULL
  IF NEW.movement_number IS NULL THEN
    NEW.movement_number := generate_movement_number();
  END IF;
  
  RETURN NEW;
END;
$$;

-- Create the trigger
DROP TRIGGER IF EXISTS trigger_auto_generate_movement_number ON account_movements;

CREATE TRIGGER trigger_auto_generate_movement_number
  BEFORE INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION auto_generate_movement_number();

-- Add comment
COMMENT ON FUNCTION auto_generate_movement_number() IS 
  'Automatically generates movement_number for new movements if not provided';
