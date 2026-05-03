/*
  # Add User Registration System with Enhanced Security

  1. Schema Updates
    - Add `full_name` (text, NOT NULL) to `app_security` table
    - Add `account_number` (text, UNIQUE) to `app_security` table
    - Create `login_attempts` table for tracking failed login attempts
    
  2. Sequences
    - Create `user_account_number_seq` starting from 26000 for user account numbers
    
  3. Functions
    - `generate_user_account_number()`: Generate sequential 5-digit account numbers starting from 26000
    - `check_login_attempts(username)`: Check if user has exceeded login attempts limit
    - `record_login_attempt(username, success, ip_address)`: Record each login attempt
    - `cleanup_old_login_attempts()`: Clean up login attempts older than 24 hours
    
  4. Triggers
    - Auto-generate account_number for new users
    
  5. Data Migration
    - Migrate existing users (Ali → 26000, Galal → 26001, A → 26002)
    
  6. Security
    - Add constraints for unique username and account_number
    - Enable RLS on login_attempts table
*/

-- 1. Add new columns to app_security table
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'app_security' AND column_name = 'full_name'
  ) THEN
    ALTER TABLE app_security ADD COLUMN full_name text;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'app_security' AND column_name = 'account_number'
  ) THEN
    ALTER TABLE app_security ADD COLUMN account_number text;
  END IF;
END $$;

-- 2. Create login_attempts table
CREATE TABLE IF NOT EXISTS login_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_name text NOT NULL,
  success boolean NOT NULL DEFAULT false,
  ip_address text,
  device_info text,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz DEFAULT now()
);

-- Create index for faster queries
CREATE INDEX IF NOT EXISTS idx_login_attempts_user_time 
  ON login_attempts(user_name, attempted_at DESC);

-- Enable RLS
ALTER TABLE login_attempts ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "Users can view own login attempts" ON login_attempts;
DROP POLICY IF EXISTS "Allow login attempt tracking" ON login_attempts;

-- Allow authenticated users to read their own attempts
CREATE POLICY "Users can view own login attempts"
  ON login_attempts FOR SELECT
  TO authenticated
  USING (user_name = current_setting('app.current_user', true));

-- Allow insert for login tracking (will be done by auth system)
CREATE POLICY "Allow login attempt tracking"
  ON login_attempts FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

-- 3. Create sequence for user account numbers
CREATE SEQUENCE IF NOT EXISTS user_account_number_seq
  START WITH 26000
  INCREMENT BY 1
  NO MAXVALUE
  CACHE 1;

-- 4. Create function to generate user account number
CREATE OR REPLACE FUNCTION generate_user_account_number()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  new_account_number text;
  account_exists boolean;
BEGIN
  LOOP
    -- Get next value from sequence
    new_account_number := LPAD(nextval('user_account_number_seq')::text, 5, '0');
    
    -- Check if account number already exists (safety check)
    SELECT EXISTS(
      SELECT 1 FROM app_security WHERE account_number = new_account_number
    ) INTO account_exists;
    
    -- If it doesn't exist, return it
    EXIT WHEN NOT account_exists;
  END LOOP;
  
  RETURN new_account_number;
END;
$$;

-- 5. Create function to check login attempts
CREATE OR REPLACE FUNCTION check_login_attempts(p_user_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  failed_attempts integer;
BEGIN
  -- Count failed attempts in last 15 minutes
  SELECT COUNT(*)
  INTO failed_attempts
  FROM login_attempts
  WHERE user_name = p_user_name
    AND success = false
    AND attempted_at > now() - interval '15 minutes';
  
  -- Return true if exceeded limit (5 attempts)
  RETURN failed_attempts >= 5;
END;
$$;

-- 6. Create function to record login attempt
CREATE OR REPLACE FUNCTION record_login_attempt(
  p_user_name text,
  p_success boolean,
  p_ip_address text DEFAULT NULL,
  p_device_info text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Insert login attempt
  INSERT INTO login_attempts (user_name, success, ip_address, device_info, attempted_at)
  VALUES (p_user_name, p_success, p_ip_address, p_device_info, now());
  
  -- Clean up old attempts (older than 24 hours)
  DELETE FROM login_attempts
  WHERE attempted_at < now() - interval '24 hours';
END;
$$;

-- 7. Create function to cleanup old login attempts
CREATE OR REPLACE FUNCTION cleanup_old_login_attempts()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM login_attempts
  WHERE attempted_at < now() - interval '24 hours';
END;
$$;

-- 8. Create trigger to auto-generate account number for new users
CREATE OR REPLACE FUNCTION trigger_generate_user_account_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Only generate if account_number is not provided
  IF NEW.account_number IS NULL THEN
    NEW.account_number := generate_user_account_number();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_generate_user_account_number ON app_security;
CREATE TRIGGER trg_generate_user_account_number
  BEFORE INSERT ON app_security
  FOR EACH ROW
  EXECUTE FUNCTION trigger_generate_user_account_number();

-- 9. Migrate existing users
DO $$
BEGIN
  -- Update Ali with account number 26000
  UPDATE app_security 
  SET 
    account_number = '26000',
    full_name = COALESCE(full_name, 'علي محمد')
  WHERE user_name = 'Ali' AND account_number IS NULL;
  
  -- Update Galal with account number 26001
  UPDATE app_security 
  SET 
    account_number = '26001',
    full_name = COALESCE(full_name, 'جلال أحمد')
  WHERE user_name = 'Galal' AND account_number IS NULL;
  
  -- Update A (admin) with account number 26002
  UPDATE app_security 
  SET 
    account_number = '26002',
    full_name = COALESCE(full_name, 'المدير')
  WHERE user_name = 'A' AND account_number IS NULL;
  
  -- Set sequence to next available number
  PERFORM setval('user_account_number_seq', 26003, false);
END $$;

-- 10. Make full_name NOT NULL after migration
ALTER TABLE app_security ALTER COLUMN full_name SET NOT NULL;

-- 11. Add unique constraint on account_number
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'unique_account_number'
  ) THEN
    ALTER TABLE app_security ADD CONSTRAINT unique_account_number UNIQUE (account_number);
  END IF;
END $$;

-- 12. Add constraint for username uniqueness (if not exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'unique_user_name'
  ) THEN
    ALTER TABLE app_security ADD CONSTRAINT unique_user_name UNIQUE (user_name);
  END IF;
END $$;

-- 13. Update RLS policies for app_security to allow registration
DROP POLICY IF EXISTS "Allow user registration" ON app_security;
CREATE POLICY "Allow user registration"
  ON app_security FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

-- 14. Create a view for user information (excluding sensitive data)
CREATE OR REPLACE VIEW user_info AS
SELECT 
  id,
  user_name,
  full_name,
  account_number,
  role,
  is_active,
  created_at,
  last_login
FROM app_security;

-- Grant select on view
GRANT SELECT ON user_info TO anon, authenticated;
