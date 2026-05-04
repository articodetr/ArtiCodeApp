/*
  # Fix movement_notifications RLS for Anonymous Users

  ## Problem
  The app uses custom authentication (not Supabase Auth), so users connect
  as anonymous users. The current RLS policies are set to 'authenticated'
  which prevents anonymous users from accessing notifications.

  ## Solution
  Update all RLS policies to allow 'anon' role instead of 'authenticated'.

  ## Changes
  - Drop existing policies
  - Create new policies for anon role
*/

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own notifications" ON movement_notifications;
DROP POLICY IF EXISTS "Users can update their own notifications" ON movement_notifications;
DROP POLICY IF EXISTS "System can insert notifications" ON movement_notifications;

-- Create new policies for anon users
CREATE POLICY "Allow read access to notifications"
  ON movement_notifications
  FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "Allow update access to notifications"
  ON movement_notifications
  FOR UPDATE
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow insert access to notifications"
  ON movement_notifications
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

CREATE POLICY "Allow delete access to notifications"
  ON movement_notifications
  FOR DELETE
  TO anon, authenticated
  USING (true);

COMMENT ON TABLE movement_notifications IS 
  'Notifications for movements - accessible by both anon and authenticated users';
