/*
  # Update Commission Currency Default to USD

  1. Changes
    - Change commission_currency column default from 'YER' to 'USD' in account_movements table
    - This ensures new records have USD as the default commission currency
  
  2. Notes
    - Existing records remain unchanged
    - Users can still manually change the commission currency to any supported currency
*/

-- Update the default value for commission_currency to USD
ALTER TABLE account_movements 
ALTER COLUMN commission_currency SET DEFAULT 'USD';
