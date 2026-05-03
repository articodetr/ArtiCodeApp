/*
  ArtiCode App - Rebuild statistics as single source of truth
  This migration installs exactly one version of:
    - public.get_app_statistics(uuid)
    - public.get_app_period_statistics(uuid, date, date)

  It also ensures the approval/balance columns required by the statistics screen exist.
*/

-- -----------------------------------------------------------------------------
-- 1) Compatibility columns used by the current application
-- -----------------------------------------------------------------------------

ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS is_profit_loss_account boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS linked_user_id uuid;

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

-- -----------------------------------------------------------------------------
-- 2) Approved-only balance views used by the app
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
WHERE c.phone IS DISTINCT FROM 'PROFIT_LOSS_ACCOUNT'
GROUP BY c.id, c.name, c.phone, c.user_id, c.linked_user_id;

-- -----------------------------------------------------------------------------
-- 3) Remove any duplicate function versions again, then recreate exactly one each
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
      AND p.proname IN ('get_app_statistics', 'get_app_period_statistics')
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
  v_result jsonb;
BEGIN
  WITH scoped_customers AS (
    SELECT c.*
    FROM public.customers c
    WHERE c.user_id = p_user_id
       OR c.linked_user_id = p_user_id
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
-- 5) Main statistics RPC
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
  v_result jsonb;
BEGIN
  WITH scoped_customers AS (
    SELECT c.*
    FROM public.customers c
    WHERE c.user_id = p_user_id
       OR c.linked_user_id = p_user_id
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
      c.updated_at AS customer_updated_at
    FROM public.account_movements am
    JOIN scoped_customers c ON c.id = am.customer_id
  ),
  approved_customer_movements AS (
    SELECT *
    FROM scoped_movements
    WHERE COALESCE(is_commission_movement, false) = false
      AND COALESCE(is_voided, false) = false
      AND COALESCE(
        approval_status,
        CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END
      ) = 'approved'
  ),
  non_system_balances AS (
    SELECT cb.*
    FROM public.customer_balances_by_currency cb
    JOIN non_system_customers c ON c.id = cb.customer_id
  ),
  owed_to_us AS (
    SELECT currency, ABS(SUM(balance)) AS amount
    FROM non_system_balances
    WHERE balance < 0
    GROUP BY currency
  ),
  we_owe AS (
    SELECT currency, SUM(balance) AS amount
    FROM non_system_balances
    WHERE balance > 0
    GROUP BY currency
  ),
  currency_balances AS (
    SELECT
      currency,
      SUM(total_incoming) AS total_incoming,
      SUM(total_outgoing) AS total_outgoing,
      SUM(balance) AS balance
    FROM non_system_balances
    GROUP BY currency
  ),
  cash_flow AS (
    SELECT
      currency,
      SUM(CASE WHEN movement_type = 'incoming'
           AND COALESCE(is_commission_movement, false) = false
           AND COALESCE(is_voided, false) = false
           AND COALESCE(approval_status, CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'approved'
           AND from_customer_id IS NULL AND to_customer_id IS NULL
           THEN amount ELSE 0 END) AS total_received,
      SUM(CASE WHEN movement_type = 'outgoing'
           AND COALESCE(is_commission_movement, false) = false
           AND COALESCE(is_voided, false) = false
           AND COALESCE(approval_status, CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'approved'
           AND from_customer_id IS NULL AND to_customer_id IS NULL
           THEN amount ELSE 0 END) AS total_paid,
      SUM(CASE WHEN movement_type = 'incoming'
           AND COALESCE(is_commission_movement, false) = false
           AND COALESCE(is_voided, false) = false
           AND COALESCE(approval_status, CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'approved'
           AND (related_transfer_id IS NOT NULL OR mirror_movement_id IS NOT NULL)
           AND from_customer_id IS NULL AND to_customer_id IS NULL
           THEN amount ELSE 0 END) AS linked_received,
      SUM(CASE WHEN movement_type = 'outgoing'
           AND COALESCE(is_commission_movement, false) = false
           AND COALESCE(is_voided, false) = false
           AND COALESCE(approval_status, CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'approved'
           AND (related_transfer_id IS NOT NULL OR mirror_movement_id IS NOT NULL)
           AND from_customer_id IS NULL AND to_customer_id IS NULL
           THEN amount ELSE 0 END) AS linked_paid,
      SUM(CASE WHEN movement_type = 'incoming'
           AND COALESCE(is_commission_movement, false) = false
           AND COALESCE(is_voided, false) = false
           AND COALESCE(approval_status, CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'approved'
           AND related_transfer_id IS NULL AND mirror_movement_id IS NULL
           AND from_customer_id IS NULL AND to_customer_id IS NULL
           THEN amount ELSE 0 END) AS direct_received,
      SUM(CASE WHEN movement_type = 'outgoing'
           AND COALESCE(is_commission_movement, false) = false
           AND COALESCE(is_voided, false) = false
           AND COALESCE(approval_status, CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'approved'
           AND related_transfer_id IS NULL AND mirror_movement_id IS NULL
           AND from_customer_id IS NULL AND to_customer_id IS NULL
           THEN amount ELSE 0 END) AS direct_paid,
      SUM(CASE WHEN COALESCE(is_commission_movement, false) = false
           AND COALESCE(is_voided, false) = false
           AND (COALESCE(pending_approval, false) = true OR approval_status = 'pending')
           THEN amount ELSE 0 END) AS pending_amount,
      COUNT(*) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND COALESCE(is_voided, false) = false
          AND (COALESCE(pending_approval, false) = true OR approval_status = 'pending')
      ) AS pending_count,
      SUM(CASE WHEN COALESCE(is_commission_movement, false) = false
           AND COALESCE(is_voided, false) = false
           AND (from_customer_id IS NOT NULL OR to_customer_id IS NOT NULL)
           THEN amount ELSE 0 END) AS internal_transfer_amount,
      COUNT(*) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND COALESCE(is_voided, false) = false
          AND (from_customer_id IS NOT NULL OR to_customer_id IS NOT NULL)
      ) AS internal_transfer_count,
      COUNT(*) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND COALESCE(is_voided, false) = false
          AND COALESCE(approval_status, CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'approved'
      ) AS approved_count
    FROM scoped_movements
    WHERE currency IS NOT NULL
    GROUP BY currency
  ),
  pending_stats AS (
    SELECT
      COUNT(*) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND COALESCE(is_voided, false) = false
          AND (COALESCE(pending_approval, false) = true OR approval_status = 'pending')
          AND customer_linked_user_id = p_user_id
          AND customer_user_id IS DISTINCT FROM p_user_id
      ) AS awaiting_my_approval_count,
      COUNT(*) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND COALESCE(is_voided, false) = false
          AND (COALESCE(pending_approval, false) = true OR approval_status = 'pending')
          AND customer_user_id = p_user_id
          AND customer_linked_user_id IS NOT NULL
      ) AS awaiting_others_approval_count,
      COUNT(*) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND COALESCE(is_voided, false) = false
          AND (COALESCE(pending_approval, false) = true OR approval_status = 'pending')
          AND created_at <= now() - interval '24 hours'
      ) AS stale_pending_count,
      COUNT(*) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND approval_status = 'approved'
          AND approved_at >= now() - interval '7 days'
      ) AS approved_last_7_days,
      COUNT(*) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND approval_status = 'rejected'
          AND COALESCE(rejected_at, created_at) >= now() - interval '7 days'
      ) AS rejected_last_7_days,
      AVG(EXTRACT(EPOCH FROM (approved_at - created_at)) / 60.0) FILTER (
        WHERE COALESCE(is_commission_movement, false) = false
          AND approval_status = 'approved'
          AND approved_at >= now() - interval '7 days'
          AND approved_at IS NOT NULL
      ) AS average_approval_minutes_last_7_days
    FROM scoped_movements
  ),
  commission_entries AS (
    SELECT COALESCE(NULLIF(commission_currency, ''), currency) AS currency, COALESCE(commission, 0) AS amount
    FROM approved_customer_movements
    WHERE COALESCE(commission, 0) > 0
    UNION ALL
    SELECT currency, COALESCE(amount, 0) AS amount
    FROM scoped_movements
    WHERE COALESCE(is_commission_movement, false) = true
      AND COALESCE(is_voided, false) = false
      AND COALESCE(approval_status, CASE WHEN COALESCE(pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'approved'
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
          FROM public.customer_balances_by_currency b
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
          FROM scoped_movements
          WHERE COALESCE(is_commission_movement, false) = false
            AND COALESCE(is_voided, false) = false
            AND (COALESCE(pending_approval, false) = true OR approval_status = 'pending')
            AND customer_linked_user_id = p_user_id
            AND customer_user_id IS DISTINCT FROM p_user_id
          GROUP BY currency
        ) s
      ), '[]'::jsonb),
      'awaitingOthersApprovalCount', COALESCE((SELECT awaiting_others_approval_count FROM pending_stats), 0),
      'awaitingOthersApprovalByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
        FROM (
          SELECT currency, SUM(amount) AS amount
          FROM scoped_movements
          WHERE COALESCE(is_commission_movement, false) = false
            AND COALESCE(is_voided, false) = false
            AND (COALESCE(pending_approval, false) = true OR approval_status = 'pending')
            AND customer_user_id = p_user_id
            AND customer_linked_user_id IS NOT NULL
          GROUP BY currency
        ) s
      ), '[]'::jsonb),
      'stalePendingCount', COALESCE((SELECT stale_pending_count FROM pending_stats), 0),
      'stalePendingByCurrency', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount) ORDER BY amount DESC)
        FROM (
          SELECT currency, SUM(amount) AS amount
          FROM scoped_movements
          WHERE COALESCE(is_commission_movement, false) = false
            AND COALESCE(is_voided, false) = false
            AND (COALESCE(pending_approval, false) = true OR approval_status = 'pending')
            AND created_at <= now() - interval '24 hours'
          GROUP BY currency
        ) s
      ), '[]'::jsonb),
      'approvedLast7Days', COALESCE((SELECT approved_last_7_days FROM pending_stats), 0),
      'rejectedLast7Days', COALESCE((SELECT rejected_last_7_days FROM pending_stats), 0),
      'approvalRateLast7Days', CASE
        WHEN COALESCE((SELECT approved_last_7_days + rejected_last_7_days FROM pending_stats), 0) = 0 THEN 0
        ELSE ROUND(((SELECT approved_last_7_days FROM pending_stats)::numeric / NULLIF((SELECT approved_last_7_days + rejected_last_7_days FROM pending_stats), 0)) * 100, 1)
      END,
      'rejectionRateLast7Days', CASE
        WHEN COALESCE((SELECT approved_last_7_days + rejected_last_7_days FROM pending_stats), 0) = 0 THEN 0
        ELSE ROUND(((SELECT rejected_last_7_days FROM pending_stats)::numeric / NULLIF((SELECT approved_last_7_days + rejected_last_7_days FROM pending_stats), 0)) * 100, 1)
      END,
      'averageApprovalMinutesLast7Days', (SELECT ROUND(average_approval_minutes_last_7_days::numeric, 1) FROM pending_stats)
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 6) Permissions
-- -----------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.get_app_statistics(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_app_period_statistics(uuid, date, date) TO anon, authenticated;
GRANT SELECT ON public.customer_balances TO anon, authenticated;
GRANT SELECT ON public.customer_balances_by_currency TO anon, authenticated;

SELECT 'articode_statistics_rpc_final_installed' AS status;
