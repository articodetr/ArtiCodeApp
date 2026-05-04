/*
  Persist notifications + keep pending visible until decided + keep history
  after a decision. Consolidates the creator-side notification into a single
  row per movement so the UI does not show two cards for the same event.

  What this migration does
  ------------------------
  1) Removes the redundant "movement_added" notification that
     insert_movement_with_user creates for the creator. The newer trigger
     trg_ensure_creator_pending_movement_notification already inserts an
     approval_needed (action_required = false) row for the creator, with a
     proper status field that flips between 'pending' / 'approved' /
     'rejected'. Having both rows produced two cards for the same logical
     event in the creator's notifications list.

  2) Re-asserts approve_movement and reject_movement_with_reason in their
     non-deleting form. They UPDATE notifications instead of deleting them so
     the row stays visible after a decision is made. Status flips from
     'pending' to 'approved' / 'rejected' on BOTH sides because both rows
     belong to get_approval_related_movement_ids(...).

  3) Cleans up legacy duplicate notifications already in the database:
     - Deletes 'movement_added' rows for the creator when an
       'approval_needed' row already exists for the same (user, movement).
     - Backfills status on legacy 'movement_added' creator rows so their
       status reflects the underlying movement (pending vs approved vs
       rejected), which is what the pending tab and the dedupe key read.

  Safe behavior preserved
  -----------------------
  - The counterparty still receives the actionable approval_needed
    notification through create_mirror_movement_v2 (unchanged).
  - The previous self-duplicate fix (mirror-side creator skip) is unchanged.
  - User-driven soft-delete (deleted_at) is unchanged.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) insert_movement_with_user: stop emitting the redundant movement_added
--    creator notification. The trigger handles the creator side now.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.insert_movement_with_user(
  p_user_name text,
  p_customer_id uuid,
  p_movement_type text,
  p_amount numeric,
  p_currency text,
  p_notes text DEFAULT NULL,
  p_sender_name text DEFAULT NULL,
  p_beneficiary_name text DEFAULT NULL,
  p_commission numeric DEFAULT NULL,
  p_commission_currency text DEFAULT NULL,
  p_commission_recipient_id uuid DEFAULT NULL
)
RETURNS TABLE(
  id uuid,
  movement_number text,
  receipt_number text,
  customer_id uuid,
  movement_type text,
  amount numeric,
  currency text,
  commission numeric,
  commission_currency text,
  created_at timestamptz,
  created_by_user_name text,
  pending_approval boolean,
  approval_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_user_full_name text;
  v_customer record;
  v_movement_id uuid;
  v_movement_number text;
  v_receipt_number text;
  v_needs_approval boolean := false;
  v_approval_status text := 'approved';
  v_notes text;
BEGIN
  SELECT u.id, u.full_name
    INTO v_user_id, v_user_full_name
  FROM public.app_security u
  WHERE u.user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT *
    INTO v_customer
  FROM public.customers
  WHERE customers.id = p_customer_id;

  IF v_customer IS NULL THEN
    RAISE EXCEPTION 'Customer not found: %', p_customer_id;
  END IF;

  v_notes := NULLIF(trim(COALESCE(p_notes, '')), '');
  IF v_notes IS NULL THEN
    RAISE EXCEPTION 'الملاحظة مطلوبة';
  END IF;

  IF v_customer.linked_user_id IS NOT NULL THEN
    v_needs_approval := true;
    v_approval_status := 'pending';
  END IF;

  v_movement_number := public.generate_movement_number();

  INSERT INTO public.account_movements (
    movement_number,
    customer_id,
    movement_type,
    amount,
    currency,
    notes,
    sender_name,
    beneficiary_name,
    commission,
    commission_currency,
    commission_recipient_id,
    source_user_id,
    created_by_user_id,
    created_by_user_name,
    pending_approval,
    approval_status,
    is_voided
  ) VALUES (
    v_movement_number,
    p_customer_id,
    p_movement_type,
    p_amount,
    p_currency,
    v_notes,
    p_sender_name,
    p_beneficiary_name,
    p_commission,
    p_commission_currency,
    p_commission_recipient_id,
    v_user_id,
    v_user_id,
    v_user_full_name,
    v_needs_approval,
    v_approval_status,
    false
  )
  RETURNING
    account_movements.id,
    account_movements.movement_number,
    account_movements.receipt_number
  INTO v_movement_id, v_movement_number, v_receipt_number;

  -- NOTE:
  --   No movement_added notification is emitted here on purpose.
  --   trg_ensure_creator_pending_movement_notification already inserts a
  --   single approval_needed row (action_required = false) for the creator
  --   when the movement is pending, and updates it to 'approved' / 'rejected'
  --   when the underlying movement transitions. That keeps the creator's
  --   list to one card per logical event with a status that reflects reality.

  RETURN QUERY
  SELECT
    v_movement_id,
    v_movement_number,
    v_receipt_number,
    p_customer_id,
    p_movement_type,
    p_amount,
    p_currency,
    p_commission,
    p_commission_currency,
    now(),
    v_user_full_name,
    v_needs_approval,
    v_approval_status;
END;
$$;

GRANT EXECUTE ON FUNCTION public.insert_movement_with_user(
  text, uuid, text, numeric, text, text, text, text, numeric, text, uuid
) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) approve_movement: re-asserted as non-deleting and pair-aware. Same
--    behavior as 20260426000200 but written here so any newer migration that
--    accidentally regressed to a DELETE path is overridden.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_movement(
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
     SET approval_status = 'approved',
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

  -- Persist all related notifications with the new status. Never delete.
  UPDATE public.movement_notifications
     SET status = 'approved',
         is_read = true,
         action_required = false,
         acted_at = COALESCE(acted_at, now()),
         extra_data = COALESCE(extra_data, '{}'::jsonb)
           || jsonb_build_object(
             'approval_status', 'approved',
             'requires_action', false,
             'approved_by', COALESCE(v_user_full_name, p_user_name),
             'approved_by_user_id', v_user_id
           )
   WHERE movement_id = ANY(v_related_ids)
     AND notification_type IN ('approval_needed', 'movement_added', 'movement_approved');

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

GRANT EXECUTE ON FUNCTION public.approve_movement(uuid, text)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3) reject_movement_with_reason: also non-deleting and pair-aware.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_movement_with_reason(
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
     SET approval_status = 'rejected',
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

  UPDATE public.movement_notifications
     SET status = 'rejected',
         is_read = true,
         action_required = false,
         acted_at = COALESCE(acted_at, now()),
         extra_data = COALESCE(extra_data, '{}'::jsonb)
           || jsonb_build_object(
             'approval_status', 'rejected',
             'requires_action', false,
             'reject_reason', v_reason,
             'rejected_by', COALESCE(v_user_full_name, p_user_name),
             'rejected_by_user_id', v_user_id
           )
   WHERE movement_id = ANY(v_related_ids)
     AND notification_type IN ('approval_needed', 'movement_added', 'movement_rejected');

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

CREATE OR REPLACE FUNCTION public.reject_movement(
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

GRANT EXECUTE ON FUNCTION public.reject_movement_with_reason(uuid, text, text)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_movement(uuid, text, text)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) Backfill status on legacy creator-side rows so that the pending tab
--    and the in-app dedupe see them with the correct lifecycle state.
-- ---------------------------------------------------------------------------

-- 4.1 Mark legacy movement_added rows as approved when the underlying
--     movement is approved.
UPDATE public.movement_notifications mn
   SET status = 'approved',
       is_read = true,
       action_required = false,
       acted_at = COALESCE(mn.acted_at, am.approved_at, now()),
       extra_data = COALESCE(mn.extra_data, '{}'::jsonb)
         || jsonb_build_object('approval_status', 'approved', 'requires_action', false)
  FROM public.account_movements am
 WHERE mn.movement_id = am.id
   AND mn.notification_type IN ('movement_added', 'approval_needed', 'movement_approved')
   AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
   AND COALESCE(mn.status, '') <> 'approved';

-- 4.2 Mark legacy notifications as rejected when the underlying movement is
--     rejected.
UPDATE public.movement_notifications mn
   SET status = 'rejected',
       is_read = true,
       action_required = false,
       acted_at = COALESCE(mn.acted_at, am.rejected_at, now()),
       extra_data = COALESCE(mn.extra_data, '{}'::jsonb)
         || jsonb_build_object(
           'approval_status', 'rejected',
           'requires_action', false,
           'reject_reason', COALESCE(am.reject_reason, am.void_reason, mn.extra_data->>'reject_reason')
         )
  FROM public.account_movements am
 WHERE mn.movement_id = am.id
   AND mn.notification_type IN ('movement_added', 'approval_needed', 'movement_rejected')
   AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'rejected'
   AND COALESCE(mn.status, '') <> 'rejected';

-- 4.3 For movements still pending, ensure the creator's row reads 'pending'.
UPDATE public.movement_notifications mn
   SET status = 'pending',
       extra_data = COALESCE(mn.extra_data, '{}'::jsonb)
         || jsonb_build_object('approval_status', 'pending')
  FROM public.account_movements am,
       public.customers c
 WHERE mn.movement_id = am.id
   AND am.customer_id = c.id
   AND mn.notification_type IN ('movement_added', 'approval_needed')
   AND mn.user_id = c.user_id
   AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'pending'
   AND COALESCE(mn.status, '') NOT IN ('pending');

-- ---------------------------------------------------------------------------
-- 5) Drop legacy duplicate movement_added rows for the creator when an
--    approval_needed row already exists for the same (user, movement).
--    These are the rows that produced two cards for the same logical event.
-- ---------------------------------------------------------------------------
DELETE FROM public.movement_notifications mn
USING public.movement_notifications other
WHERE mn.notification_type = 'movement_added'
  AND other.notification_type = 'approval_needed'
  AND other.user_id = mn.user_id
  AND other.movement_id = mn.movement_id
  AND mn.deleted_at IS NULL;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'notifications_persistence_and_consolidation_applied' AS status;