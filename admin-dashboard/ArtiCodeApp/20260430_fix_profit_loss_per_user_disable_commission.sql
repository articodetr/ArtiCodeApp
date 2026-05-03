/*
  Fixes for ArtiCodeApp
  - Disable commission automation in Supabase
  - Make profit/loss account user-scoped instead of system-wide
  - Ensure each user can have exactly one auto-created profit/loss account
*/

BEGIN;

-- 1) Remove old global trigger/function that auto-record commissions.
DROP TRIGGER IF EXISTS trigger_record_commission ON public.account_movements;
DROP FUNCTION IF EXISTS public.record_commission_to_profit_loss();

-- 2) Remove the old global "only one profit/loss account in the whole system" constraint.
ALTER TABLE public.customers
  DROP CONSTRAINT IF EXISTS only_one_profit_loss_account;

-- 3) Make sure the flag exists.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'customers'
      AND column_name = 'is_profit_loss_account'
  ) THEN
    ALTER TABLE public.customers
      ADD COLUMN is_profit_loss_account boolean NOT NULL DEFAULT false;
  END IF;
END $$;

-- 4) Create one-per-user uniqueness instead of one global account for the whole app.
DROP INDEX IF EXISTS public.customers_one_profit_loss_per_user_idx;
CREATE UNIQUE INDEX IF NOT EXISTS customers_one_profit_loss_per_user_idx
  ON public.customers (user_id)
  WHERE is_profit_loss_account = true;

-- 5) Make old global helper user-aware.
CREATE OR REPLACE FUNCTION public.get_profit_loss_account_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT c.id
  FROM public.customers c
  WHERE c.is_profit_loss_account = true
    AND c.user_id = auth.uid()
  ORDER BY c.created_at NULLS FIRST, c.id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.get_profit_loss_account_id(p_user_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT c.id
  FROM public.customers c
  WHERE c.is_profit_loss_account = true
    AND c.user_id = p_user_id
  ORDER BY c.created_at NULLS FIRST, c.id
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_profit_loss_account_id() IS
'Returns the current authenticated user''s profit/loss customer id.';

COMMENT ON FUNCTION public.get_profit_loss_account_id(uuid) IS
'Returns the specified user''s profit/loss customer id.';

-- 6) Helper to auto-create a private profit/loss account for a user if it does not exist.
CREATE OR REPLACE FUNCTION public.ensure_profit_loss_account_for_user(p_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id uuid;
  v_name text := 'الأرباح والخسائر';
  v_phone text;
BEGIN
  SELECT c.id
    INTO v_id
  FROM public.customers c
  WHERE c.user_id = p_user_id
    AND c.is_profit_loss_account = true
  ORDER BY c.created_at NULLS FIRST, c.id
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  v_phone := 'PROFIT_LOSS_' || replace(p_user_id::text, '-', '_');

  INSERT INTO public.customers (
    name,
    phone,
    user_id,
    is_profit_loss_account,
    created_at
  )
  VALUES (
    v_name,
    v_phone,
    p_user_id,
    true,
    now()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.ensure_profit_loss_account_for_user(uuid) IS
'Ensures that each user has exactly one private profit/loss customer.';

-- 7) Backfill: convert the old global/system profit-loss record into per-user records.
--    a) If there is an old global account with NULL user_id, turn it into a normal customer placeholder.
UPDATE public.customers
SET is_profit_loss_account = false,
    name = CASE WHEN name = 'الأرباح والخسائر' THEN 'الأرباح والخسائر (قديم)' ELSE name END
WHERE is_profit_loss_account = true
  AND user_id IS NULL;

--    b) Ensure every existing user who already has customers gets a private profit/loss account.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT c.user_id
    FROM public.customers c
    WHERE c.user_id IS NOT NULL
  LOOP
    PERFORM public.ensure_profit_loss_account_for_user(r.user_id);
  END LOOP;
END $$;

-- 8) Prevent duplicate profit/loss flags for the same user if old data exists.
WITH ranked AS (
  SELECT id,
         user_id,
         row_number() OVER (
           PARTITION BY user_id
           ORDER BY created_at NULLS FIRST, id
         ) AS rn
  FROM public.customers
  WHERE is_profit_loss_account = true
    AND user_id IS NOT NULL
)
UPDATE public.customers c
SET is_profit_loss_account = false
FROM ranked r
WHERE c.id = r.id
  AND r.rn > 1;

-- 9) Commission should no longer affect new accounting logic.
--    Keep the columns for compatibility, but default them to NULL and zero out any accidental auto-generated values later in app logic.
ALTER TABLE public.account_movements
  ALTER COLUMN commission DROP DEFAULT;

ALTER TABLE public.account_movements
  ALTER COLUMN commission_currency DROP DEFAULT;

-- Optional compatibility no-op: if any old migration or function recreates the trigger later,
-- this function will do nothing until the app fully removes old commission flows.
CREATE OR REPLACE FUNCTION public.record_commission_to_profit_loss()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_commission_to_profit_loss() IS
'Compatibility no-op. Commission auto-recording is disabled.';

COMMIT;
