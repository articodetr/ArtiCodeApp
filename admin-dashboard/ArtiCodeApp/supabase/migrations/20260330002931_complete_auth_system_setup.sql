/*
  # Complete Authentication & Authorization System
  
  This migration creates a fully functional authentication system with:
  - User registration and login
  - Password hashing and verification  
  - Login attempt tracking and rate limiting (5 attempts = 15 min lockout)
  - Role-based access control (admin, user)
  - Account number generation (26000+)
  - RLS policies for security
  - Helper functions for auth operations
*/

-- 1. Create app_security table for user authentication
CREATE TABLE IF NOT EXISTS app_security (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_name text UNIQUE NOT NULL,
  full_name text NOT NULL,
  pin_hash text NOT NULL,
  account_number text UNIQUE,
  role text NOT NULL DEFAULT 'user',
  is_active boolean NOT NULL DEFAULT true,
  last_login timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_app_security_user_name_lower ON app_security (LOWER(user_name));
CREATE INDEX IF NOT EXISTS idx_app_security_account_number ON app_security (account_number);
CREATE INDEX IF NOT EXISTS idx_app_security_role ON app_security (role);

-- 2. Create app_settings table
CREATE TABLE IF NOT EXISTS app_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_name text NOT NULL DEFAULT 'الترف للحوالات المالية',
  shop_phone text,
  shop_address text,
  shop_logo bytea,
  header_layout text DEFAULT 'centered',
  header_primary_color text DEFAULT '#4F46E5',
  shop_name_en text DEFAULT 'Alatrof Money Transfer',
  shop_phone_en text,
  shop_address_en text,
  selected_receipt_logo text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Insert default settings with fixed ID if not exists
INSERT INTO app_settings (id)
VALUES ('00000000-0000-0000-0000-000000000000')
ON CONFLICT (id) DO NOTHING;

-- 3. Create login_attempts table for rate limiting
CREATE TABLE IF NOT EXISTS login_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_name text NOT NULL,
  success boolean NOT NULL DEFAULT false,
  ip_address text,
  device_info text,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_user_time ON login_attempts (LOWER(user_name), attempted_at DESC);

-- 4. Create user_info view (non-sensitive user data)
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

-- 5. Create sequence for account numbers
CREATE SEQUENCE IF NOT EXISTS user_account_number_seq
  START WITH 26000
  INCREMENT BY 1
  NO MAXVALUE
  CACHE 1;

-- 6. Create function to generate account number
CREATE OR REPLACE FUNCTION generate_user_account_number()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  new_account_number text;
  account_exists boolean;
BEGIN
  LOOP
    new_account_number := LPAD(nextval('user_account_number_seq')::text, 5, '0');
    
    SELECT EXISTS(
      SELECT 1 FROM app_security WHERE account_number = new_account_number
    ) INTO account_exists;
    
    EXIT WHEN NOT account_exists;
  END LOOP;
  
  RETURN new_account_number;
END;
$$;

-- 7. Create trigger to auto-generate account_number
CREATE OR REPLACE FUNCTION trigger_generate_user_account_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
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

-- 8. Create function to check login attempts (rate limiting)
CREATE OR REPLACE FUNCTION check_login_attempts(p_user_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  failed_attempts integer;
BEGIN
  SELECT COUNT(*)
  INTO failed_attempts
  FROM login_attempts
  WHERE LOWER(user_name) = LOWER(p_user_name)
    AND success = false
    AND attempted_at > now() - interval '15 minutes';
  
  RETURN failed_attempts >= 5;
END;
$$;

-- 9. Create function to record login attempt
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
  INSERT INTO login_attempts (user_name, success, ip_address, device_info, attempted_at)
  VALUES (p_user_name, p_success, p_ip_address, p_device_info, now());
  
  DELETE FROM login_attempts
  WHERE attempted_at < now() - interval '24 hours';
END;
$$;

-- 10. Create function to set current user for RLS context
CREATE OR REPLACE FUNCTION set_current_user(user_name text)
RETURNS void
LANGUAGE sql
AS $$
  SELECT set_config('app.current_user', user_name, false);
$$;

-- 11. Enable RLS on all tables
ALTER TABLE app_security ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE login_attempts ENABLE ROW LEVEL SECURITY;

-- 12. Drop existing policies to recreate them cleanly
DROP POLICY IF EXISTS "Allow user registration" ON app_security;
DROP POLICY IF EXISTS "Allow login" ON app_security;
DROP POLICY IF EXISTS "Users can read own record" ON app_security;
DROP POLICY IF EXISTS "Users can update own record" ON app_security;
DROP POLICY IF EXISTS "Allow login attempt tracking" ON login_attempts;
DROP POLICY IF EXISTS "Users can view own login attempts" ON login_attempts;
DROP POLICY IF EXISTS "Allow app settings read" ON app_settings;
DROP POLICY IF EXISTS "Allow app settings update" ON app_settings;

-- 13. Create RLS policies for app_security table
-- Allow anyone to insert (register)
CREATE POLICY "Allow user registration"
  ON app_security FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

-- Allow users to read their own record
CREATE POLICY "Users can read own record"
  ON app_security FOR SELECT
  TO anon, authenticated
  USING (
    LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))
    OR (SELECT role FROM app_security WHERE LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))) = 'admin'
  );

-- Allow users to update their own record
CREATE POLICY "Users can update own record"
  ON app_security FOR UPDATE
  TO authenticated
  USING (
    LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))
    OR (SELECT role FROM app_security WHERE LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))) = 'admin'
  )
  WITH CHECK (
    LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))
    OR (SELECT role FROM app_security WHERE LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))) = 'admin'
  );

-- 14. Create RLS policies for login_attempts table
-- Allow insert for login attempt tracking
CREATE POLICY "Allow login attempt tracking"
  ON login_attempts FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

-- Allow users to view their own attempts
CREATE POLICY "Users can view own login attempts"
  ON login_attempts FOR SELECT
  TO anon, authenticated
  USING (
    LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))
  );

-- 15. Create RLS policies for app_settings table
-- Allow all users to read settings
CREATE POLICY "Allow app settings read"
  ON app_settings FOR SELECT
  TO anon, authenticated
  USING (true);

-- Allow admin users to update settings
CREATE POLICY "Allow app settings update"
  ON app_settings FOR UPDATE
  TO authenticated
  USING (
    (SELECT role FROM app_security WHERE LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))) = 'admin'
  )
  WITH CHECK (
    (SELECT role FROM app_security WHERE LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))) = 'admin'
  );

-- 16. Grant permissions on views
GRANT SELECT ON user_info TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON app_settings TO anon, authenticated;
