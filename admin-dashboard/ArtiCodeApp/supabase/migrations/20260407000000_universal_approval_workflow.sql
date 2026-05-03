/*
  Universal approval workflow for all inter-party account movements.

  Guarantees:
  - approval_status is the primary source of truth.
  - pending_approval stays synchronized for backward compatibility.
  - notes are mandatory for every movement insert/update.
  - linked-counterparty movements stay pending for both parties until approval.
  - pending/rejected/voided movements never affect aggregate views.
  - internal transfers follow the same rule per affected counterparty.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Backfill and synchronize approval state
-- ---------------------------------------------------------------------------
UPDATE account_movements
SET
  approval_status = COALESCE(
    approval_status,
    CASE
      WHEN COALESCE(pending_approval, false) THEN 'pending'
      ELSE 'approved'
    END
  ),
  pending_approval = CASE
    WHEN COALESCE(
      approval_status,
      CASE
        WHEN COALESCE(pending_approval, false) THEN 'pending'
        ELSE 'approved'
      END
    ) = 'pending' THEN true
    ELSE false
  END
WHERE approval_status IS NULL
   OR pending_approval IS DISTINCT FROM (
     CASE
       WHEN COALESCE(
         approval_status,
         CASE
           WHEN COALESCE(pending_approval, false) THEN 'pending'
           ELSE 'approved'
         END
       ) = 'pending' THEN true
       ELSE false
     END
   );

CREATE OR REPLACE FUNCTION sync_account_movement_approval_state()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_status text;
BEGIN
  v_status := NULLIF(trim(COALESCE(NEW.approval_status, '')), '');

  IF v_status IS NULL THEN
    v_status := CASE
      WHEN COALESCE(NEW.pending_approval, false) THEN 'pending'
      ELSE 'approved'
    END;
  END IF;

  IF v_status NOT IN ('pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'Invalid approval status: %', v_status;
  END IF;

  NEW.approval_status := v_status;
  NEW.pending_approval := (v_status = 'pending');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_sync_account_movement_approval_state ON account_movements;
CREATE TRIGGER trigger_sync_account_movement_approval_state
  BEFORE INSERT OR UPDATE ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION sync_account_movement_approval_state();

CREATE OR REPLACE FUNCTION enforce_account_movement_notes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NULLIF(trim(COALESCE(NEW.notes, '')), '') IS NULL THEN
    RAISE EXCEPTION 'الملاحظة مطلوبة';
  END IF;

  NEW.notes := trim(NEW.notes);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_enforce_account_movement_notes ON account_movements;
CREATE TRIGGER trigger_enforce_account_movement_notes
  BEFORE INSERT OR UPDATE ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION enforce_account_movement_notes();

-- ---------------------------------------------------------------------------
-- 2) Movement creation RPC
-- ---------------------------------------------------------------------------
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
  SELECT id, full_name
  INTO v_user_id, v_user_full_name
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT *
  INTO v_customer
  FROM customers
  WHERE id = p_customer_id;

  IF v_customer IS NULL THEN
    RAISE EXCEPTION 'Customer not found: %', p_customer_id;
  END IF;

  v_notes := NULLIF(trim(COALESCE(p_notes, '')), '');

  IF v_notes IS NULL THEN
    RAISE EXCEPTION 'الملاحظة مطلوبة';
  END IF;

  IF v_customer.linked_user_id IS NOT NULL
     AND v_customer.linked_user_id <> v_user_id THEN
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
    NULLIF(trim(COALESCE(p_sender_name, '')), ''),
    NULLIF(trim(COALESCE(p_beneficiary_name, '')), ''),
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
