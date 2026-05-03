/*
  Include pending movements in balances and totals before approval.

  Goal:
  - Pending movements should affect "له / عليه" totals immediately.
  - Rejected movements must not affect totals.
  - Voided and commission movements remain excluded as before.
*/

BEGIN;

DROP VIEW IF EXISTS total_balances_by_currency;
DROP VIEW IF EXISTS customer_balances;
DROP VIEW IF EXISTS customer_accounts;
DROP VIEW IF EXISTS user_linked_accounts;
DROP VIEW IF EXISTS customer_balances_by_currency;

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
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
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
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
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
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
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
        AND COALESCE(am.approval_status, 'approved') <> 'rejected'
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
  'Customer accounts summary - non-rejected, non-voided, non-commission movements are counted, including pending approval';

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
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
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
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
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
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
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
        AND COALESCE(am.approval_status, 'approved') <> 'rejected'
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
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
          AND COALESCE(am.is_voided, false) = false
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.approval_status, 'approved') <> 'rejected'
          AND COALESCE(am.is_voided, false) = false
        THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) != 0;

COMMENT ON VIEW customer_balances IS
  'Customer balances - non-rejected, non-voided, non-commission movements are counted, including pending approval';

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
      AND COALESCE(am.approval_status, 'approved') <> 'rejected'
      AND COALESCE(am.is_voided, false) = false
  ), 0) AS total_movements
FROM customer_balances cb
WHERE cb.currency IS NOT NULL
GROUP BY cb.currency;

COMMENT ON VIEW total_balances_by_currency IS
  'Total balances by currency - built from non-rejected, non-voided customer balances, including pending approval';

CREATE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  c.user_id,
  c.linked_user_id,
  am.currency,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        ELSE 0
      END
    ),
    0
  ) AS total_incoming,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' THEN am.amount
        ELSE 0
      END
    ),
    0
  ) AS total_outgoing,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) AS balance,
  MAX(am.created_at) AS last_movement_date,
  COUNT(am.id) AS movement_count
FROM customers c
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND COALESCE(am.is_voided, false) = false
  AND COALESCE(am.is_commission_movement, false) = false
  AND COALESCE(am.approval_status, 'approved') <> 'rejected'
GROUP BY c.id, c.name, c.user_id, c.linked_user_id, am.currency
HAVING am.currency IS NOT NULL
  AND (
    COALESCE(
      SUM(
        CASE
          WHEN am.movement_type = 'incoming' THEN am.amount
          WHEN am.movement_type = 'outgoing' THEN -am.amount
          ELSE 0
        END
      ),
      0
    ) <> 0
    OR EXISTS (
      SELECT 1
      FROM customers c2
      WHERE c2.id = c.id
        AND COALESCE(c2.is_profit_loss_account, false) = true
    )
  );

GRANT SELECT ON customer_balances_by_currency TO authenticated, anon;

COMMENT ON VIEW customer_balances_by_currency IS
  'Customer balances by currency - non-rejected, non-voided, non-commission movements are counted, including pending approval';

CREATE VIEW user_linked_accounts AS
SELECT
  c.user_id AS owner_user_id,
  owner.user_name AS owner_user_name,
  owner.full_name AS owner_full_name,
  owner.account_number AS owner_account_number,
  c.linked_user_id,
  linked.user_name AS linked_user_name,
  linked.full_name AS linked_full_name,
  linked.account_number AS linked_account_number,
  c.id AS customer_id,
  c.name AS customer_name,
  c.phone AS customer_phone,
  c.created_at AS link_created_at,
  (
    SELECT COALESCE(
      SUM(
        CASE
          WHEN am.movement_type = 'incoming' THEN am.amount
          WHEN am.movement_type = 'outgoing' THEN -am.amount
          ELSE 0
        END
      ),
      0
    )
    FROM account_movements am
    WHERE am.customer_id = c.id
      AND COALESCE(am.is_commission_movement, false) = false
      AND COALESCE(am.is_voided, false) = false
      AND COALESCE(am.approval_status, 'approved') <> 'rejected'
  ) AS total_balance
FROM customers c
INNER JOIN app_security owner ON c.user_id = owner.id
INNER JOIN app_security linked ON c.linked_user_id = linked.id
WHERE c.linked_user_id IS NOT NULL;

GRANT SELECT ON user_linked_accounts TO authenticated;

COMMENT ON VIEW user_linked_accounts IS
  'Linked accounts summary - non-rejected, non-voided, non-commission movements are counted, including pending approval';

COMMIT;
