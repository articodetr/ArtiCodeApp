/*
  # Enable Realtime for Auto-Refresh Feature

  1. Changes
    - Enable realtime on account_movements table
    - Enable realtime on customers table
    - Enable realtime on transactions table

  2. Purpose
    - Allow the app to receive real-time updates when data changes
    - Auto-refresh all screens when movements, customers, or transactions are modified
    - Improve user experience with instant data synchronization
*/

-- Enable realtime for account_movements table
ALTER PUBLICATION supabase_realtime ADD TABLE account_movements;

-- Enable realtime for customers table
ALTER PUBLICATION supabase_realtime ADD TABLE customers;

-- Enable realtime for transactions table
ALTER PUBLICATION supabase_realtime ADD TABLE transactions;
