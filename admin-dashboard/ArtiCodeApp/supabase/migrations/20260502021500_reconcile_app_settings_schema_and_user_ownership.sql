/*
  Reconcile app_settings schema with the codebase and move settings ownership to each app user.
  This migration is safe for databases that were created from older migrations where app_settings
  had only: id, shop_name, shop_logo, shop_phone, shop_address, pin_code, updated_at.
*/

BEGIN;

-- Make sure helper exists for custom auth context.
CREATE OR REPLACE FUNCTION public.get_current_user_id()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_user_name text;
  v_user_id uuid;
BEGIN
  v_user_name := current_setting('app.current_user', true);

  IF v_user_name IS NULL OR v_user_name = '' THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_user_id
  FROM public.app_security
  WHERE lower(user_name) = lower(v_user_name)
  LIMIT 1;

  RETURN v_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_current_user_id() TO anon, authenticated;

ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES public.app_security(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS header_layout text DEFAULT 'centered',
  ADD COLUMN IF NOT EXISTS header_primary_color text DEFAULT '#4F46E5',
  ADD COLUMN IF NOT EXISTS shop_name_en text DEFAULT 'ArtiCode',
  ADD COLUMN IF NOT EXISTS shop_phone_en text,
  ADD COLUMN IF NOT EXISTS shop_address_en text,
  ADD COLUMN IF NOT EXISTS selected_receipt_logo text,
  ADD COLUMN IF NOT EXISTS whatsapp_account_statement_template text DEFAULT 'مرحباً {customer_name}،

هذا كشف حسابك حتى تاريخ {date}:
{balances}

تفاصيل الحركات:
{movements}

مع التحية
{shop_name}',
  ADD COLUMN IF NOT EXISTS whatsapp_share_account_template text DEFAULT 'مرحباً {customer_name}،
رقم حسابك لدينا هو: {account_number}
مع التحية
{shop_name}',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

UPDATE public.app_settings
SET created_at = COALESCE(created_at, updated_at, now())
WHERE created_at IS NULL;

-- Remove obsolete pin code field if it still exists on older databases.
ALTER TABLE public.app_settings
  DROP COLUMN IF EXISTS pin_code;

CREATE UNIQUE INDEX IF NOT EXISTS app_settings_user_id_uidx
  ON public.app_settings(user_id)
  WHERE user_id IS NOT NULL;

DO $$
DECLARE
  v_seed RECORD;
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
  ORDER BY updated_at DESC NULLS LAST, id
  LIMIT 1;

  INSERT INTO public.app_settings (
    id,
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
    whatsapp_share_account_template,
    created_at,
    updated_at
  )
  SELECT
    gen_random_uuid(),
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
    COALESCE(v_seed.whatsapp_account_statement_template, 'مرحباً {customer_name}،

هذا كشف حسابك حتى تاريخ {date}:
{balances}

تفاصيل الحركات:
{movements}

مع التحية
{shop_name}'),
    COALESCE(v_seed.whatsapp_share_account_template, 'مرحباً {customer_name}،
رقم حسابك لدينا هو: {account_number}
مع التحية
{shop_name}'),
    now(),
    now()
  FROM public.app_security u
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.app_settings s
    WHERE s.user_id = u.id
  );
END $$;

CREATE OR REPLACE FUNCTION public.get_or_create_user_settings(p_user_id uuid)
RETURNS public.app_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings public.app_settings;
  v_seed public.app_settings;
BEGIN
  SELECT *
  INTO v_settings
  FROM public.app_settings
  WHERE user_id = p_user_id
  LIMIT 1;

  IF FOUND THEN
    RETURN v_settings;
  END IF;

  SELECT *
  INTO v_seed
  FROM public.app_settings
  WHERE user_id IS NULL OR id = '00000000-0000-0000-0000-000000000000'
  ORDER BY updated_at DESC NULLS LAST, id
  LIMIT 1;

  INSERT INTO public.app_settings (
    id,
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
    whatsapp_share_account_template,
    created_at,
    updated_at
  )
  VALUES (
    gen_random_uuid(),
    p_user_id,
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
    COALESCE(v_seed.whatsapp_account_statement_template, 'مرحباً {customer_name}،

هذا كشف حسابك حتى تاريخ {date}:
{balances}

تفاصيل الحركات:
{movements}

مع التحية
{shop_name}'),
    COALESCE(v_seed.whatsapp_share_account_template, 'مرحباً {customer_name}،
رقم حسابك لدينا هو: {account_number}
مع التحية
{shop_name}'),
    now(),
    now()
  )
  RETURNING * INTO v_settings;

  RETURN v_settings;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_or_create_user_settings(uuid) TO anon, authenticated;

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow app settings read" ON public.app_settings;
DROP POLICY IF EXISTS "Allow app settings update" ON public.app_settings;
DROP POLICY IF EXISTS "Allow app settings insert" ON public.app_settings;
DROP POLICY IF EXISTS "Allow app settings delete" ON public.app_settings;
DROP POLICY IF EXISTS "Users can read own app settings" ON public.app_settings;
DROP POLICY IF EXISTS "Users can insert own app settings" ON public.app_settings;
DROP POLICY IF EXISTS "Users can update own app settings" ON public.app_settings;
DROP POLICY IF EXISTS "Admins can delete app settings" ON public.app_settings;

-- The project uses custom auth based on app_security + AsyncStorage rather than Supabase Auth.
-- To keep the app working reliably in React Native, app_settings follows the same permissive RLS
-- approach already used in customers, while ownership is enforced by user_id in the app logic.
CREATE POLICY "Allow read access to app_settings"
  ON public.app_settings FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "Allow insert access to app_settings"
  ON public.app_settings FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

CREATE POLICY "Allow update access to app_settings"
  ON public.app_settings FOR UPDATE
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow delete access to app_settings"
  ON public.app_settings FOR DELETE
  TO anon, authenticated
  USING (true);

COMMIT;
