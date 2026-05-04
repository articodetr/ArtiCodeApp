/*
  Combined fix for linked-account mirror movements and pending-balance logic.

  What this fixes:
  1) Duplicate receipt_number error (23505) when creating mirror movements,
     especially on "عليه" movements.
  2) Pending / rejected / voided linked-account movements should NOT affect balances.
  3) Movement fetch for the UI still returns pending_approval / approval_status /
     approved_at / is_voided fields.

  Safe behavior preserved:
  - "عليه" still creates a mirror movement that needs approval.
  - "له" mirror movement is auto-approved.
  - No auto-approve-all behavior is introduced.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Fix create_mirror_movement_v2
--    Important: do NOT pass receipt_number into the mirror insert.
--    Let the DB trigger generate a fresh receipt number for the linked customer.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_mirror_movement_v2(p_movement_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_original_movement record;
  v_customer record;
  v_linked_customer_id uuid;
  v_mirror_movement_id uuid;
  v_mirror_type text;
  v_mirror_needs_approval boolean;
  v_mirror_approval_status text;
  v_customer_was_created boolean := false;
  v_original_creator_name text;
BEGIN
  RAISE NOTICE '[create_mirror_movement_v2] بدء إنشاء حركة مرآة للحركة: %', p_movement_id;

  SELECT * INTO v_original_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF v_original_movement IS NULL THEN
    RAISE NOTICE '[create_mirror_movement_v2] الحركة غير موجودة: %', p_movement_id;
    RETURN NULL;
  END IF;

  SELECT * INTO v_customer
  FROM customers
  WHERE id = v_original_movement.customer_id;

  IF v_customer IS NULL OR v_customer.linked_user_id IS NULL THEN
    RAISE NOTICE '[create_mirror_movement_v2] العميل غير مرتبط بمستخدم';
    RETURN NULL;
  END IF;

  SELECT id INTO v_linked_customer_id
  FROM customers
  WHERE user_id = v_customer.linked_user_id
    AND linked_user_id = v_customer.user_id
  LIMIT 1;

  IF v_linked_customer_id IS NULL THEN
    SELECT user_name INTO v_original_creator_name
    FROM app_security
    WHERE id = v_customer.user_id
    LIMIT 1;

    INSERT INTO customers (
      user_id,
      name,
      account_number,
      linked_user_id
    ) VALUES (
      v_customer.linked_user_id,
      COALESCE(v_original_creator_name, 'الطرف المقابل'),
      v_customer.account_number,
      v_customer.user_id
    )
    RETURNING id INTO v_linked_customer_id;

    v_customer_was_created := true;
    RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء العميل المتبادل: %', v_linked_customer_id;
  END IF;

  IF v_original_movement.movement_type = 'outgoing' THEN
    v_mirror_type := 'incoming';
    v_mirror_needs_approval := true;
    v_mirror_approval_status := 'pending';
  ELSE
    v_mirror_type := 'outgoing';
    v_mirror_needs_approval := false;
    v_mirror_approval_status := 'approved';
  END IF;

  INSERT INTO account_movements (
    customer_id,
    movement_type,
    amount,
    currency,
    notes,
    commission,
    commission_currency,
    commission_recipient_id,
    created_by_user_id,
    mirror_movement_id,
    pending_approval,
    approval_status,
    is_voided
  ) VALUES (
    v_linked_customer_id,
    v_mirror_type,
    v_original_movement.amount,
    v_original_movement.currency,
    v_original_movement.notes,
    v_original_movement.commission,
    v_original_movement.commission_currency,
    v_original_movement.commission_recipient_id,
    v_original_movement.created_by_user_id,
    p_movement_id,
    v_mirror_needs_approval,
    v_mirror_approval_status,
    false
  )
  RETURNING id INTO v_mirror_movement_id;

  UPDATE account_movements
  SET mirror_movement_id = v_mirror_movement_id
  WHERE id = p_movement_id;

  IF v_mirror_needs_approval THEN
    PERFORM create_notification(
      v_mirror_movement_id,
      v_customer.linked_user_id,
      'approval_needed',
      'حركة جديدة تنتظر موافقتك من ' || v_customer.name,
      v_original_movement.movement_number,
      v_original_movement.amount,
      v_original_movement.currency,
      v_customer.name,
      v_customer.name,
      v_original_movement.movement_type,
      NULL
    );
  END IF;

  RAISE NOTICE '[create_mirror_movement_v2] تم إنشاء الحركة المرآة: %', v_mirror_movement_id;
  RETURN v_mirror_movement_id;
END;
$$;

COMMENT ON FUNCTION create_mirror_movement_v2 IS
  'Create linked-account mirror movement without copying receipt_number; preserve approval logic';

-- ---------------------------------------------------------------------------
-- 2) customer_balances_by_currency
--    Only approved, non-voided, non-commission movements affect balances.
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
-- 3) user_linked_accounts
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
-- 4) get_customer_movements_with_user
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
