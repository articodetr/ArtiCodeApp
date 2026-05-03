/*
  # Add PIN Security System

  1. New Tables
    - `app_security`
      - `id` (uuid, primary key)
      - `user_name` (text) - Name of the person who set up the PIN
      - `pin_hash` (text) - Hashed PIN for security
      - `created_at` (timestamptz)
      - `updated_at` (timestamptz)
      - Only one row allowed in this table

  2. Security
    - Enable RLS on `app_security` table
    - Add policies for authenticated users to manage PIN settings
*/

-- Create app_security table
CREATE TABLE IF NOT EXISTS app_security (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_name text NOT NULL,
  pin_hash text NOT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Enable RLS
ALTER TABLE app_security ENABLE ROW LEVEL SECURITY;

-- Policies for authenticated users
CREATE POLICY "Authenticated users can view PIN settings"
  ON app_security FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can insert PIN settings"
  ON app_security FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "Authenticated users can update PIN settings"
  ON app_security FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated users can delete PIN settings"
  ON app_security FOR DELETE
  TO authenticated
  USING (true);

-- Add constraint to ensure only one PIN configuration exists
CREATE UNIQUE INDEX IF NOT EXISTS single_pin_config ON app_security ((1));

-- Function to update the updated_at timestamp
CREATE OR REPLACE FUNCTION update_app_security_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to automatically update updated_at
DROP TRIGGER IF EXISTS update_app_security_updated_at_trigger ON app_security;
CREATE TRIGGER update_app_security_updated_at_trigger
  BEFORE UPDATE ON app_security
  FOR EACH ROW
  EXECUTE FUNCTION update_app_security_updated_at();