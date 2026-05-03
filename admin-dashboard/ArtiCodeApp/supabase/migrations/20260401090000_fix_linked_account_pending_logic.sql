/*
  Fix linked-account pending approval logic in balances and movement fetches.

  What this script does:
  1) Recreates customer_balances_by_currency so only approved, non-voided,
     non-commission movements affect balances.
  2) Recreates user_linked_accounts so linked-account balances also ignore
     pending / rejected / voided / commission movements.
  3) Recreates get_customer_movements_with_user so the UI still receives
     pending_approval / approval_status / approved_at / is_voided fields.

  Why DROP + CREATE for views?
  PostgreSQL does not allow changing view column names/order safely with
  CREATE OR REPLACE VIEW in this case, so we drop and recreate the views.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) customer_balances_by_currency
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS customer_balances_by_currency;

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
  AND COALESCE(am.pending_approval, false) = false
  AND COALESCE(am.approval_status, 'approved') = 'approved'
  AND COALESCE(am.is_commission_movement, false) = false
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
  'Customer balances by currency - only approved, non-voided, non-commission movements are counted';

-- ---------------------------------------------------------------------------
-- 2) user_linked_accounts
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS user_linked_accounts;

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
      AND COALESCE(am.pending_approval, false) = false
      AND COALESCE(am.approval_status, 'approved') = 'approved'
  ) AS total_balance
FROM customers c
INNER JOIN app_security owner ON c.user_id = owner.id
INNER JOIN app_security linked ON c.linked_user_id = linked.id
WHERE c.linked_user_id IS NOT NULL;

GRANT SELECT ON user_linked_accounts TO authenticated;

COMMENT ON VIEW user_linked_accounts IS
  'Linked accounts summary - only approved, non-voided, non-commission movements are counted';

-- ---------------------------------------------------------------------------
-- 3) get_customer_movements_with_user
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_customer_movements_with_user(
  p_user_name text,
  p_customer_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM set_config('app.current_user', p_user_name, false);

  SELECT jsonb_agg(
    jsonb_build_object(
      'id', am.id,
      'movement_number', am.movement_number,
      'customer_id', am.customer_id,
      'movement_type', am.movement_type,
      'amount', am.amount,
      'currency', am.currency,
      'notes', am.notes,
      'created_at', am.created_at,
      'sender_name', am.sender_name,
      'beneficiary_name', am.beneficiary_name,
      'commission', am.commission,
      'commission_currency', am.commission_currency,
      'commission_recipient_id', am.commission_recipient_id,
      'is_commission_movement', am.is_commission_movement,
      'receipt_number', am.receipt_number,
      'account_statement_number', am.account_statement_number,
      'transfer_number', am.transfer_number,
      'from_customer_id', am.from_customer_id,
      'to_customer_id', am.to_customer_id,
      'transfer_direction', am.transfer_direction,
      'related_transfer_id', am.related_transfer_id,
      'mirror_movement_id', am.mirror_movement_id,
      'source_user_id', am.source_user_id,
      'related_commission_movement_id', am.related_commission_movement_id,
      'pending_approval', COALESCE(am.pending_approval, false),
      'approval_status', COALESCE(am.approval_status, 'approved'),
      'approved_at', am.approved_at,
      'is_voided', COALESCE(am.is_voided, false),
      'is_internal_transfer', CASE
        WHEN am.from_customer_id IS NOT NULL OR am.to_customer_id IS NOT NULL THEN true
        ELSE false
      END,
      'customer', jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'linked_user_id', c.linked_user_id,
        'linked_user', CASE
          WHEN c.linked_user_id IS NOT NULL THEN
            jsonb_build_object(
              'id', lu.id,
              'user_name', lu.user_name,
              'full_name', lu.full_name,
              'account_number', lu.account_number
            )
          ELSE NULL
        END
      )
    )
    ORDER BY am.created_at DESC
  )
  INTO v_result
  FROM account_movements am
  LEFT JOIN customers c ON am.customer_id = c.id
  LEFT JOIN app_security lu ON c.linked_user_id = lu.id
  WHERE am.customer_id = p_customer_id
    AND COALESCE(am.is_voided, false) = false;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_customer_movements_with_user(text, uuid) TO anon, authenticated;

COMMENT ON FUNCTION get_customer_movements_with_user IS
  'Get customer movements with linked-user info and approval fields; excludes voided movements from list';

COMMIT;
