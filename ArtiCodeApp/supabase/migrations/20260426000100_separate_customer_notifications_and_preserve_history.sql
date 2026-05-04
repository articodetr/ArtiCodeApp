/*
  Separate customer notifications from general notifications and preserve history.

  What this migration does:
  1. Adds soft-delete columns so a user can hide a notification without losing audit history.
  2. Adds customer_id snapshot to movement_notifications and backfills it from account_movements.
  3. Replaces approval/rejection RPCs so approval_needed notifications are NOT deleted after a decision.
     They are updated to approved/rejected and remain visible until the user deletes them manually.
*/

BEGIN;

ALTER TABLE IF EXISTS public.movement_notifications
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS customer_id uuid;

UPDATE public.movement_notifications mn
SET customer_id = am.customer_id
FROM public.account_movements am
WHERE mn.movement_id = am.id
  AND mn.customer_id IS NULL;

CREATE INDEX IF NOT EXISTS movement_notifications_visible_user_idx
  ON public.movement_notifications (user_id, created_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS movement_notifications_customer_visible_idx
  ON public.movement_notifications (user_id, customer_id, created_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS movement_notifications_customer_id_idx
  ON public.movement_notifications (customer_id)
  WHERE customer_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.set_movement_notification_customer_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.customer_id IS NULL AND NEW.movement_id IS NOT NULL THEN
    SELECT am.customer_id
    INTO NEW.customer_id
    FROM public.account_movements am
    WHERE am.id = NEW.movement_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_movement_notification_customer_id_trigger ON public.movement_notifications;
CREATE TRIGGER set_movement_notification_customer_id_trigger
BEFORE INSERT OR UPDATE OF movement_id, customer_id
ON public.movement_notifications
FOR EACH ROW
EXECUTE FUNCTION public.set_movement_notification_customer_id();

DROP FUNCTION IF EXISTS public.approve_movement(uuid, text) CASCADE;
DROP FUNCTION IF EXISTS public.reject_movement_with_reason(uuid, text, text) CASCADE;
DROP FUNCTION IF EXISTS public.reject_movement(uuid, text, text) CASCADE;

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
  v_related_ids uuid[];
  v_pending_count integer := 0;
  v_rejected_or_voided_count integer := 0;
  v_permission_count integer := 0;
  v_creator_count integer := 0;
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

  IF NOT EXISTS (SELECT 1 FROM public.account_movements WHERE id = p_movement_id) THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  v_related_ids := public.get_approval_related_movement_ids(p_movement_id);

  SELECT COUNT(*)
  INTO v_permission_count
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = ANY(v_related_ids)
    AND (c.user_id = v_user_id OR c.linked_user_id = v_user_id);

  IF v_permission_count = 0 THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT COUNT(*)
  INTO v_creator_count
  FROM public.account_movements am
  WHERE am.id = ANY(v_related_ids)
    AND COALESCE(am.source_user_id, am.created_by_user_id) IS DISTINCT FROM v_user_id;

  IF v_creator_count = 0 THEN
    RAISE EXCEPTION 'لا يمكن لمنشئ الحركة اعتمادها بنفسه';
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE public.get_movement_approval_status(approval_status, pending_approval) = 'pending'),
    COUNT(*) FILTER (
      WHERE public.get_movement_approval_status(approval_status, pending_approval) = 'rejected'
         OR COALESCE(is_voided, false) = true
    )
  INTO v_pending_count, v_rejected_or_voided_count
  FROM public.account_movements
  WHERE id = ANY(v_related_ids);

  IF v_rejected_or_voided_count > 0 THEN
    RAISE EXCEPTION 'لا يمكن قبول حركة مرفوضة أو ملغاة';
  END IF;

  UPDATE public.account_movements
  SET
    approval_status = 'approved',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = COALESCE(approved_at, now()),
    rejected_by_user_id = NULL,
    rejected_at = NULL,
    reject_reason = NULL,
    is_voided = false,
    void_type = NULL,
    void_reason = NULL
  WHERE id = ANY(v_related_ids)
    AND public.get_movement_approval_status(approval_status, pending_approval) <> 'approved';

  UPDATE public.movement_notifications mn
  SET
    status = 'approved',
    is_read = true,
    action_required = false,
    acted_at = COALESCE(acted_at, now()),
    customer_id = COALESCE(mn.customer_id, am.customer_id),
    extra_data = COALESCE(mn.extra_data, '{}'::jsonb)
      || jsonb_build_object('approval_status', 'approved', 'approved_by', COALESCE(v_user_full_name, p_user_name))
  FROM public.account_movements am
  WHERE mn.movement_id = am.id
    AND mn.movement_id = ANY(v_related_ids)
    AND mn.notification_type IN ('approval_needed', 'movement_added', 'movement_approved');

  RETURN json_build_object(
    'success', true,
    'message', CASE WHEN v_pending_count = 0 THEN 'الحركة معتمدة مسبقًا' ELSE 'تم قبول الحركة بنجاح' END,
    'movement_id', p_movement_id,
    'movement_ids', v_related_ids,
    'approved_by', COALESCE(v_user_full_name, p_user_name),
    'status', 'approved'
  );
END;
$$;

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
  v_reason text;
  v_related_ids uuid[];
  v_permission_count integer := 0;
  v_creator_count integer := 0;
  v_approved_count integer := 0;
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

  IF NOT EXISTS (SELECT 1 FROM public.account_movements WHERE id = p_movement_id) THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  v_related_ids := public.get_approval_related_movement_ids(p_movement_id);

  SELECT COUNT(*)
  INTO v_permission_count
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = ANY(v_related_ids)
    AND (c.user_id = v_user_id OR c.linked_user_id = v_user_id);

  IF v_permission_count = 0 THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT COUNT(*)
  INTO v_creator_count
  FROM public.account_movements am
  WHERE am.id = ANY(v_related_ids)
    AND COALESCE(am.source_user_id, am.created_by_user_id) IS DISTINCT FROM v_user_id;

  IF v_creator_count = 0 THEN
    RAISE EXCEPTION 'لا يمكن لمنشئ الحركة رفضها بنفسه';
  END IF;

  SELECT COUNT(*)
  INTO v_approved_count
  FROM public.account_movements
  WHERE id = ANY(v_related_ids)
    AND public.get_movement_approval_status(approval_status, pending_approval) = 'approved';

  IF v_approved_count > 0 THEN
    RAISE EXCEPTION 'لا يمكن رفض حركة معتمدة مسبقًا';
  END IF;

  UPDATE public.account_movements
  SET
    approval_status = 'rejected',
    pending_approval = false,
    rejected_by_user_id = v_user_id,
    rejected_at = COALESCE(rejected_at, now()),
    approved_by_user_id = NULL,
    approved_at = NULL,
    reject_reason = v_reason,
    is_voided = true,
    void_type = 'rejected',
    void_reason = v_reason
  WHERE id = ANY(v_related_ids);

  UPDATE public.movement_notifications mn
  SET
    status = 'rejected',
    is_read = true,
    action_required = false,
    acted_at = COALESCE(acted_at, now()),
    customer_id = COALESCE(mn.customer_id, am.customer_id),
    extra_data = COALESCE(mn.extra_data, '{}'::jsonb)
      || jsonb_build_object(
        'approval_status', 'rejected',
        'reject_reason', v_reason,
        'rejected_by', COALESCE(v_user_full_name, p_user_name)
      )
  FROM public.account_movements am
  WHERE mn.movement_id = am.id
    AND mn.movement_id = ANY(v_related_ids)
    AND mn.notification_type IN ('approval_needed', 'movement_added', 'movement_rejected');

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

GRANT EXECUTE ON FUNCTION public.set_movement_notification_customer_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_movement(uuid, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_movement_with_reason(uuid, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_movement(uuid, text, text) TO anon, authenticated, service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'customer_notifications_separated_and_history_preserved' AS status;
