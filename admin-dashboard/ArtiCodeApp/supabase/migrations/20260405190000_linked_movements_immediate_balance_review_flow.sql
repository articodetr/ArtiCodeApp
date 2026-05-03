/*
  Linked movements review flow:
  - Outgoing linked movement is recorded immediately and included in totals.
  - Receiver gets approval_needed notification.
  - approve_movement only updates state to approved.
  - reject_movement_with_reason requires reason and removes financial effect by setting rejected.
  - Pending + approved are counted in totals, rejected is excluded.
*/

BEGIN;

-- Keep notification types compatible with current and legacy flows.
ALTER TABLE movement_notifications
  DROP CONSTRAINT IF EXISTS valid_notification_type;

ALTER TABLE movement_notifications
  DROP CONSTRAINT IF EXISTS movement_notifications_notification_type_check;

ALTER TABLE movement_notifications
  ADD CONSTRAINT movement_notifications_notification_type_check
  CHECK (
    notification_type IN (
      'approval_needed',
      'deletion_request',
      'movement_added',
      'movement_approved',
      'movement_rejected',
      'movement_deleted',
      'approved',
      'rejected',
      'customer_added',
      'linked_account_added',
      'payment_reminder'
    )
  );

CREATE OR REPLACE FUNCTION insert_movement_with_user(
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
BEGIN
  SELECT u.id, u.full_name
  INTO v_user_id, v_user_full_name
  FROM app_security u
  WHERE u.user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT *
  INTO v_customer
  FROM customers
  WHERE customers.id = p_customer_id;

  IF v_customer IS NULL THEN
    RAISE EXCEPTION 'Customer not found: %', p_customer_id;
  END IF;

  -- Linked-account outgoing movements require receiver review, but still count immediately.
  IF v_customer.linked_user_id IS NOT NULL AND p_movement_type = 'outgoing' THEN
    v_needs_approval := true;
    v_approval_status := 'pending';
  END IF;

  v_movement_number := generate_movement_number();

  INSERT INTO account_movements (
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
    p_notes,
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
  v_actor_name text;
BEGIN
  SELECT *
  INTO v_original_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF v_original_movement IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT *
  INTO v_customer
  FROM customers
  WHERE id = v_original_movement.customer_id;

  IF v_customer IS NULL OR v_customer.linked_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT id
  INTO v_linked_customer_id
  FROM customers
  WHERE user_id = v_customer.linked_user_id
    AND linked_user_id = v_customer.user_id
  LIMIT 1;

  IF v_linked_customer_id IS NULL THEN
    INSERT INTO customers (user_id, name, account_number, linked_user_id)
    VALUES (
      v_customer.linked_user_id,
      COALESCE(v_original_movement.created_by_user_name, 'الطرف المقابل'),
      v_customer.account_number,
      v_customer.user_id
    )
    RETURNING id INTO v_linked_customer_id;
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
    source_user_id,
    created_by_user_id,
    created_by_user_name,
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
    v_original_movement.source_user_id,
    v_original_movement.created_by_user_id,
    v_original_movement.created_by_user_name,
    p_movement_id,
    v_mirror_needs_approval,
    v_mirror_approval_status,
    false
  )
  RETURNING id INTO v_mirror_movement_id;

  UPDATE account_movements
  SET mirror_movement_id = v_mirror_movement_id
  WHERE id = p_movement_id;

  v_actor_name := COALESCE(v_original_movement.created_by_user_name, 'الطرف الآخر');

  IF v_mirror_needs_approval THEN
    PERFORM create_notification(
      v_mirror_movement_id,
      v_customer.linked_user_id,
      'approval_needed',
      format(
        'قيّد عليك %s مبلغ %s %s',
        v_actor_name,
        trim(to_char(v_original_movement.amount, 'FM999999999990.00')),
        v_original_movement.currency
      ),
      v_original_movement.movement_number,
      v_original_movement.amount,
      v_original_movement.currency,
      v_customer.name,
      v_actor_name,
      v_original_movement.movement_type,
      NULL
    );
  END IF;

  RETURN v_mirror_movement_id;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_create_mirror_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NEW.mirror_movement_id IS NULL THEN
    PERFORM create_mirror_movement_v2(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION approve_movement(
  p_movement_id uuid,
  p_user_name text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_movement record;
  v_pair_id uuid;
  v_creator_user_id uuid;
BEGIN
  SELECT id INTO v_user_id
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT am.*, c.user_id AS customer_owner_id
  INTO v_movement
  FROM account_movements am
  JOIN customers c ON c.id = am.customer_id
  WHERE am.id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  IF v_movement.approval_status <> 'pending' THEN
    RAISE EXCEPTION 'Movement is not pending approval';
  END IF;

  IF v_movement.customer_owner_id <> v_user_id THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  v_pair_id := COALESCE(
    v_movement.mirror_movement_id,
    (SELECT am.id FROM account_movements am WHERE am.mirror_movement_id = v_movement.id LIMIT 1)
  );

  UPDATE account_movements
  SET
    approval_status = 'approved',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now()
  WHERE id = v_movement.id OR (v_pair_id IS NOT NULL AND id = v_pair_id);

  v_creator_user_id := COALESCE(
    v_movement.created_by_user_id,
    (SELECT created_by_user_id FROM account_movements WHERE id = v_pair_id)
  );

  IF v_creator_user_id IS NOT NULL AND v_creator_user_id <> v_user_id THEN
    PERFORM create_notification(
      v_movement.id,
      v_creator_user_id,
      'movement_approved',
      format('تم قبول الحركة من %s', p_user_name),
      v_movement.movement_number,
      v_movement.amount,
      v_movement.currency,
      NULL,
      p_user_name,
      v_movement.movement_type,
      NULL
    );
  END IF;

  RETURN json_build_object(
    'success', true,
    'movement_id', p_movement_id,
    'status', 'approved'
  );
END;
$$;

CREATE OR REPLACE FUNCTION reject_movement_with_reason(
  p_movement_id uuid,
  p_user_name text,
  p_reject_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_movement record;
  v_pair_id uuid;
  v_creator_user_id uuid;
BEGIN
  IF COALESCE(trim(p_reject_reason), '') = '' THEN
    RAISE EXCEPTION 'سبب الرفض مطلوب';
  END IF;

  SELECT id INTO v_user_id
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT am.*, c.user_id AS customer_owner_id, c.name AS customer_name
  INTO v_movement
  FROM account_movements am
  JOIN customers c ON c.id = am.customer_id
  WHERE am.id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  IF v_movement.approval_status <> 'pending' THEN
    RAISE EXCEPTION 'Movement is not pending approval';
  END IF;

  IF v_movement.customer_owner_id <> v_user_id THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  v_pair_id := COALESCE(
    v_movement.mirror_movement_id,
    (SELECT am.id FROM account_movements am WHERE am.mirror_movement_id = v_movement.id LIMIT 1)
  );

  UPDATE account_movements
  SET
    approval_status = 'rejected',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now(),
    void_type = 'rejected',
    void_reason = p_reject_reason
  WHERE id = v_movement.id OR (v_pair_id IS NOT NULL AND id = v_pair_id);

  UPDATE account_movements
  SET
    approval_status = 'rejected',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now(),
    void_type = 'rejected',
    void_reason = p_reject_reason
  WHERE related_commission_movement_id = v_movement.id
     OR (v_pair_id IS NOT NULL AND related_commission_movement_id = v_pair_id);

  DELETE FROM movement_notifications
  WHERE user_id = v_user_id
    AND notification_type = 'approval_needed'
    AND (movement_id = v_movement.id OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id));

  v_creator_user_id := COALESCE(
    v_movement.created_by_user_id,
    (SELECT created_by_user_id FROM account_movements WHERE id = v_pair_id)
  );

  IF v_creator_user_id IS NOT NULL AND v_creator_user_id <> v_user_id THEN
    PERFORM create_notification(
      v_movement.id,
      v_creator_user_id,
      'movement_rejected',
      format('تم رفض الحركة من %s', p_user_name),
      v_movement.movement_number,
      v_movement.amount,
      v_movement.currency,
      v_movement.customer_name,
      p_user_name,
      v_movement.movement_type,
      jsonb_build_object(
        'reject_reason', p_reject_reason,
        'rejected_by', p_user_name,
        'rejected_at', now()
      )
    );
  END IF;

  RETURN json_build_object(
    'success', true,
    'movement_id', p_movement_id,
    'status', 'rejected',
    'reject_reason', p_reject_reason
  );
END;
$$;

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
  ) <> 0;

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

CREATE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  c.user_id,
  c.linked_user_id,
  am.currency,
  COALESCE(
    SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END),
    0
  ) AS total_incoming,
  COALESCE(
    SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END),
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

GRANT SELECT ON customer_balances_by_currency TO authenticated, anon;
GRANT SELECT ON user_linked_accounts TO authenticated;

COMMIT;
