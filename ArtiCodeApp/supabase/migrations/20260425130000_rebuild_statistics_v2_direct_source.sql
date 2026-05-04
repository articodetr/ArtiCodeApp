/*
  ArtiCode App - Statistics V2 Direct Source Rebuild
  Purpose:
    - Remove every old/overloaded statistics RPC.
    - Recreate exactly one get_app_statistics(uuid) and one get_app_period_statistics(uuid,date,date).
    - Calculate statistics directly from customers/account_movements/transactions.
    - Include diagnostics through get_app_statistics_debug(uuid).
    - Support admin users by allowing them to see all data.
    - Support pending approvals from both linked customer fields and movement_notifications.

  Safe notes:
    - Does not delete customers, movements, transactions, or notifications.
    - Rebuilds customer balance views to exclude pending/rejected/voided movements.
*/

-- -----------------------------------------------------------------------------
-- 1) Required compatibility columns
-- -----------------------------------------------------------------------------

ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS is_profit_loss_account boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS linked_user_id uuid,
  ADD COLUMN IF NOT EXISTS user_id uuid;

ALTER TABLE public.account_movements
  ADD COLUMN IF NOT EXISTS commission numeric DEFAULT 0,
  ADD COLUMN IF NOT EXISTS commission_currency text,
  ADD COLUMN IF NOT EXISTS related_transfer_id uuid,
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

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'account_movements_approval_status_check'
  ) THEN
    ALTER TABLE public.account_movements
      ADD CONSTRAINT account_movements_approval_status_check
      CHECK (
        approval_status IS NULL
        OR approval_status IN ('pending', 'approved', 'rejected')
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS customers_user_scope_idx
  ON public.customers (user_id, linked_user_id);

CREATE INDEX IF NOT EXISTS account_movements_customer_created_idx
  ON public.account_movements (customer_id, created_at DESC);

CREATE INDEX IF NOT EXISTS account_movements_approval_status_idx
  ON public.account_movements (approval_status, pending_approval, is_voided);

CREATE INDEX IF NOT EXISTS account_movements_currency_idx
  ON public.account_movements (currency);

CREATE INDEX IF NOT EXISTS movement_notifications_user_movement_idx
  ON public.movement_notifications (user_id, movement_id)
  WHERE movement_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2) Rebuild approved-only balance views
-- -----------------------------------------------------------------------------

DROP VIEW IF EXISTS public.customer_balances_by_currency CASCADE;
DROP VIEW IF EXISTS public.customer_balances CASCADE;

CREATE VIEW public.customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  c.user_id,
  c.linked_user_id,
  am.currency,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  COALESCE(SUM(
    CASE
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ), 0) AS balance
FROM public.customers c
JOIN public.account_movements am
  ON am.customer_id = c.id
  AND COALESCE(am.is_commission_movement, false) = false
  AND COALESCE(am.is_voided, false) = false
  AND COALESCE(
    am.approval_status,
    CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END
  ) = 'approved'
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, c.user_id, c.linked_user_id, am.currency;

CREATE VIEW public.customer_balances AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.user_id,
  c.linked_user_id,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  COALESCE(SUM(
    CASE
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ), 0) AS balance,
  COUNT(am.id) AS total_movements,
  MAX(am.created_at) AS last_activity
FROM public.customers c
LEFT JOIN public.account_movements am
  ON am.customer_id = c.id
  AND COALESCE(am.is_commission_movement, false) = false
  AND COALESCE(am.is_voided, false) = false
  AND COALESCE(
    am.approval_status,
    CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END
  ) = 'approved'
WHERE COALESCE(c.is_profit_loss_account, false) = false
  AND c.phone IS DISTINCT FROM 'PROFIT_LOSS_ACCOUNT'
GROUP BY c.id, c.name, c.phone, c.user_id, c.linked_user_id;

-- -----------------------------------------------------------------------------
-- 3) Remove every old duplicate/overloaded statistics function
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
        'get_app_statistics',
        'get_app_period_statistics',
        'get_app_statistics_debug'
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

-- -----------------------------------------------------------------------------
-- 4) Period statistics RPC
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_app_period_statistics(
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

  WITH scoped_customers AS (
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
  period_transactions AS (
    SELECT t.*
    FROM public.transactions t
    JOIN scoped_customers c ON c.id = t.customer_id
    WHERE COALESCE(t.status, 'completed') = 'completed'
      AND t.created_at >= v_start
      AND t.created_at < v_end
  ),
  period_movements AS (
    SELECT am.*
    FROM public.account_movements am
    JOIN scoped_customers c ON c.id = am.customer_id
    WHERE am.created_at >= v_start
      AND am.created_at < v_end
      AND COALESCE(am.is_commission_movement, false) = false
      AND COALESCE(am.is_voided, false) = false
      AND COALESCE(
        am.approval_status,
        CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END
      ) = 'approved'
  ),
  period_commissions AS (
    SELECT
      COALESCE(NULLIF(am.commission_currency, ''), am.currency) AS currency,
      COALESCE(am.commission, 0) AS amount
    FROM period_movements am
    WHERE COALESCE(am.commission, 0) > 0
    UNION ALL
    SELECT
      am.currency,
      COALESCE(am.amount, 0) AS amount
    FROM public.account_movements am
    JOIN scoped_customers c ON c.id = am.customer_id
    WHERE am.created_at >= v_start
      AND am.created_at < v_end
      AND COALESCE(am.is_commission_movement, false) = true
      AND COALESCE(am.is_voided, false) = false
      AND COALESCE(
        am.approval_status,
        CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END
      ) = 'approved'
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
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 5) Main statistics RPC - direct source of truth
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_app_statistics(p_user_id uuid)
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

  WITH scoped_customers AS (
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
  non_system_customers AS (
    SELECT *
    FROM scoped_customers
    WHERE COALESCE(is_profit_loss_account, false) = false
      AND phone IS DISTINCT FROM 'PROFIT_LOSS_ACCOUNT'
  ),
  scoped_transactions AS (
    SELECT t.*
    FROM public.transactions t
    JOIN scoped_customers c ON c.id = t.customer_id
    WHERE COALESCE(t.status, 'completed') = 'completed'
  ),
  scoped_movements AS (
    SELECT
      am.*,
      c.name AS customer_name,
      c.phone AS customer_phone,
      c.user_id AS customer_user_id,
      c.linked_user_id AS customer_linked_user_id,
      COALESCE(c.is_profit_loss_account, false) AS customer_is_profit_loss_account,
      COALESCE(
        am.approval_status,
        CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END
      ) AS normalized_status,
      COALESCE(am.is_voided, false) AS normalized_voided,
      COALESCE(am.is_commission_movement, false) AS normalized_commission
    FROM public.account_movements am
    JOIN scoped_customers c ON c.id = am.customer_id
  ),
  non_commission_movements AS (
    SELECT *
    FROM scoped_movements
    WHERE normalized_commission = false
      AND normalized_voided = false
      AND currency IS NOT NULL
  ),
  approved_customer_movements AS (
    SELECT *
    FROM non_commission_movements
    WHERE normalized_status = 'approved'
  ),
  pending_customer_movements AS (
    SELECT *
    FROM non_commission_movements
    WHERE normalized_status = 'pending'
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
    WHERE customer_is_profit_loss_account = false
      AND customer_phone IS DISTINCT FROM 'PROFIT_LOSS_ACCOUNT'
    GROUP BY customer_id, customer_name, customer_phone, customer_user_id, customer_linked_user_id, currency
  ),
  currency_balances AS (
    SELECT
      currency,
      COALESCE(SUM(total_incoming), 0) AS total_incoming,
      COALESCE(SUM(total_outgoing), 0) AS total_outgoing,
      COALESCE(SUM(balance), 0) AS balance
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
  cash_flow AS (
    SELECT
      currency,
      SUM(CASE WHEN normalized_status = 'approved' AND movement_type = 'incoming' THEN amount ELSE 0 END) AS total_received,
      SUM(CASE WHEN normalized_status = 'approved' AND movement_type = 'outgoing' THEN amount ELSE 0 END) AS total_paid,
      SUM(CASE WHEN normalized_status = 'approved' AND movement_type = 'incoming'
          AND (related_transfer_id IS NOT NULL OR mirror_movement_id IS NOT NULL)
          AND from_customer_id IS NULL AND to_customer_id IS NULL THEN amount ELSE 0 END) AS linked_received,
      SUM(CASE WHEN normalized_status = 'approved' AND movement_type = 'outgoing'
          AND (related_transfer_id IS NOT NULL OR mirror_movement_id IS NOT NULL)
          AND from_customer_id IS NULL AND to_customer_id IS NULL THEN amount ELSE 0 END) AS linked_paid,
      SUM(CASE WHEN normalized_status = 'approved' AND movement_type = 'incoming'
          AND related_transfer_id IS NULL AND mirror_movement_id IS NULL
          AND from_customer_id IS NULL AND to_customer_id IS NULL THEN amount ELSE 0 END) AS direct_received,
      SUM(CASE WHEN normalized_status = 'approved' AND movement_type = 'outgoing'
          AND related_transfer_id IS NULL AND mirror_movement_id IS NULL
          AND from_customer_id IS NULL AND to_customer_id IS NULL THEN amount ELSE 0 END) AS direct_paid,
      SUM(CASE WHEN normalized_status = 'pending' THEN amount ELSE 0 END) AS pending_amount,
      COUNT(*) FILTER (WHERE normalized_status = 'pending') AS pending_count,
      SUM(CASE WHEN from_customer_id IS NOT NULL OR to_customer_id IS NOT NULL THEN amount ELSE 0 END) AS internal_transfer_amount,
      COUNT(*) FILTER (WHERE from_customer_id IS NOT NULL OR to_customer_id IS NOT NULL) AS internal_transfer_count,
      COUNT(*) FILTER (WHERE normalized_status = 'approved') AS approved_count
    FROM non_commission_movements
    GROUP BY currency
  ),
  pending_stats AS (
    SELECT
      COUNT(*) FILTER (
        WHERE (
          customer_linked_user_id = p_user_id
          AND customer_user_id IS DISTINCT FROM p_user_id
        )
        OR id IN (
          SELECT movement_id
          FROM public.movement_notifications
          WHERE user_id = p_user_id
            AND notification_type = 'approval_needed'
            AND COALESCE(action_required, true) = true
        )
      ) AS awaiting_my_approval_count,
      COUNT(*) FILTER (
        WHERE customer_user_id = p_user_id
           OR created_by_user_id = p_user_id
           OR source_user_id = p_user_id
      ) AS awaiting_others_approval_count,
      COUNT(*) FILTER (WHERE created_at <= now() - interval '24 hours') AS stale_pending_count
    FROM pending_customer_movements
  ),
  approval_performance AS (
    SELECT
      COUNT(*) FILTER (
        WHERE normalized_status = 'approved'
          AND approved_at >= now() - interval '7 days'
      ) AS approved_last_7_days,
      COUNT(*) FILTER (
        WHERE normalized_status = 'rejected'
          AND COALESCE(rejected_at, created_at) >= now() - interval '7 days'
      ) AS rejected_last_7_days,
      AVG(EXTRACT(EPOCH FROM (approved_at - created_at)) / 60.0) FILTER (
        WHERE normalized_status = 'approved'
          AND approved_at >= now() - interval '7 days'
          AND approved_at IS NOT NULL
      ) AS average_approval_minutes_last_7_days
    FROM scoped_movements
    WHERE normalized_commission = false
  ),
  commission_entries AS (
    SELECT COALESCE(NULLIF(commission_currency, ''), currency) AS currency, COALESCE(commission, 0) AS amount
    FROM approved_customer_movements
    WHERE COALESCE(commission, 0) > 0
    UNION ALL
    SELECT currency, COALESCE(amount, 0) AS amount
    FROM scoped_movements
    WHERE normalized_commission = true
      AND normalized_voided = false
      AND normalized_status = 'approved'
      AND currency IS NOT NULL
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
    FROM non_system_customers c
    LEFT JOIN approved_customer_movements am ON am.customer_id = c.id
    GROUP BY c.id, c.name, c.phone, c.linked_user_id, c.created_at, c.updated_at
    HAVING COUNT(am.id) > 0
    ORDER BY COUNT(am.id) DESC, COALESCE(SUM(am.amount), 0) DESC, COALESCE(MAX(am.created_at), COALESCE(c.updated_at, c.created_at)) DESC
    LIMIT 5
  )
  SELECT jsonb_build_object(
    'totalCustomers', (SELECT COUNT(*) FROM non_system_customers),
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
        'total_incoming', total_incoming,
        'total_outgoing', total_outgoing,
        'balance', balance
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
          WHERE (
            customer_linked_user_id = p_user_id
            AND customer_user_id IS DISTINCT FROM p_user_id
          )
          OR id IN (
            SELECT movement_id
            FROM public.movement_notifications
            WHERE user_id = p_user_id
              AND notification_type = 'approval_needed'
              AND COALESCE(action_required, true) = true
          )
          GROUP BY currency
        ) s
      ), '[]'::jsonb),
      'awaitingOthersApprovalCount', COALESCE((SELECT awaiting_others_approval_count FROM pending_stats), 0),
      'awaitingOthersApprovalByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
        FROM (
          SELECT currency, SUM(amount) AS amount
          FROM pending_customer_movements
          WHERE customer_user_id = p_user_id
             OR created_by_user_id = p_user_id
             OR source_user_id = p_user_id
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
-- 6) Diagnostics RPC
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_app_statistics_debug(p_user_id uuid)
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

  WITH scoped_customers AS (
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
  scoped_movements AS (
    SELECT
      am.*,
      COALESCE(
        am.approval_status,
        CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END
      ) AS normalized_status,
      COALESCE(am.is_voided, false) AS normalized_voided,
      COALESCE(am.is_commission_movement, false) AS normalized_commission
    FROM public.account_movements am
    JOIN scoped_customers c ON c.id = am.customer_id
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
    'scopedCustomers', (SELECT COUNT(*) FROM scoped_customers),
    'allMovements', (SELECT COUNT(*) FROM public.account_movements),
    'scopedMovements', (SELECT COUNT(*) FROM scoped_movements),
    'allNotificationsForUser', (
      SELECT COUNT(*)
      FROM public.movement_notifications
      WHERE user_id = p_user_id
    ),
    'functionSignatures', COALESCE((
      SELECT jsonb_agg((p.oid::regprocedure)::text ORDER BY p.proname, p.oid::regprocedure::text)
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('get_app_statistics', 'get_app_period_statistics', 'get_app_statistics_debug')
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
        SELECT
          normalized_status,
          normalized_voided,
          normalized_commission,
          COUNT(*) AS movements_count,
          COALESCE(SUM(amount), 0) AS total_amount
        FROM scoped_movements
        GROUP BY normalized_status, normalized_voided, normalized_commission
      ) s
    ), '[]'::jsonb),
    'currencyCounts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('currency', currency, 'count', movements_count, 'amount', total_amount) ORDER BY movements_count DESC)
      FROM (
        SELECT currency, COUNT(*) AS movements_count, COALESCE(SUM(amount), 0) AS total_amount
        FROM scoped_movements
        GROUP BY currency
      ) s
    ), '[]'::jsonb),
    'latestScopedMovements', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', id,
        'customer_id', customer_id,
        'movement_type', movement_type,
        'amount', amount,
        'currency', currency,
        'status', normalized_status,
        'is_voided', normalized_voided,
        'created_at', created_at
      ) ORDER BY created_at DESC)
      FROM (
        SELECT *
        FROM scoped_movements
        ORDER BY created_at DESC
        LIMIT 10
      ) latest
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 7) Permissions and verification
-- -----------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.get_app_statistics(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_app_period_statistics(uuid, date, date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_app_statistics_debug(uuid) TO anon, authenticated;
GRANT SELECT ON public.customer_balances TO anon, authenticated;
GRANT SELECT ON public.customer_balances_by_currency TO anon, authenticated;

SELECT
  'articode_statistics_v2_direct_source_installed' AS status,
  (
    SELECT jsonb_agg((p.oid::regprocedure)::text ORDER BY p.proname, p.oid::regprocedure::text)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('get_app_statistics', 'get_app_period_statistics', 'get_app_statistics_debug')
  ) AS installed_functions;
