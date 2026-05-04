/*
  ArtiCodeApp - Pair Approval + Statistics Dedup Fix

  Fixes two related problems:
  1) Approval RPC could return success when the passed movement was already approved,
     while the paired/mirror movement was still pending. It now approves/rejects the
     whole logical pair together and is safe to call from either side.
  2) Statistics/cash flow counted both the original movement and its mirror for the
     same user when scoped customers included both user_id and linked_user_id.
     Approved statistics now use the user's own ledger rows only, while pending
     approval statistics still look at linked rows and notifications.

  Safe: does not delete movements, customers, users, or notifications.
*/

-- -----------------------------------------------------------------------------
-- 1) Compatibility columns
-- -----------------------------------------------------------------------------

ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS is_profit_loss_account boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS linked_user_id uuid,
  ADD COLUMN IF NOT EXISTS user_id uuid;

ALTER TABLE public.account_movements
  ADD COLUMN IF NOT EXISTS commission numeric DEFAULT 0,
  ADD COLUMN IF NOT EXISTS commission_currency text,
  ADD COLUMN IF NOT EXISTS related_transfer_id uuid,
  ADD COLUMN IF NOT EXISTS related_commission_movement_id uuid,
  ADD COLUMN IF NOT EXISTS mirror_movement_id uuid,
  ADD COLUMN IF NOT EXISTS is_commission_movement boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS pending_approval boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS approval_status text,
  ADD COLUMN IF NOT EXISTS approved_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS rejected_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS rejected_at timestamptz,
  ADD COLUMN IF NOT EXISTS reject_reason text,
  ADD COLUMN IF NOT EXISTS is_voided boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS void_type text,
  ADD COLUMN IF NOT EXISTS void_reason text,
  ADD COLUMN IF NOT EXISTS created_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS created_by_user_name text,
  ADD COLUMN IF NOT EXISTS source_user_id uuid,
  ADD COLUMN IF NOT EXISTS from_customer_id uuid,
  ADD COLUMN IF NOT EXISTS to_customer_id uuid;

UPDATE public.account_movements
SET approval_status = CASE
  WHEN COALESCE(pending_approval, false) = true THEN 'pending'
  ELSE 'approved'
END
WHERE approval_status IS NULL;

UPDATE public.account_movements
SET pending_approval = (approval_status = 'pending')
WHERE pending_approval IS DISTINCT FROM (approval_status = 'pending');

CREATE INDEX IF NOT EXISTS account_movements_pair_status_idx
  ON public.account_movements (mirror_movement_id, approval_status, pending_approval, is_voided);

CREATE INDEX IF NOT EXISTS account_movements_customer_status_idx
  ON public.account_movements (customer_id, approval_status, pending_approval, is_voided);

CREATE INDEX IF NOT EXISTS movement_notifications_action_idx
  ON public.movement_notifications (user_id, movement_id, notification_type)
  WHERE movement_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2) Helper: normalize approval status
-- -----------------------------------------------------------------------------

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

-- -----------------------------------------------------------------------------
-- 3) Remove overloaded approval/rejection/statistics RPCs
-- -----------------------------------------------------------------------------

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
        'reject_movement',
        'get_approval_related_movement_ids',
        'get_app_statistics',
        'get_app_period_statistics',
        'get_app_statistics_debug'
      )
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE', r.schema_name, r.function_name, r.args);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 4) Helper: collect all rows in the same logical movement pair
-- -----------------------------------------------------------------------------

CREATE FUNCTION public.get_approval_related_movement_ids(p_movement_id uuid)
RETURNS uuid[]
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH RECURSIVE related_ids(id) AS (
    SELECT p_movement_id
    UNION
    SELECT am.mirror_movement_id
    FROM public.account_movements am
    JOIN related_ids r ON r.id = am.id
    WHERE am.mirror_movement_id IS NOT NULL
    UNION
    SELECT am.related_transfer_id
    FROM public.account_movements am
    JOIN related_ids r ON r.id = am.id
    WHERE am.related_transfer_id IS NOT NULL
    UNION
    SELECT am.related_commission_movement_id
    FROM public.account_movements am
    JOIN related_ids r ON r.id = am.id
    WHERE am.related_commission_movement_id IS NOT NULL
    UNION
    SELECT am.id
    FROM public.account_movements am
    JOIN related_ids r
      ON am.mirror_movement_id = r.id
      OR am.related_transfer_id = r.id
      OR am.related_commission_movement_id = r.id
  )
  SELECT COALESCE(array_agg(DISTINCT id), ARRAY[p_movement_id]::uuid[])
  FROM related_ids
  WHERE id IS NOT NULL;
$$;

-- -----------------------------------------------------------------------------
-- 5) Approval RPC: approve the whole pair, not only the passed row
-- -----------------------------------------------------------------------------

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

  -- Idempotent: if the passed row is already approved but the pair still has
  -- pending rows, we still approve the pending pair rows. If nothing is pending,
  -- return success without creating an error.
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
    'message', CASE WHEN v_pending_count = 0 THEN 'الحركة معتمدة مسبقًا' ELSE 'تم قبول الحركة بنجاح' END,
    'movement_id', p_movement_id,
    'movement_ids', v_related_ids,
    'approved_by', COALESCE(v_user_full_name, p_user_name),
    'status', 'approved'
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 6) Rejection RPC: reject the whole pair safely
-- -----------------------------------------------------------------------------

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

-- -----------------------------------------------------------------------------
-- 7) Period statistics: use the user's own ledger rows for approved statistics
-- -----------------------------------------------------------------------------

CREATE FUNCTION public.get_app_period_statistics(
  p_user_id uuid,
  p_start_date date,
  p_end_date date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start timestamptz := p_start_date::timestamptz;
  v_end timestamptz := (p_end_date + 1)::timestamptz;
  v_role text;
  v_result jsonb;
BEGIN
  SELECT role INTO v_role
  FROM public.app_security
  WHERE id = p_user_id
  LIMIT 1;

  WITH visible_customers AS (
    SELECT c.*
    FROM public.customers c
    WHERE (v_role = 'admin' OR c.user_id = p_user_id)
      AND COALESCE(c.is_profit_loss_account, false) = false
      AND c.phone IS DISTINCT FROM 'PROFIT_LOSS_ACCOUNT'
  ),
  period_transactions AS (
    SELECT t.*
    FROM public.transactions t
    JOIN visible_customers c ON c.id = t.customer_id
    WHERE COALESCE(t.status, 'completed') = 'completed'
      AND t.created_at >= v_start
      AND t.created_at < v_end
  ),
  period_movements AS (
    SELECT am.*
    FROM public.account_movements am
    JOIN visible_customers c ON c.id = am.customer_id
    WHERE am.created_at >= v_start
      AND am.created_at < v_end
      AND COALESCE(am.is_commission_movement, false) = false
      AND COALESCE(am.is_voided, false) = false
      AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
      AND (
        v_role <> 'admin'
        OR am.mirror_movement_id IS NULL
        OR am.id::text < am.mirror_movement_id::text
      )
  ),
  period_commissions AS (
    SELECT COALESCE(NULLIF(am.commission_currency, ''), am.currency) AS currency, COALESCE(am.commission, 0) AS amount
    FROM period_movements am
    WHERE COALESCE(am.commission, 0) > 0
    UNION ALL
    SELECT am.currency, COALESCE(am.amount, 0) AS amount
    FROM public.account_movements am
    JOIN visible_customers c ON c.id = am.customer_id
    WHERE am.created_at >= v_start
      AND am.created_at < v_end
      AND COALESCE(am.is_commission_movement, false) = true
      AND COALESCE(am.is_voided, false) = false
      AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
  )
  SELECT jsonb_build_object(
    'transactions', (SELECT COUNT(*) FROM period_transactions),
    'movements', (SELECT COUNT(*) FROM period_movements),
    'commissionMovements', (SELECT COUNT(*) FROM period_commissions),
    'transactionAmount', COALESCE((SELECT SUM(amount_sent) FROM period_transactions), 0),
    'movementAmount', COALESCE((SELECT SUM(amount) FROM period_movements), 0),
    'commissionAmount', COALESCE((SELECT SUM(amount) FROM period_commissions), 0),
    'transactionAmountsByCurrency', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('currency', currency_sent, 'amount', amount) ORDER BY amount DESC)
      FROM (
        SELECT currency_sent, SUM(amount_sent) AS amount
        FROM period_transactions
        GROUP BY currency_sent
      ) s
    ), '[]'::jsonb),
    'movementAmountsByCurrency', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
      FROM (
        SELECT currency, SUM(amount) AS amount
        FROM period_movements
        GROUP BY currency
      ) s
    ), '[]'::jsonb),
    'commissionAmountsByCurrency', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
      FROM (
        SELECT currency, SUM(amount) AS amount
        FROM period_commissions
        GROUP BY currency
      ) s
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 8) Main statistics: approved cash flow is counted from the user's own ledger
-- -----------------------------------------------------------------------------

CREATE FUNCTION public.get_app_statistics(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today date := CURRENT_DATE;
  v_yesterday date := CURRENT_DATE - 1;
  v_week_start date := CURRENT_DATE - 7;
  v_month_start date := CURRENT_DATE - 30;
  v_role text;
  v_result jsonb;
BEGIN
  SELECT role INTO v_role
  FROM public.app_security
  WHERE id = p_user_id
  LIMIT 1;

  WITH approval_scope_customers AS (
    SELECT c.*
    FROM public.customers c
    WHERE v_role = 'admin'
       OR c.user_id = p_user_id
       OR c.linked_user_id = p_user_id
       OR c.id IN (
         SELECT am.customer_id
         FROM public.account_movements am
         JOIN public.movement_notifications mn ON mn.movement_id = am.id
         WHERE mn.user_id = p_user_id
       )
  ),
  visible_customers AS (
    SELECT c.*
    FROM public.customers c
    WHERE (v_role = 'admin' OR c.user_id = p_user_id)
      AND COALESCE(c.is_profit_loss_account, false) = false
      AND c.phone IS DISTINCT FROM 'PROFIT_LOSS_ACCOUNT'
  ),
  scoped_transactions AS (
    SELECT t.*
    FROM public.transactions t
    JOIN visible_customers c ON c.id = t.customer_id
    WHERE COALESCE(t.status, 'completed') = 'completed'
  ),
  approval_scope_movements AS (
    SELECT
      am.*,
      c.name AS customer_name,
      c.phone AS customer_phone,
      c.user_id AS customer_user_id,
      c.linked_user_id AS customer_linked_user_id,
      COALESCE(c.is_profit_loss_account, false) AS customer_is_profit_loss_account,
      public.get_movement_approval_status(am.approval_status, am.pending_approval) AS normalized_status,
      COALESCE(am.is_voided, false) AS normalized_voided,
      COALESCE(am.is_commission_movement, false) AS normalized_commission,
      CASE
        WHEN am.mirror_movement_id IS NOT NULL THEN LEAST(am.id::text, am.mirror_movement_id::text)
        ELSE am.id::text
      END AS logical_pair_key
    FROM public.account_movements am
    JOIN approval_scope_customers c ON c.id = am.customer_id
  ),
  visible_movements AS (
    SELECT
      am.*,
      c.name AS customer_name,
      c.phone AS customer_phone,
      c.user_id AS customer_user_id,
      c.linked_user_id AS customer_linked_user_id,
      COALESCE(c.is_profit_loss_account, false) AS customer_is_profit_loss_account,
      public.get_movement_approval_status(am.approval_status, am.pending_approval) AS normalized_status,
      COALESCE(am.is_voided, false) AS normalized_voided,
      COALESCE(am.is_commission_movement, false) AS normalized_commission,
      CASE
        WHEN am.mirror_movement_id IS NOT NULL THEN LEAST(am.id::text, am.mirror_movement_id::text)
        ELSE am.id::text
      END AS logical_pair_key
    FROM public.account_movements am
    JOIN visible_customers c ON c.id = am.customer_id
    WHERE v_role <> 'admin'
       OR am.mirror_movement_id IS NULL
       OR am.id::text < am.mirror_movement_id::text
  ),
  visible_non_commission_movements AS (
    SELECT *
    FROM visible_movements
    WHERE normalized_commission = false
      AND normalized_voided = false
      AND currency IS NOT NULL
  ),
  approved_customer_movements AS (
    SELECT *
    FROM visible_non_commission_movements
    WHERE normalized_status = 'approved'
  ),
  pending_scope_movements_raw AS (
    SELECT *
    FROM approval_scope_movements
    WHERE normalized_commission = false
      AND normalized_voided = false
      AND currency IS NOT NULL
      AND normalized_status = 'pending'
  ),
  pending_customer_movements AS (
    SELECT *
    FROM (
      SELECT
        p.*,
        row_number() OVER (
          PARTITION BY p.logical_pair_key
          ORDER BY
            CASE WHEN p.id IN (
              SELECT movement_id
              FROM public.movement_notifications
              WHERE user_id = p_user_id
                AND notification_type = 'approval_needed'
                AND COALESCE(action_required, true) = true
            ) THEN 0 ELSE 1 END,
            CASE WHEN p.customer_user_id = p_user_id THEN 0 ELSE 1 END,
            p.created_at DESC
        ) AS rn
      FROM pending_scope_movements_raw p
    ) ranked
    WHERE rn = 1
  ),
  balance_by_customer_currency AS (
    SELECT
      customer_id,
      customer_name,
      customer_phone,
      customer_user_id,
      customer_linked_user_id,
      currency,
      SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE 0 END) AS total_incoming,
      SUM(CASE WHEN movement_type = 'outgoing' THEN amount ELSE 0 END) AS total_outgoing,
      SUM(CASE
        WHEN movement_type = 'incoming' THEN amount
        WHEN movement_type = 'outgoing' THEN -amount
        ELSE 0
      END) AS balance
    FROM approved_customer_movements
    GROUP BY customer_id, customer_name, customer_phone, customer_user_id, customer_linked_user_id, currency
  ),
  currency_balances AS (
    SELECT currency, SUM(total_incoming) AS total_incoming, SUM(total_outgoing) AS total_outgoing, SUM(balance) AS balance
    FROM balance_by_customer_currency
    GROUP BY currency
  ),
  owed_to_us AS (
    SELECT currency, ABS(SUM(balance)) AS amount
    FROM balance_by_customer_currency
    WHERE balance < 0
    GROUP BY currency
  ),
  we_owe AS (
    SELECT currency, SUM(balance) AS amount
    FROM balance_by_customer_currency
    WHERE balance > 0
    GROUP BY currency
  ),
  cash_flow_currencies AS (
    SELECT currency FROM visible_non_commission_movements WHERE currency IS NOT NULL
    UNION
    SELECT currency FROM pending_customer_movements WHERE currency IS NOT NULL
  ),
  cash_flow AS (
    SELECT
      cur.currency,
      COALESCE(SUM(CASE WHEN vm.normalized_status = 'approved' AND vm.movement_type = 'incoming' THEN vm.amount ELSE 0 END), 0) AS total_received,
      COALESCE(SUM(CASE WHEN vm.normalized_status = 'approved' AND vm.movement_type = 'outgoing' THEN vm.amount ELSE 0 END), 0) AS total_paid,
      COALESCE(SUM(CASE WHEN vm.normalized_status = 'approved' AND vm.movement_type = 'incoming'
        AND (vm.related_transfer_id IS NOT NULL OR vm.mirror_movement_id IS NOT NULL)
        AND vm.from_customer_id IS NULL AND vm.to_customer_id IS NULL THEN vm.amount ELSE 0 END), 0) AS linked_received,
      COALESCE(SUM(CASE WHEN vm.normalized_status = 'approved' AND vm.movement_type = 'outgoing'
        AND (vm.related_transfer_id IS NOT NULL OR vm.mirror_movement_id IS NOT NULL)
        AND vm.from_customer_id IS NULL AND vm.to_customer_id IS NULL THEN vm.amount ELSE 0 END), 0) AS linked_paid,
      COALESCE(SUM(CASE WHEN vm.normalized_status = 'approved' AND vm.movement_type = 'incoming'
        AND vm.related_transfer_id IS NULL AND vm.mirror_movement_id IS NULL
        AND vm.from_customer_id IS NULL AND vm.to_customer_id IS NULL THEN vm.amount ELSE 0 END), 0) AS direct_received,
      COALESCE(SUM(CASE WHEN vm.normalized_status = 'approved' AND vm.movement_type = 'outgoing'
        AND vm.related_transfer_id IS NULL AND vm.mirror_movement_id IS NULL
        AND vm.from_customer_id IS NULL AND vm.to_customer_id IS NULL THEN vm.amount ELSE 0 END), 0) AS direct_paid,
      COALESCE((SELECT SUM(pm.amount) FROM pending_customer_movements pm WHERE pm.currency = cur.currency), 0) AS pending_amount,
      COALESCE((SELECT COUNT(*) FROM pending_customer_movements pm WHERE pm.currency = cur.currency), 0) AS pending_count,
      COALESCE(SUM(CASE WHEN vm.from_customer_id IS NOT NULL OR vm.to_customer_id IS NOT NULL THEN vm.amount ELSE 0 END), 0) AS internal_transfer_amount,
      COUNT(vm.id) FILTER (WHERE vm.from_customer_id IS NOT NULL OR vm.to_customer_id IS NOT NULL) AS internal_transfer_count,
      COUNT(vm.id) FILTER (WHERE vm.normalized_status = 'approved') AS approved_count
    FROM cash_flow_currencies cur
    LEFT JOIN visible_non_commission_movements vm ON vm.currency = cur.currency
    GROUP BY cur.currency
  ),
  pending_stats AS (
    SELECT
      COUNT(*) FILTER (
        WHERE (
          COALESCE(source_user_id, created_by_user_id) IS DISTINCT FROM p_user_id
          AND (
            customer_user_id = p_user_id
            OR customer_linked_user_id = p_user_id
            OR id IN (
              SELECT movement_id
              FROM public.movement_notifications
              WHERE user_id = p_user_id
                AND notification_type = 'approval_needed'
                AND COALESCE(action_required, true) = true
            )
          )
        )
      ) AS awaiting_my_approval_count,
      COUNT(*) FILTER (
        WHERE COALESCE(source_user_id, created_by_user_id) = p_user_id
      ) AS awaiting_others_approval_count,
      COUNT(*) FILTER (WHERE created_at <= now() - interval '24 hours') AS stale_pending_count
    FROM pending_customer_movements
  ),
  approval_performance AS (
    SELECT
      COUNT(*) FILTER (WHERE normalized_status = 'approved' AND approved_at >= now() - interval '7 days') AS approved_last_7_days,
      COUNT(*) FILTER (WHERE normalized_status = 'rejected' AND COALESCE(rejected_at, created_at) >= now() - interval '7 days') AS rejected_last_7_days,
      AVG(EXTRACT(EPOCH FROM (approved_at - created_at)) / 60.0) FILTER (
        WHERE normalized_status = 'approved'
          AND approved_at >= now() - interval '7 days'
          AND approved_at IS NOT NULL
      ) AS average_approval_minutes_last_7_days
    FROM visible_movements
    WHERE normalized_commission = false
  ),
  commission_entries AS (
    SELECT COALESCE(NULLIF(commission_currency, ''), currency) AS currency, COALESCE(commission, 0) AS amount
    FROM approved_customer_movements
    WHERE COALESCE(commission, 0) > 0
    UNION ALL
    SELECT vm.currency, COALESCE(vm.amount, 0) AS amount
    FROM visible_movements vm
    WHERE vm.normalized_commission = true
      AND vm.normalized_voided = false
      AND vm.normalized_status = 'approved'
      AND vm.currency IS NOT NULL
  ),
  top_customer_stats AS (
    SELECT
      c.id,
      c.name,
      c.phone,
      c.linked_user_id,
      COUNT(am.id) AS total_movements,
      COALESCE(SUM(am.amount), 0) AS total_volume,
      COALESCE(MAX(am.created_at), COALESCE(c.updated_at, c.created_at)) AS last_activity
    FROM visible_customers c
    LEFT JOIN approved_customer_movements am ON am.customer_id = c.id
    GROUP BY c.id, c.name, c.phone, c.linked_user_id, c.created_at, c.updated_at
    HAVING COUNT(am.id) > 0
    ORDER BY COUNT(am.id) DESC, COALESCE(SUM(am.amount), 0) DESC, COALESCE(MAX(am.created_at), COALESCE(c.updated_at, c.created_at)) DESC
    LIMIT 5
  )
  SELECT jsonb_build_object(
    'totalCustomers', (SELECT COUNT(*) FROM visible_customers),
    'totalTransactions', (SELECT COUNT(*) FROM scoped_transactions),
    'totalMovements', (SELECT COUNT(*) FROM approved_customer_movements),
    'totalAmount', COALESCE((SELECT SUM(amount) FROM approved_customer_movements), 0),
    'totalDebts', COALESCE((SELECT SUM(amount) FROM owed_to_us), 0),
    'totalWeOwe', COALESCE((SELECT SUM(amount) FROM we_owe), 0),
    'periodStats', jsonb_build_object(
      'today', public.get_app_period_statistics(p_user_id, v_today, v_today),
      'yesterday', public.get_app_period_statistics(p_user_id, v_yesterday, v_yesterday),
      'week', public.get_app_period_statistics(p_user_id, v_week_start, v_today),
      'month', public.get_app_period_statistics(p_user_id, v_month_start, v_today)
    ),
    'currencyBalances', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'currency', currency,
        'total_incoming', COALESCE(total_incoming, 0),
        'total_outgoing', COALESCE(total_outgoing, 0),
        'balance', COALESCE(balance, 0)
      ) ORDER BY currency)
      FROM currency_balances
    ), '[]'::jsonb),
    'cashFlowByCurrency', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'currency', currency,
        'totalReceived', COALESCE(total_received, 0),
        'totalPaid', COALESCE(total_paid, 0),
        'netFlow', COALESCE(total_received, 0) - COALESCE(total_paid, 0),
        'linkedReceived', COALESCE(linked_received, 0),
        'linkedPaid', COALESCE(linked_paid, 0),
        'directReceived', COALESCE(direct_received, 0),
        'directPaid', COALESCE(direct_paid, 0),
        'pendingAmount', COALESCE(pending_amount, 0),
        'pendingCount', COALESCE(pending_count, 0),
        'internalTransferAmount', COALESCE(internal_transfer_amount, 0),
        'internalTransferCount', COALESCE(internal_transfer_count, 0),
        'approvedCount', COALESCE(approved_count, 0)
      ) ORDER BY currency)
      FROM cash_flow
    ), '[]'::jsonb),
    'topCustomers', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', t.id,
        'name', t.name,
        'phone', t.phone,
        'linked_user_id', t.linked_user_id,
        'totalMovements', t.total_movements,
        'totalVolume', t.total_volume,
        'lastActivity', t.last_activity,
        'balanceByCurrency', COALESCE((
          SELECT jsonb_agg(jsonb_build_object('currency', b.currency, 'amount', b.balance) ORDER BY ABS(b.balance) DESC)
          FROM balance_by_customer_currency b
          WHERE b.customer_id = t.id
            AND b.balance <> 0
        ), '[]'::jsonb)
      ))
      FROM top_customer_stats t
    ), '[]'::jsonb),
    'commissionStats', jsonb_build_object(
      'totalCommission', COALESCE((SELECT SUM(amount) FROM commission_entries), 0),
      'commissionByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'total', total) ORDER BY total DESC)
        FROM (
          SELECT currency, SUM(amount) AS total
          FROM commission_entries
          GROUP BY currency
        ) s
      ), '[]'::jsonb)
    ),
    'debtStats', jsonb_build_object(
      'totalOwedToUs', COALESCE((SELECT SUM(amount) FROM owed_to_us), 0),
      'totalWeOwe', COALESCE((SELECT SUM(amount) FROM we_owe), 0),
      'owedToUsByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
        FROM owed_to_us
      ), '[]'::jsonb),
      'weOweByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
        FROM we_owe
      ), '[]'::jsonb)
    ),
    'actionableStats', jsonb_build_object(
      'awaitingMyApprovalCount', COALESCE((SELECT awaiting_my_approval_count FROM pending_stats), 0),
      'awaitingMyApprovalByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
        FROM (
          SELECT currency, SUM(amount) AS amount
          FROM pending_customer_movements
          WHERE COALESCE(source_user_id, created_by_user_id) IS DISTINCT FROM p_user_id
          GROUP BY currency
        ) s
      ), '[]'::jsonb),
      'awaitingOthersApprovalCount', COALESCE((SELECT awaiting_others_approval_count FROM pending_stats), 0),
      'awaitingOthersApprovalByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
        FROM (
          SELECT currency, SUM(amount) AS amount
          FROM pending_customer_movements
          WHERE COALESCE(source_user_id, created_by_user_id) = p_user_id
          GROUP BY currency
        ) s
      ), '[]'::jsonb),
      'stalePendingCount', COALESCE((SELECT stale_pending_count FROM pending_stats), 0),
      'stalePendingByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
        FROM (
          SELECT currency, SUM(amount) AS amount
          FROM pending_customer_movements
          WHERE created_at <= now() - interval '24 hours'
          GROUP BY currency
        ) s
      ), '[]'::jsonb),
      'approvedLast7Days', COALESCE((SELECT approved_last_7_days FROM approval_performance), 0),
      'rejectedLast7Days', COALESCE((SELECT rejected_last_7_days FROM approval_performance), 0),
      'approvalRateLast7Days', CASE
        WHEN COALESCE((SELECT approved_last_7_days + rejected_last_7_days FROM approval_performance), 0) = 0 THEN 0
        ELSE ROUND(((SELECT approved_last_7_days FROM approval_performance)::numeric / NULLIF((SELECT approved_last_7_days + rejected_last_7_days FROM approval_performance), 0)) * 100, 1)
      END,
      'rejectionRateLast7Days', CASE
        WHEN COALESCE((SELECT approved_last_7_days + rejected_last_7_days FROM approval_performance), 0) = 0 THEN 0
        ELSE ROUND(((SELECT rejected_last_7_days FROM approval_performance)::numeric / NULLIF((SELECT approved_last_7_days + rejected_last_7_days FROM approval_performance), 0)) * 100, 1)
      END,
      'averageApprovalMinutesLast7Days', (SELECT ROUND(average_approval_minutes_last_7_days::numeric, 1) FROM approval_performance)
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 9) Diagnostics with pair visibility
-- -----------------------------------------------------------------------------

CREATE FUNCTION public.get_app_statistics_debug(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_result jsonb;
BEGIN
  SELECT role INTO v_role
  FROM public.app_security
  WHERE id = p_user_id
  LIMIT 1;

  WITH scope_customers AS (
    SELECT c.*
    FROM public.customers c
    WHERE v_role = 'admin'
       OR c.user_id = p_user_id
       OR c.linked_user_id = p_user_id
       OR c.id IN (
         SELECT am.customer_id
         FROM public.account_movements am
         JOIN public.movement_notifications mn ON mn.movement_id = am.id
         WHERE mn.user_id = p_user_id
       )
  ),
  own_customers AS (
    SELECT c.*
    FROM public.customers c
    WHERE v_role = 'admin' OR c.user_id = p_user_id
  ),
  scoped_movements AS (
    SELECT
      am.*,
      c.name AS customer_name,
      c.user_id AS customer_user_id,
      c.linked_user_id AS customer_linked_user_id,
      public.get_movement_approval_status(am.approval_status, am.pending_approval) AS normalized_status,
      COALESCE(am.is_voided, false) AS normalized_voided,
      COALESCE(am.is_commission_movement, false) AS normalized_commission
    FROM public.account_movements am
    JOIN scope_customers c ON c.id = am.customer_id
  ),
  own_movements AS (
    SELECT
      am.*,
      c.name AS customer_name,
      c.user_id AS customer_user_id,
      c.linked_user_id AS customer_linked_user_id,
      public.get_movement_approval_status(am.approval_status, am.pending_approval) AS normalized_status,
      COALESCE(am.is_voided, false) AS normalized_voided,
      COALESCE(am.is_commission_movement, false) AS normalized_commission
    FROM public.account_movements am
    JOIN own_customers c ON c.id = am.customer_id
  )
  SELECT jsonb_build_object(
    'inputUserId', p_user_id,
    'selectedUser', (
      SELECT jsonb_build_object('id', id, 'user_name', user_name, 'role', role, 'is_active', is_active)
      FROM public.app_security
      WHERE id = p_user_id
      LIMIT 1
    ),
    'allUsers', (SELECT COUNT(*) FROM public.app_security),
    'allCustomers', (SELECT COUNT(*) FROM public.customers),
    'scopedCustomers', (SELECT COUNT(*) FROM scope_customers),
    'ownCustomers', (SELECT COUNT(*) FROM own_customers),
    'allMovements', (SELECT COUNT(*) FROM public.account_movements),
    'scopedMovements', (SELECT COUNT(*) FROM scoped_movements),
    'ownMovements', (SELECT COUNT(*) FROM own_movements),
    'allNotificationsForUser', (SELECT COUNT(*) FROM public.movement_notifications WHERE user_id = p_user_id),
    'functionSignatures', COALESCE((
      SELECT jsonb_agg((p.oid::regprocedure)::text ORDER BY p.proname, p.oid::regprocedure::text)
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('approve_movement', 'reject_movement_with_reason', 'get_app_statistics', 'get_app_period_statistics', 'get_app_statistics_debug')
    ), '[]'::jsonb),
    'movementStatusCounts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'status', normalized_status,
        'is_voided', normalized_voided,
        'is_commission', normalized_commission,
        'count', movements_count,
        'amount', total_amount
      ) ORDER BY movements_count DESC)
      FROM (
        SELECT normalized_status, normalized_voided, normalized_commission, COUNT(*) AS movements_count, COALESCE(SUM(amount), 0) AS total_amount
        FROM own_movements
        GROUP BY normalized_status, normalized_voided, normalized_commission
      ) s
    ), '[]'::jsonb),
    'latestScopedMovements', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', id,
        'customer_id', customer_id,
        'customer_name', customer_name,
        'movement_type', movement_type,
        'amount', amount,
        'currency', currency,
        'status', normalized_status,
        'is_voided', normalized_voided,
        'mirror_movement_id', mirror_movement_id,
        'created_by_user_id', created_by_user_id,
        'source_user_id', source_user_id,
        'created_at', created_at
      ) ORDER BY created_at DESC)
      FROM (
        SELECT *
        FROM scoped_movements
        ORDER BY created_at DESC
        LIMIT 20
      ) latest
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 10) Grants and schema cache reload
-- -----------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.get_movement_approval_status(text, boolean) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_approval_related_movement_ids(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_movement(uuid, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_movement_with_reason(uuid, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_movement(uuid, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_app_statistics(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_app_period_statistics(uuid, date, date) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_app_statistics_debug(uuid) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

SELECT
  'pair_approval_and_statistics_dedup_fixed' AS status,
  (
    SELECT jsonb_agg((p.oid::regprocedure)::text ORDER BY p.proname, p.oid::regprocedure::text)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'approve_movement',
        'reject_movement_with_reason',
        'reject_movement',
        'get_app_statistics',
        'get_app_period_statistics',
        'get_app_statistics_debug'
      )
  ) AS installed_functions;
