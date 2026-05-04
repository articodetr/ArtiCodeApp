/*
  Finalize linked movement review flow so that:
  - Any linked movement starts pending for both parties.
  - The creator gets a "waiting" notification immediately.
  - Only the counterparty can approve/reject the pending request.
  - Creator-side pending notifications are replaced with the final decision.
*/

BEGIN;

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
  v_notes text;
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

  v_notes := NULLIF(trim(COALESCE(p_notes, '')), '');

  IF v_notes IS NULL THEN
    RAISE EXCEPTION 'الملاحظة مطلوبة';
  END IF;

  IF v_customer.linked_user_id IS NOT NULL THEN
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

  IF v_needs_approval THEN
    PERFORM create_notification(
      v_movement_id,
      v_user_id,
      'movement_added',
      format(
        'تم تسجيل حركة %s مع %s بانتظار موافقة الطرف الآخر',
        CASE
          WHEN p_movement_type = 'incoming' THEN 'له'
          ELSE 'عليه'
        END,
        COALESCE(v_customer.name, 'الطرف الآخر')
      ),
      v_movement_number,
      p_amount,
      p_currency,
      v_customer.name,
      NULL,
      p_movement_type,
      jsonb_build_object(
        'approval_status', 'pending',
        'requires_action', false
      )
    );
  END IF;

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
  v_user_full_name text;
  v_movement record;
  v_pair_id uuid;
  v_creator_user_id uuid;
  v_creator_movement_id uuid;
  v_creator_movement_number text;
  v_creator_movement_amount numeric;
  v_creator_movement_currency text;
  v_creator_movement_type text;
  v_creator_customer_name text;
BEGIN
  SELECT id, full_name
  INTO v_user_id, v_user_full_name
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

  IF COALESCE(v_movement.source_user_id, v_movement.created_by_user_id) = v_user_id THEN
    RAISE EXCEPTION 'لا يمكن لمنشئ الحركة اعتمادها بنفسه';
  END IF;

  v_pair_id := COALESCE(
    v_movement.mirror_movement_id,
    (SELECT am.id FROM account_movements am WHERE am.mirror_movement_id = v_movement.id LIMIT 1)
  );

  v_creator_user_id := COALESCE(
    v_movement.created_by_user_id,
    (SELECT created_by_user_id FROM account_movements WHERE id = v_pair_id)
  );

  SELECT
    am.id,
    am.movement_number,
    am.amount,
    am.currency,
    am.movement_type,
    c.name AS customer_name
  INTO
    v_creator_movement_id,
    v_creator_movement_number,
    v_creator_movement_amount,
    v_creator_movement_currency,
    v_creator_movement_type,
    v_creator_customer_name
  FROM account_movements am
  JOIN customers c ON c.id = am.customer_id
  WHERE am.id IN (v_movement.id, v_pair_id)
    AND c.user_id = v_creator_user_id
  LIMIT 1;

  IF v_creator_movement_id IS NULL THEN
    SELECT
      am.id,
      am.movement_number,
      am.amount,
      am.currency,
      am.movement_type,
      c.name AS customer_name
    INTO
      v_creator_movement_id,
      v_creator_movement_number,
      v_creator_movement_amount,
      v_creator_movement_currency,
      v_creator_movement_type,
      v_creator_customer_name
    FROM account_movements am
    JOIN customers c ON c.id = am.customer_id
    WHERE am.id = COALESCE(v_pair_id, v_movement.id)
    LIMIT 1;
  END IF;

  UPDATE account_movements
  SET
    approval_status = 'approved',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now()
  WHERE id = v_movement.id OR (v_pair_id IS NOT NULL AND id = v_pair_id);

  UPDATE account_movements
  SET
    approval_status = 'approved',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now()
  WHERE related_commission_movement_id = v_movement.id
     OR (v_pair_id IS NOT NULL AND related_commission_movement_id = v_pair_id);

  DELETE FROM movement_notifications
  WHERE notification_type = 'approval_needed'
    AND (movement_id = v_movement.id OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id));

  IF v_creator_user_id IS NOT NULL THEN
    DELETE FROM movement_notifications
    WHERE user_id = v_creator_user_id
      AND notification_type = 'movement_added'
      AND (
        movement_id = v_movement.id
        OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id)
        OR (v_creator_movement_id IS NOT NULL AND movement_id = v_creator_movement_id)
      );
  END IF;

  IF v_creator_user_id IS NOT NULL AND v_creator_user_id <> v_user_id THEN
    PERFORM create_notification(
      COALESCE(v_creator_movement_id, v_pair_id, v_movement.id),
      v_creator_user_id,
      'movement_approved',
      format('تم اعتماد الحركة من %s', COALESCE(v_user_full_name, p_user_name)),
      COALESCE(v_creator_movement_number, v_movement.movement_number),
      COALESCE(v_creator_movement_amount, v_movement.amount),
      COALESCE(v_creator_movement_currency, v_movement.currency),
      COALESCE(v_creator_customer_name, v_movement.customer_name),
      COALESCE(v_user_full_name, p_user_name),
      COALESCE(v_creator_movement_type, v_movement.movement_type),
      jsonb_build_object(
        'approval_status', 'approved',
        'approved_by', p_user_name,
        'approved_at', now()
      )
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
  v_user_full_name text;
  v_movement record;
  v_pair_id uuid;
  v_creator_user_id uuid;
  v_creator_movement_id uuid;
  v_creator_movement_number text;
  v_creator_movement_amount numeric;
  v_creator_movement_currency text;
  v_creator_movement_type text;
  v_creator_customer_name text;
BEGIN
  IF COALESCE(trim(p_reject_reason), '') = '' THEN
    RAISE EXCEPTION 'سبب الرفض مطلوب';
  END IF;

  SELECT id, full_name
  INTO v_user_id, v_user_full_name
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

  IF COALESCE(v_movement.source_user_id, v_movement.created_by_user_id) = v_user_id THEN
    RAISE EXCEPTION 'لا يمكن لمنشئ الحركة رفضها بنفسه';
  END IF;

  v_pair_id := COALESCE(
    v_movement.mirror_movement_id,
    (SELECT am.id FROM account_movements am WHERE am.mirror_movement_id = v_movement.id LIMIT 1)
  );

  v_creator_user_id := COALESCE(
    v_movement.created_by_user_id,
    (SELECT created_by_user_id FROM account_movements WHERE id = v_pair_id)
  );

  SELECT
    am.id,
    am.movement_number,
    am.amount,
    am.currency,
    am.movement_type,
    c.name AS customer_name
  INTO
    v_creator_movement_id,
    v_creator_movement_number,
    v_creator_movement_amount,
    v_creator_movement_currency,
    v_creator_movement_type,
    v_creator_customer_name
  FROM account_movements am
  JOIN customers c ON c.id = am.customer_id
  WHERE am.id IN (v_movement.id, v_pair_id)
    AND c.user_id = v_creator_user_id
  LIMIT 1;

  IF v_creator_movement_id IS NULL THEN
    SELECT
      am.id,
      am.movement_number,
      am.amount,
      am.currency,
      am.movement_type,
      c.name AS customer_name
    INTO
      v_creator_movement_id,
      v_creator_movement_number,
      v_creator_movement_amount,
      v_creator_movement_currency,
      v_creator_movement_type,
      v_creator_customer_name
    FROM account_movements am
    JOIN customers c ON c.id = am.customer_id
    WHERE am.id = COALESCE(v_pair_id, v_movement.id)
    LIMIT 1;
  END IF;

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
  WHERE notification_type = 'approval_needed'
    AND (movement_id = v_movement.id OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id));

  IF v_creator_user_id IS NOT NULL THEN
    DELETE FROM movement_notifications
    WHERE user_id = v_creator_user_id
      AND notification_type = 'movement_added'
      AND (
        movement_id = v_movement.id
        OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id)
        OR (v_creator_movement_id IS NOT NULL AND movement_id = v_creator_movement_id)
      );
  END IF;

  IF v_creator_user_id IS NOT NULL AND v_creator_user_id <> v_user_id THEN
    PERFORM create_notification(
      COALESCE(v_creator_movement_id, v_pair_id, v_movement.id),
      v_creator_user_id,
      'movement_rejected',
      format('تم رفض الحركة من %s', COALESCE(v_user_full_name, p_user_name)),
      COALESCE(v_creator_movement_number, v_movement.movement_number),
      COALESCE(v_creator_movement_amount, v_movement.amount),
      COALESCE(v_creator_movement_currency, v_movement.currency),
      COALESCE(v_creator_customer_name, v_movement.customer_name),
      COALESCE(v_user_full_name, p_user_name),
      COALESCE(v_creator_movement_type, v_movement.movement_type),
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

COMMIT;
