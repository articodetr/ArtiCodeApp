/*
  # Create customizable receipt letterhead settings

  This migration adds a dedicated table for the receipt/print letterhead.
  The visual target size used in the app is 534 x 106.
*/

CREATE TABLE IF NOT EXISTS public.letterhead_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.app_security(id) ON DELETE CASCADE,
  logo_url text,
  business_name text NOT NULL DEFAULT 'ArtiCode',
  phone_number text NOT NULL DEFAULT '',
  background_color text NOT NULL DEFAULT '#FFFFFF',
  primary_color text NOT NULL DEFAULT '#111827',
  text_color text NOT NULL DEFAULT '#374151',
  border_color text NOT NULL DEFAULT '#E5E7EB',
  accent_color text NOT NULL DEFAULT '#0EA5E9',
  layout text NOT NULL DEFAULT 'logo_right',
  show_logo boolean NOT NULL DEFAULT true,
  show_phone boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT letterhead_settings_user_unique UNIQUE (user_id),
  CONSTRAINT letterhead_settings_layout_check CHECK (layout IN ('logo_right')),
  CONSTRAINT letterhead_settings_background_color_check CHECK (background_color ~ '^#[0-9A-Fa-f]{6}$'),
  CONSTRAINT letterhead_settings_primary_color_check CHECK (primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  CONSTRAINT letterhead_settings_text_color_check CHECK (text_color ~ '^#[0-9A-Fa-f]{6}$'),
  CONSTRAINT letterhead_settings_border_color_check CHECK (border_color ~ '^#[0-9A-Fa-f]{6}$'),
  CONSTRAINT letterhead_settings_accent_color_check CHECK (accent_color ~ '^#[0-9A-Fa-f]{6}$')
);

CREATE INDEX IF NOT EXISTS idx_letterhead_settings_user_id
  ON public.letterhead_settings(user_id);

CREATE OR REPLACE FUNCTION public.set_letterhead_settings_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_letterhead_settings_updated_at ON public.letterhead_settings;
CREATE TRIGGER trg_letterhead_settings_updated_at
  BEFORE UPDATE ON public.letterhead_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_letterhead_settings_updated_at();

ALTER TABLE public.letterhead_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow letterhead settings read" ON public.letterhead_settings;
DROP POLICY IF EXISTS "Allow letterhead settings insert" ON public.letterhead_settings;
DROP POLICY IF EXISTS "Allow letterhead settings update" ON public.letterhead_settings;
DROP POLICY IF EXISTS "Allow letterhead settings delete" ON public.letterhead_settings;

-- The app uses its own app_security login system instead of Supabase Auth.
-- These policies match the current app_settings access model while the app itself writes by current user_id.
CREATE POLICY "Allow letterhead settings read"
  ON public.letterhead_settings FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "Allow letterhead settings insert"
  ON public.letterhead_settings FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

CREATE POLICY "Allow letterhead settings update"
  ON public.letterhead_settings FOR UPDATE
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow letterhead settings delete"
  ON public.letterhead_settings FOR DELETE
  TO anon, authenticated
  USING (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.letterhead_settings TO anon, authenticated;
