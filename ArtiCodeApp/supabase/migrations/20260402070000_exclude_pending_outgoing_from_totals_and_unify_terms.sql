/*
  # Exclude pending linked-account "عليه" movements from all totals

  ## Goal
  Ensure any movement that still needs approval does not affect totals anywhere
  until it is approved. This applies to both parties, especially linked-account
  outgoing movements ("عليه").

  ## Changes
  - Recreate customer_accounts to count only approved, non-voided movements
  - Recreate customer_balances to count only approved, non-voided,
    non-commission movements
  - Recreate total_balances_by_currency on top of the updated balances view
*/

DROP VIEW IF EXISTS customer_accounts;

CREATE VIEW customer_accounts AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.email,
  c.address,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        ELSE 0
      END
    ),
    0
  ) AS total_incoming,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        ELSE 0
      END
    ),
    0
  ) AS total_outgoing,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) AS balance,
  COUNT(
    CASE
      WHEN COALESCE(am.is_commission_movement, false) = false
        AND COALESCE(am.pending_approval, false) = false
        AND COALESCE(am.approval_status, 'approved') = 'approved'
        AND COALESCE(am.is_voided, false) = false
      THEN am.id
      ELSE NULL
    END
  ) AS total_movements,
  c.created_at,
  c.updated_at
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.created_at, c.updated_at;

COMMENT ON VIEW customer_accounts IS
  'Customer accounts summary - only approved, non-voided, non-commission movements are counted';

DROP VIEW IF EXISTS total_balances_by_currency;
DROP VIEW IF EXISTS customer_balances;

CREATE VIEW customer_balances AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.user_id,
  c.linked_user_id,
  c.is_profit_loss_account,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        ELSE 0
      END
    ),
    0
  ) AS total_incoming,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        ELSE 0
      END
    ),
    0
  ) AS total_outgoing,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) AS balance,
  am.currency,
  MAX(
    CASE
      WHEN COALESCE(am.is_commission_movement, false) = false
        AND COALESCE(am.pending_approval, false) = false
        AND COALESCE(am.approval_status, 'approved') = 'approved'
        AND COALESCE(am.is_voided, false) = false
      THEN am.created_at
      ELSE NULL
    END
  ) AS last_activity
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.user_id, c.linked_user_id, c.is_profit_loss_account, am.currency
HAVING
  c.is_profit_loss_account = true
  OR COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.pending_approval, false) = false
          AND COALESCE(am.approval_status, 'approved') = 'approved'
          AND COALESCE(am.is_voided, false) = false
        THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) != 0;

COMMENT ON VIEW customer_balances IS
  'Customer balances - only approved, non-voided, non-commission movements are counted';

CREATE VIEW total_balances_by_currency AS
SELECT
  cb.currency,
  COALESCE(SUM(cb.balance), 0) AS total_balance,
  COALESCE(SUM(cb.total_incoming), 0) AS total_incoming,
  COALESCE(SUM(cb.total_outgoing), 0) AS total_outgoing,
  0::numeric AS total_commission,
  COUNT(DISTINCT CASE WHEN cb.is_profit_loss_account IS NOT TRUE THEN cb.id END) AS customer_count,
  COALESCE((
    SELECT COUNT(am.id)
    FROM account_movements am
    WHERE am.currency = cb.currency
      AND COALESCE(am.is_commission_movement, false) = false
      AND COALESCE(am.pending_approval, false) = false
      AND COALESCE(am.approval_status, 'approved') = 'approved'
      AND COALESCE(am.is_voided, false) = false
  ), 0) AS total_movements
FROM customer_balances cb
WHERE cb.currency IS NOT NULL
GROUP BY cb.currency;

COMMENT ON VIEW total_balances_by_currency IS
  'Total balances by currency - built from approved, non-voided customer balances only';
