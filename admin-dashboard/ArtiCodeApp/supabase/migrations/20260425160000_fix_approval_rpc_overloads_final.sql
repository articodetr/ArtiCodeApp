/*
  Final approval/rejection RPC overload cleanup for ArtiCodeApp.

  Problem fixed:
  PostgREST/Supabase RPC cannot choose between overloaded functions such as:
    public.approve_movement(p_movement_id uuid, p_user_name text)
    public.approve_movement(p_movement_id uuid, p_user_name text, p_user_id uuid DEFAULT ...)

  This migration removes every approve/reject overload and recreates ONLY the exact
  signatures used by the current app:
    approve_movement(uuid, text)
    reject_movement_with_reason(uuid, text, text)
    reject_movement(uuid, text, text)
*/

BEGIN;

-- ------------------------------------------------------------------
-- 1) Required columns used by approval workflow
-- ------------------------------------------------------------------
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS pending_approval boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS approval_status text DEFAULT 'approved',
  ADD COLUMN IF NOT EXISTS approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS approved_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS rejected_at timestamptz,
  ADD COLUMN IF NOT EXISTS rejected_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS reject_reason text,
  ADD COLUMN IF NOT EXISTS mirror_movement_id uuid,
  ADD COLUMN IF NOT EXISTS related_transfer_id uuid,
  ADD COLUMN IF NOT EXISTS related_commission_movement_id uuid,
  ADD COLUMN IF NOT EXISTS source_user_id uuid,
  ADD COLUMN IF NOT EXISTS created_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS created_by_user_name text,
  ADD COLUMN IF NOT EXISTS is_voided boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS void_type text,
  ADD COLUMN IF NOT EXISTS void_reason text;

UPDATE public.account_movements
SET approval_status = CASE
  WHEN COALESCE(pending_approval, false) THEN 'pending'
  ELSE 'approved'
END
WHERE approval_status IS NULL;

UPDATE public.account_movements
SET pending_approval = (approval_status = 'pending')
WHERE pending_approval IS DISTINCT FROM (approval_status = 'pending');

-- ------------------------------------------------------------------
-- 2) Approval status helper
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_movement_approval_status(
  p_approval_status text,
  p_pending_approval boolean DEFAULT false
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN NULLIF(trim(COALESCE(p_approval_status, '')), '') IN ('pending', 'approved', 'rejected')
      THEN NULLIF(trim(COALESCE(p_approval_status, '')), '')
    WHEN COALESCE(p_pending_approval, false) THEN 'pending'
    ELSE 'approved'
  END;
$$;

-- ------------------------------------------------------------------
-- 3) Remove every old overloaded approve/reject RPC version
-- ------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'approve_movement',
        'reject_movement_with_reason',
        'reject_movement'
      )
  LOOP
    EXECUTE format(
      'DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE',
      r.schema_name,
      r.function_name,
      r.args
    );
  END LOOP;
END $$;

-- ------------------------------------------------------------------
-- 4) Helper to get original + mirror + related rows together
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_approval_related_movement_ids(p_movement_id uuid)
RETURNS uuid[]
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH root AS (
    SELECT
      am.id,
      am.mirror_movement_id,
      am.related_transfer_id
    FROM public.account_movements am
    WHERE am.id = p_movement_id
  ),
  seeds AS (
    SELECT id FROM root
    UNION
    SELECT mirror_movement_id FROM root WHERE mirror_movement_id IS NOT NULL
    UNION
    SELECT related_transfer_id FROM root WHERE related_transfer_id IS NOT NULL
  ),
  expanded AS (
    SELECT id FROM seeds WHERE id IS NOT NULL
    UNION
    SELECT am.id
    FROM public.account_movements am
    WHERE am.mirror_movement_id IN (SELECT id FROM seeds WHERE id IS NOT NULL)
       OR am.related_transfer_id IN (SELECT id FROM seeds WHERE id IS NOT NULL)
       OR am.related_commission_movement_id IN (SELECT id FROM seeds WHERE id IS NOT NULL)
  )
  SELECT COALESCE(array_agg(DISTINCT id), ARRAY[p_movement_id]::uuid[])
  FROM expanded
  WHERE id IS NOT NULL;
$$;

-- ------------------------------------------------------------------
-- 5) Exact approve RPC used by the app: approve_movement(uuid, text)
-- ------------------------------------------------------------------
CREATE FUNCTION public.approve_movement(
  p_movement_id uuid,
  p_user_name text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_user_full_name text;
  v_movement record;
  v_related_ids uuid[];
  v_current_status text;
BEGIN
  SELECT a.id, COALESCE(NULLIF(trim(a.full_name), ''), a.user_name)
  INTO v_user_id, v_user_full_name
  FROM public.app_security a
  WHERE a.user_name = p_user_name
    AND COALESCE(a.is_active, true) = true
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT
    am.*,
    c.user_id AS customer_owner_id,
    c.linked_user_id AS customer_linked_user_id,
    c.name AS customer_name
  INTO v_movement
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  v_current_status := public.get_movement_approval_status(
    v_movement.approval_status,
    v_movement.pending_approval
  );

  IF v_current_status = 'approved' THEN
    RETURN json_build_object(
      'success', true,
      'message', 'الحركة معتمدة مسبقًا',
      'movement_id', p_movement_id,
      'status', 'approved'
    );
  END IF;

  IF v_current_status = 'rejected' OR COALESCE(v_movement.is_voided, false) = true THEN
    RAISE EXCEPTION 'لا يمكن قبول حركة مرفوضة أو ملغاة';
  END IF;

  IF NOT (
    v_movement.customer_owner_id = v_user_id
    OR v_movement.customer_linked_user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  IF COALESCE(v_movement.source_user_id, v_movement.created_by_user_id) = v_user_id THEN
    RAISE EXCEPTION 'لا يمكن لمنشئ الحركة اعتمادها بنفسه';
  END IF;

  v_related_ids := public.get_approval_related_movement_ids(p_movement_id);

  UPDATE public.account_movements
  SET
    approval_status = 'approved',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now(),
    rejected_by_user_id = NULL,
    rejected_at = NULL,
    reject_reason = NULL,
    is_voided = false,
    void_type = NULL,
    void_reason = NULL
  WHERE id = ANY(v_related_ids);

  DELETE FROM public.movement_notifications
  WHERE notification_type = 'approval_needed'
    AND movement_id = ANY(v_related_ids);

  UPDATE public.movement_notifications
  SET
    status = 'approved',
    is_read = true,
    action_required = false,
    acted_at = COALESCE(acted_at, now())
  WHERE movement_id = ANY(v_related_ids)
    AND notification_type IN ('movement_added', 'movement_approved');

  RETURN json_build_object(
    'success', true,
    'message', 'تم قبول الحركة بنجاح',
    'movement_id', p_movement_id,
    'movement_ids', v_related_ids,
    'approved_by', COALESCE(v_user_full_name, p_user_name),
    'status', 'approved'
  );
END;
$$;

-- ------------------------------------------------------------------
-- 6) Exact reject RPC used by the app: reject_movement_with_reason(uuid,text,text)
-- ------------------------------------------------------------------
CREATE FUNCTION public.reject_movement_with_reason(
  p_movement_id uuid,
  p_user_name text,
  p_reject_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_user_full_name text;
  v_movement record;
  v_related_ids uuid[];
  v_current_status text;
  v_reason text;
BEGIN
  v_reason := NULLIF(trim(COALESCE(p_reject_reason, '')), '');

  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'سبب الرفض مطلوب';
  END IF;

  SELECT a.id, COALESCE(NULLIF(trim(a.full_name), ''), a.user_name)
  INTO v_user_id, v_user_full_name
  FROM public.app_security a
  WHERE a.user_name = p_user_name
    AND COALESCE(a.is_active, true) = true
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT
    am.*,
    c.user_id AS customer_owner_id,
    c.linked_user_id AS customer_linked_user_id,
    c.name AS customer_name
  INTO v_movement
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  v_current_status := public.get_movement_approval_status(
    v_movement.approval_status,
    v_movement.pending_approval
  );

  IF v_current_status = 'rejected' THEN
    RETURN json_build_object(
      'success', true,
      'message', 'الحركة مرفوضة مسبقًا',
      'movement_id', p_movement_id,
      'status', 'rejected',
      'reject_reason', COALESCE(v_movement.reject_reason, v_reason)
    );
  END IF;

  IF v_current_status = 'approved' THEN
    RAISE EXCEPTION 'لا يمكن رفض حركة معتمدة مسبقًا';
  END IF;

  IF NOT (
    v_movement.customer_owner_id = v_user_id
    OR v_movement.customer_linked_user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  IF COALESCE(v_movement.source_user_id, v_movement.created_by_user_id) = v_user_id THEN
    RAISE EXCEPTION 'لا يمكن لمنشئ الحركة رفضها بنفسه';
  END IF;

  v_related_ids := public.get_approval_related_movement_ids(p_movement_id);

  UPDATE public.account_movements
  SET
    approval_status = 'rejected',
    pending_approval = false,
    rejected_by_user_id = v_user_id,
    rejected_at = now(),
    approved_by_user_id = NULL,
    approved_at = NULL,
    reject_reason = v_reason,
    is_voided = true,
    void_type = 'rejected',
    void_reason = v_reason
  WHERE id = ANY(v_related_ids);

  DELETE FROM public.movement_notifications
  WHERE notification_type = 'approval_needed'
    AND movement_id = ANY(v_related_ids);

  UPDATE public.movement_notifications
  SET
    status = 'rejected',
    is_read = true,
    action_required = false,
    acted_at = COALESCE(acted_at, now()),
    extra_data = COALESCE(extra_data, '{}'::jsonb) || jsonb_build_object('reject_reason', v_reason)
  WHERE movement_id = ANY(v_related_ids)
    AND notification_type IN ('movement_added', 'movement_rejected');

  RETURN json_build_object(
    'success', true,
    'message', 'تم رفض الحركة',
    'movement_id', p_movement_id,
    'movement_ids', v_related_ids,
    'rejected_by', COALESCE(v_user_full_name, p_user_name),
    'status', 'rejected',
    'reject_reason', v_reason
  );
END;
$$;

-- Compatibility wrapper if any older screen calls reject_movement.
CREATE FUNCTION public.reject_movement(
  p_movement_id uuid,
  p_user_name text,
  p_reject_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.reject_movement_with_reason(p_movement_id, p_user_name, p_reject_reason);
END;
$$;

-- ------------------------------------------------------------------
-- 7) Grants and schema cache refresh
-- ------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.get_approval_related_movement_ids(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_movement(uuid, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_movement_with_reason(uuid, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_movement(uuid, text, text) TO anon, authenticated, service_role;

COMMIT;

-- Ask PostgREST/Supabase API to reload the schema cache so RPC ambiguity disappears immediately.
NOTIFY pgrst, 'reload schema';

SELECT 'approval_rpc_overloads_fixed_final' AS status;
