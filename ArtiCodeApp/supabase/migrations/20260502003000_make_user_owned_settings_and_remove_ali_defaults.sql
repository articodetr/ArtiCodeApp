/*
  Reconcile legacy single-owner assumptions with the current multi-user app.
  This migration does four things safely on older and newer databases:
  1) Adds any missing app_settings columns used by the app.
  2) Makes app_settings user-owned with one row per app user.
  3) Removes legacy Ali-specific defaults and protections.
  4) Tightens letterhead_settings access so each user only edits their own row.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Reconcile app_settings schema across old/new databases
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_shop_logo_type text;
BEGIN
  SELECT data_type
  INTO v_shop_logo_type
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'app_settings'
    AND column_name = 'shop_logo';

  IF v_shop_logo_type = 'bytea' THEN
    ALTER TABLE public.app_settings
      ALTER COLUMN shop_logo TYPE text
      USING CASE
        WHEN shop_logo IS NULL THEN NULL
        ELSE convert_from(shop_logo, 'UTF8')
      END;
  END IF;
END $$;

ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS user_id uuid,
  ADD COLUMN IF NOT EXISTS header_layout text DEFAULT 'centered',
  ADD COLUMN IF NOT EXISTS header_primary_color text DEFAULT '#4F46E5',
  ADD COLUMN IF NOT EXISTS shop_name_en text DEFAULT 'ArtiCode',
  ADD COLUMN IF NOT EXISTS shop_phone_en text,
  ADD COLUMN IF NOT EXISTS shop_address_en text,
  ADD COLUMN IF NOT EXISTS selected_receipt_logo text,
  ADD COLUMN IF NOT EXISTS whatsapp_account_statement_template text DEFAULT 'مرحبا {الاسم}

{الرصيد}',
  ADD COLUMN IF NOT EXISTS whatsapp_share_account_template text DEFAULT 'مرحبا {الاسم}

كشف الحساب التفصيلي

{الأرصدة}

الحركات المالية

{الحركات المالية}

{اسم_المحل}';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'app_settings_user_id_fkey'
  ) THEN
    ALTER TABLE public.app_settings
      ADD CONSTRAINT app_settings_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES public.app_security(id) ON DELETE CASCADE;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS app_settings_user_id_uidx
  ON public.app_settings(user_id)
  WHERE user_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) Backfill one settings row per user using the legacy global row as seed
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_seed record;
BEGIN
  SELECT
    shop_name,
    shop_logo,
    shop_phone,
    shop_address,
    selected_receipt_logo,
    header_layout,
    header_primary_color,
    shop_name_en,
    shop_phone_en,
    shop_address_en,
    whatsapp_account_statement_template,
    whatsapp_share_account_template
  INTO v_seed
  FROM public.app_settings
  ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST, id
  LIMIT 1;

  INSERT INTO public.app_settings (
    user_id,
    shop_name,
    shop_logo,
    shop_phone,
    shop_address,
    selected_receipt_logo,
    header_layout,
    header_primary_color,
    shop_name_en,
    shop_phone_en,
    shop_address_en,
    whatsapp_account_statement_template,
    whatsapp_share_account_template
  )
  SELECT
    u.id,
    COALESCE(v_seed.shop_name, 'ArtiCode'),
    v_seed.shop_logo,
    COALESCE(v_seed.shop_phone, ''),
    COALESCE(v_seed.shop_address, ''),
    v_seed.selected_receipt_logo,
    COALESCE(v_seed.header_layout, 'centered'),
    COALESCE(v_seed.header_primary_color, '#4F46E5'),
    COALESCE(v_seed.shop_name_en, 'ArtiCode'),
    COALESCE(v_seed.shop_phone_en, ''),
    COALESCE(v_seed.shop_address_en, ''),
    COALESCE(v_seed.whatsapp_account_statement_template, 'مرحبا {الاسم}

{الرصيد}'),
    COALESCE(v_seed.whatsapp_share_account_template, 'مرحبا {الاسم}

كشف الحساب التفصيلي

{الأرصدة}

الحركات المالية

{الحركات المالية}

{اسم_المحل}')
  FROM public.app_security u
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.app_settings s
    WHERE s.user_id = u.id
  );
END $$;

CREATE OR REPLACE FUNCTION public.get_app_current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT id
  FROM public.app_security
  WHERE LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.is_app_admin()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.app_security
    WHERE LOWER(user_name) = LOWER(COALESCE(current_setting('app.current_user', true), ''))
      AND role = 'admin'
  );
$$;

CREATE OR REPLACE FUNCTION public.get_or_create_user_app_settings(p_user_id uuid)
RETURNS public.app_settings
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_settings public.app_settings;
BEGIN
  SELECT * INTO v_settings
  FROM public.app_settings
  WHERE user_id = p_user_id
  LIMIT 1;

  IF FOUND THEN
    RETURN v_settings;
  END IF;

  INSERT INTO public.app_settings (
    user_id, shop_name, shop_phone, shop_address, shop_name_en, shop_phone_en, shop_address_en,
    header_layout, header_primary_color, selected_receipt_logo
  )
  VALUES (
    p_user_id, 'ArtiCode', '', '', 'ArtiCode', '', '', 'centered', '#4F46E5', NULL
  )
  RETURNING * INTO v_settings;

  RETURN v_settings;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_app_current_user_id() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_app_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_or_create_user_app_settings(uuid) TO anon, authenticated;

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow anon and authenticated users full access to app_settings" ON public.app_settings;
DROP POLICY IF EXISTS "Allow app settings read" ON public.app_settings;
DROP POLICY IF EXISTS "Allow app settings update" ON public.app_settings;
DROP POLICY IF EXISTS "User owned app settings access" ON public.app_settings;

CREATE POLICY "User owned app settings access"
  ON public.app_settings
  FOR ALL
  TO anon, authenticated
  USING (
    user_id = public.get_app_current_user_id()
    OR public.is_app_admin()
  )
  WITH CHECK (
    user_id = public.get_app_current_user_id()
    OR public.is_app_admin()
  );

-- ---------------------------------------------------------------------------
-- 3) Remove Ali-specific assumptions
-- ---------------------------------------------------------------------------
ALTER TABLE public.account_movements
  ALTER COLUMN sender_name DROP DEFAULT,
  ALTER COLUMN beneficiary_name DROP DEFAULT;

DROP TRIGGER IF EXISTS prevent_ali_deletion_trigger ON public.app_security;
DROP FUNCTION IF EXISTS public.prevent_ali_deletion();
DROP POLICY IF EXISTS "Protect admin user Ali" ON public.app_security;

-- ---------------------------------------------------------------------------
-- 4) Tighten user-owned letterhead settings access
-- ---------------------------------------------------------------------------
ALTER TABLE public.letterhead_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow letterhead settings read" ON public.letterhead_settings;
DROP POLICY IF EXISTS "Allow letterhead settings insert" ON public.letterhead_settings;
DROP POLICY IF EXISTS "Allow letterhead settings update" ON public.letterhead_settings;
DROP POLICY IF EXISTS "Allow letterhead settings delete" ON public.letterhead_settings;
DROP POLICY IF EXISTS "User owned letterhead settings access" ON public.letterhead_settings;

CREATE POLICY "User owned letterhead settings access"
  ON public.letterhead_settings
  FOR ALL
  TO anon, authenticated
  USING (
    user_id = public.get_app_current_user_id()
    OR public.is_app_admin()
  )
  WITH CHECK (
    user_id = public.get_app_current_user_id()
    OR public.is_app_admin()
  );

COMMIT;
