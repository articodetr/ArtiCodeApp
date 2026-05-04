BEGIN;

DO $$
DECLARE
  v_constraint_name text;
BEGIN
  FOR v_constraint_name IN
    SELECT con.conname
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = 'public'
      AND rel.relname = 'movement_notifications'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%notification_type%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.movement_notifications DROP CONSTRAINT IF EXISTS %I',
      v_constraint_name
    );
  END LOOP;
END $$;

ALTER TABLE movement_notifications
  ADD CONSTRAINT movement_notifications_notification_type_check
  CHECK (
    notification_type IN (
      'approval_needed',
      'deletion_request',
      'approved',
      'rejected',
      'movement_added',
      'movement_approved',
      'movement_rejected',
      'customer_added',
      'linked_account_added'
    )
  );

CREATE OR REPLACE FUNCTION get_movement_approval_status(
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

CREATE OR REPLACE FUNCTION movement_requires_counterparty_approval(
  p_customer_id uuid,
  p_actor_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM customers c
    WHERE c.id = p_customer_id
      AND c.linked_user_id IS NOT NULL
      AND c.user_id IS DISTINCT FROM c.linked_user_id
  );
$$;

UPDATE account_movements
SET
  approval_status = get_movement_approval_status(approval_status, pending_approval),
  pending_approval = (get_movement_approval_status(approval_status, pending_approval) = 'pending')
WHERE approval_status IS NULL
   OR pending_approval IS DISTINCT FROM (
     get_movement_approval_status(approval_status, pending_approval) = 'pending'
   );

UPDATE account_movements
SET notes = COALESCE(NULLIF(trim(notes), ''), 'حركة قديمة بدون ملاحظة')
WHERE NULLIF(trim(COALESCE(notes, '')), '') IS NULL;

CREATE OR REPLACE FUNCTION sync_account_movement_approval_state()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_status text;
BEGIN
  v_status := get_movement_approval_status(NEW.approval_status, NEW.pending_approval);
  NEW.approval_status := v_status;
  NEW.pending_approval := (v_status = 'pending');
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
  SELECT id, COALESCE(NULLIF(trim(full_name), ''), user_name)
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

  IF get_movement_approval_status(v_movement.approval_status, v_movement.pending_approval) <> 'pending' THEN
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
    (
      SELECT am.id
      FROM account_movements am
      WHERE am.mirror_movement_id = v_movement.id
      LIMIT 1
    )
  );

  v_creator_user_id := COALESCE(
    v_movement.created_by_user_id,
    (
      SELECT created_by_user_id
      FROM account_movements
      WHERE id = v_pair_id
    )
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
    approved_at = now(),
    reject_reason = NULL,
    void_type = CASE WHEN void_type = 'rejected' THEN NULL ELSE void_type END,
    void_reason = CASE WHEN void_type = 'rejected' THEN NULL ELSE void_reason END
  WHERE id = v_movement.id
     OR (v_pair_id IS NOT NULL AND id = v_pair_id);

  UPDATE account_movements
  SET
    approval_status = 'approved',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now(),
    reject_reason = NULL,
    void_type = CASE WHEN void_type = 'rejected' THEN NULL ELSE void_type END,
    void_reason = CASE WHEN void_type = 'rejected' THEN NULL ELSE void_reason END
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
      format('تمت الموافقة على الحركة من %s', COALESCE(v_user_full_name, p_user_name)),
      COALESCE(v_creator_movement_number, v_movement.movement_number),
      COALESCE(v_creator_movement_amount, v_movement.amount),
      COALESCE(v_creator_movement_currency, v_movement.currency),
      COALESCE(v_creator_customer_name, v_movement.customer_name),
      COALESCE(v_user_full_name, p_user_name),
      COALESCE(v_creator_movement_type, v_movement.movement_type),
      jsonb_build_object(
        'approval_status', 'approved',
        'approved_by', p_user_name,
        'approved_at', now(),
        'requires_action', false
      )
    );
  END IF;

  PERFORM create_notification(
    p_movement_id,
    v_user_id,
    'movement_approved',
    'تمت الموافقة على الحركة وأصبحت ضمن الإجماليات',
    v_movement.movement_number,
    v_movement.amount,
    v_movement.currency,
    v_movement.customer_name,
    COALESCE(v_user_full_name, p_user_name),
    v_movement.movement_type,
    jsonb_build_object(
      'approval_status', 'approved',
      'approved_by', p_user_name,
      'approved_at', now(),
      'requires_action', false
    )
  );

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
  v_reason text;
BEGIN
  v_reason := NULLIF(trim(COALESCE(p_reject_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'سبب الرفض مطلوب';
  END IF;

  SELECT id, COALESCE(NULLIF(trim(full_name), ''), user_name)
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

  IF get_movement_approval_status(v_movement.approval_status, v_movement.pending_approval) <> 'pending' THEN
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
    (
      SELECT am.id
      FROM account_movements am
      WHERE am.mirror_movement_id = v_movement.id
      LIMIT 1
    )
  );

  v_creator_user_id := COALESCE(
    v_movement.created_by_user_id,
    (
      SELECT created_by_user_id
      FROM account_movements
      WHERE id = v_pair_id
    )
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
    reject_reason = v_reason,
    void_type = 'rejected',
    void_reason = v_reason
  WHERE id = v_movement.id
     OR (v_pair_id IS NOT NULL AND id = v_pair_id);

  UPDATE account_movements
  SET
    approval_status = 'rejected',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = now(),
    reject_reason = v_reason,
    void_type = 'rejected',
    void_reason = v_reason
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
        'approval_status', 'rejected',
        'reject_reason', v_reason,
        'rejected_by', p_user_name,
        'rejected_at', now(),
        'requires_action', false
      )
    );
  END IF;

  PERFORM create_notification(
    p_movement_id,
    v_user_id,
    'movement_rejected',
    'تم رفض الحركة ولن تدخل في الإجماليات',
    v_movement.movement_number,
    v_movement.amount,
    v_movement.currency,
    v_movement.customer_name,
    COALESCE(v_user_full_name, p_user_name),
    v_movement.movement_type,
    jsonb_build_object(
      'approval_status', 'rejected',
      'reject_reason', v_reason,
      'rejected_by', p_user_name,
      'rejected_at', now(),
      'requires_action', false
    )
  );

  RETURN json_build_object(
    'success', true,
    'movement_id', p_movement_id,
    'status', 'rejected',
    'reject_reason', v_reason
  );
END;
$$;

DROP FUNCTION IF EXISTS create_internal_transfer(uuid, uuid, numeric, text, text, numeric, text, uuid);

CREATE OR REPLACE FUNCTION create_internal_transfer(
  p_from_customer_id uuid,
  p_to_customer_id uuid,
  p_amount decimal,
  p_currency text,
  p_notes text DEFAULT NULL,
  p_commission decimal DEFAULT NULL,
  p_commission_currency text DEFAULT 'USD',
  p_commission_recipient_id uuid DEFAULT NULL,
  p_user_name text DEFAULT NULL
)
RETURNS TABLE (
  from_movement_id uuid,
  to_movement_id uuid,
  success boolean,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_user_full_name text;
  v_notes text;
  v_from_movement_id uuid;
  v_to_movement_id uuid;
  v_from_movement_number text;
  v_to_movement_number text;
  v_transfer_direction text;
  v_from_customer record;
  v_to_customer record;
  v_actual_to_amount decimal;
  v_actual_from_amount decimal;
  v_from_approval_required boolean := false;
  v_to_approval_required boolean := false;
  v_from_status text := 'approved';
  v_to_status text := 'approved';
  v_any_pending boolean := false;
  v_result_message text;
BEGIN
  SELECT id, COALESCE(NULLIF(trim(full_name), ''), user_name)
  INTO v_user_id, v_user_full_name
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'المستخدم غير موجود'::text;
    RETURN;
  END IF;

  v_notes := NULLIF(trim(COALESCE(p_notes, '')), '');
  IF v_notes IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'الملاحظة مطلوبة لكل حركة'::text;
    RETURN;
  END IF;

  IF COALESCE(p_amount, 0) <= 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'المبلغ يجب أن يكون أكبر من صفر'::text;
    RETURN;
  END IF;

  IF p_commission IS NOT NULL AND p_commission < 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العمولة يجب أن تكون صفر أو أكبر'::text;
    RETURN;
  END IF;

  IF p_commission IS NOT NULL AND p_commission >= p_amount THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العمولة لا يمكن أن تكون أكبر من أو تساوي المبلغ'::text;
    RETURN;
  END IF;

  IF p_from_customer_id IS NOT NULL
     AND p_to_customer_id IS NOT NULL
     AND p_from_customer_id = p_to_customer_id THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'لا يمكن التحويل لنفس العميل'::text;
    RETURN;
  END IF;

  IF p_commission_recipient_id IS NOT NULL THEN
    IF p_commission_recipient_id <> p_from_customer_id
       AND p_commission_recipient_id <> p_to_customer_id THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'مستلم العمولة يجب أن يكون أحد أطراف التحويل'::text;
      RETURN;
    END IF;
  END IF;

  IF p_from_customer_id IS NULL AND p_to_customer_id IS NOT NULL THEN
    v_transfer_direction := 'shop_to_customer';
  ELSIF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NULL THEN
    v_transfer_direction := 'customer_to_shop';
  ELSIF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NOT NULL THEN
    v_transfer_direction := 'customer_to_customer';
  ELSE
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'يجب تحديد طرف واحد على الأقل'::text;
    RETURN;
  END IF;

  IF p_from_customer_id IS NOT NULL THEN
    SELECT *
    INTO v_from_customer
    FROM customers
    WHERE id = p_from_customer_id;

    IF v_from_customer IS NULL THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العميل المُحوِّل غير موجود'::text;
      RETURN;
    END IF;
  END IF;

  IF p_to_customer_id IS NOT NULL THEN
    SELECT *
    INTO v_to_customer
    FROM customers
    WHERE id = p_to_customer_id;

    IF v_to_customer IS NULL THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العميل المُحوَّل إليه غير موجود'::text;
      RETURN;
    END IF;
  END IF;

  IF p_from_customer_id IS NOT NULL THEN
    v_from_approval_required := movement_requires_counterparty_approval(p_from_customer_id, v_user_id);
    v_from_status := CASE WHEN v_from_approval_required THEN 'pending' ELSE 'approved' END;
  END IF;

  IF p_to_customer_id IS NOT NULL THEN
    v_to_approval_required := movement_requires_counterparty_approval(p_to_customer_id, v_user_id);
    v_to_status := CASE WHEN v_to_approval_required THEN 'pending' ELSE 'approved' END;
  END IF;

  v_any_pending := v_from_approval_required OR v_to_approval_required;

  IF p_commission IS NOT NULL AND p_commission > 0 THEN
    IF p_commission_recipient_id = p_from_customer_id THEN
      v_actual_from_amount := p_amount - p_commission;
    ELSE
      v_actual_from_amount := p_amount;
    END IF;
  ELSE
    v_actual_from_amount := p_amount;
  END IF;

  IF p_commission IS NOT NULL AND p_commission > 0 THEN
    IF p_commission_recipient_id IS NULL THEN
      v_actual_to_amount := p_amount - p_commission;
    ELSIF p_commission_recipient_id = p_to_customer_id THEN
      v_actual_to_amount := p_amount + p_commission;
    ELSE
      v_actual_to_amount := p_amount;
    END IF;
  ELSE
    v_actual_to_amount := p_amount;
  END IF;

  BEGIN
    IF v_transfer_direction = 'shop_to_customer' THEN
      v_to_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
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
        approved_by_user_id,
        approved_at,
        is_voided
      ) VALUES (
        v_to_movement_number,
        p_to_customer_id,
        'incoming',
        v_actual_to_amount,
        p_currency,
        v_notes,
        NULL,
        p_to_customer_id,
        v_transfer_direction,
        'المحل',
        COALESCE(v_to_customer.name, 'العميل'),
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id,
        v_user_id,
        v_user_id,
        v_user_full_name,
        v_to_approval_required,
        v_to_status,
        CASE WHEN v_to_status = 'approved' THEN v_user_id ELSE NULL END,
        CASE WHEN v_to_status = 'approved' THEN now() ELSE NULL END,
        false
      )
      RETURNING id INTO v_to_movement_id;

      IF v_to_approval_required THEN
        PERFORM create_notification(
          v_to_movement_id,
          v_user_id,
          'movement_added',
          format('تم تسجيل حركة له مع %s بانتظار موافقة الطرف الآخر', COALESCE(v_to_customer.name, 'الطرف الآخر')),
          v_to_movement_number,
          v_actual_to_amount,
          p_currency,
          COALESCE(v_to_customer.name, 'الطرف الآخر'),
          NULL,
          'incoming',
          jsonb_build_object('approval_status', 'pending', 'requires_action', false)
        );
      END IF;

    ELSIF v_transfer_direction = 'customer_to_shop' THEN
      v_from_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
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
        approved_by_user_id,
        approved_at,
        is_voided
      ) VALUES (
        v_from_movement_number,
        p_from_customer_id,
        'outgoing',
        v_actual_from_amount,
        p_currency,
        v_notes,
        p_from_customer_id,
        NULL,
        v_transfer_direction,
        COALESCE(v_from_customer.name, 'العميل'),
        'المحل',
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id,
        v_user_id,
        v_user_id,
        v_user_full_name,
        v_from_approval_required,
        v_from_status,
        CASE WHEN v_from_status = 'approved' THEN v_user_id ELSE NULL END,
        CASE WHEN v_from_status = 'approved' THEN now() ELSE NULL END,
        false
      )
      RETURNING id INTO v_from_movement_id;

      IF v_from_approval_required THEN
        PERFORM create_notification(
          v_from_movement_id,
          v_user_id,
          'movement_added',
          format('تم تسجيل حركة عليه مع %s بانتظار موافقة الطرف الآخر', COALESCE(v_from_customer.name, 'الطرف الآخر')),
          v_from_movement_number,
          v_actual_from_amount,
          p_currency,
          COALESCE(v_from_customer.name, 'الطرف الآخر'),
          NULL,
          'outgoing',
          jsonb_build_object('approval_status', 'pending', 'requires_action', false)
        );
      END IF;

    ELSE
      v_from_movement_number := generate_movement_number();
      v_to_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
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
        approved_by_user_id,
        approved_at,
        is_voided
      ) VALUES (
        v_from_movement_number,
        p_from_customer_id,
        'outgoing',
        v_actual_from_amount,
        p_currency,
        v_notes,
        p_from_customer_id,
        p_to_customer_id,
        v_transfer_direction,
        COALESCE(v_from_customer.name, 'العميل'),
        COALESCE(v_to_customer.name, 'العميل'),
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id,
        v_user_id,
        v_user_id,
        v_user_full_name,
        v_from_approval_required,
        v_from_status,
        CASE WHEN v_from_status = 'approved' THEN v_user_id ELSE NULL END,
        CASE WHEN v_from_status = 'approved' THEN now() ELSE NULL END,
        false
      )
      RETURNING id INTO v_from_movement_id;

      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        related_transfer_id,
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
        approved_by_user_id,
        approved_at,
        is_voided
      ) VALUES (
        v_to_movement_number,
        p_to_customer_id,
        'incoming',
        v_actual_to_amount,
        p_currency,
        v_notes,
        p_from_customer_id,
        p_to_customer_id,
        v_transfer_direction,
        v_from_movement_id,
        COALESCE(v_from_customer.name, 'العميل'),
        COALESCE(v_to_customer.name, 'العميل'),
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id,
        v_user_id,
        v_user_id,
        v_user_full_name,
        v_to_approval_required,
        v_to_status,
        CASE WHEN v_to_status = 'approved' THEN v_user_id ELSE NULL END,
        CASE WHEN v_to_status = 'approved' THEN now() ELSE NULL END,
        false
      )
      RETURNING id INTO v_to_movement_id;

      UPDATE account_movements
      SET related_transfer_id = v_to_movement_id
      WHERE id = v_from_movement_id;

      IF v_from_approval_required THEN
        PERFORM create_notification(
          v_from_movement_id,
          v_user_id,
          'movement_added',
          format('تم تسجيل حركة عليه مع %s بانتظار موافقة الطرف الآخر', COALESCE(v_from_customer.name, 'الطرف الآخر')),
          v_from_movement_number,
          v_actual_from_amount,
          p_currency,
          COALESCE(v_from_customer.name, 'الطرف الآخر'),
          NULL,
          'outgoing',
          jsonb_build_object('approval_status', 'pending', 'requires_action', false)
        );
      END IF;

      IF v_to_approval_required THEN
        PERFORM create_notification(
          v_to_movement_id,
          v_user_id,
          'movement_added',
          format('تم تسجيل حركة له مع %s بانتظار موافقة الطرف الآخر', COALESCE(v_to_customer.name, 'الطرف الآخر')),
          v_to_movement_number,
          v_actual_to_amount,
          p_currency,
          COALESCE(v_to_customer.name, 'الطرف الآخر'),
          NULL,
          'incoming',
          jsonb_build_object('approval_status', 'pending', 'requires_action', false)
        );
      END IF;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, ('خطأ في إنشاء التحويل: ' || SQLERRM)::text;
      RETURN;
  END;

  IF v_any_pending THEN
    v_result_message := 'تم تسجيل التحويل وبانتظار موافقة الطرف الآخر قبل احتسابه في الإجماليات';
  ELSIF v_transfer_direction = 'shop_to_customer' THEN
    v_result_message := 'تم التحويل بنجاح من المحل إلى ' || COALESCE(v_to_customer.name, 'العميل');
  ELSIF v_transfer_direction = 'customer_to_shop' THEN
    v_result_message := 'تم التحويل بنجاح من ' || COALESCE(v_from_customer.name, 'العميل') || ' إلى المحل';
  ELSE
    v_result_message := 'تم التحويل بنجاح من ' || COALESCE(v_from_customer.name, 'العميل')
      || ' إلى ' || COALESCE(v_to_customer.name, 'العميل');
  END IF;

  RETURN QUERY SELECT v_from_movement_id, v_to_movement_id, true, v_result_message::text;
END;
$$;

CREATE OR REPLACE FUNCTION record_commission_to_profit_loss()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_profit_loss_id uuid;
  v_commission_movement_id uuid;
  v_recipient_movement_id uuid;
BEGIN
  IF COALESCE(NEW.is_commission_movement, false) OR COALESCE(NEW.is_voided, false) THEN
    RETURN NEW;
  END IF;

  IF NEW.commission IS NULL OR NEW.commission <= 0 THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_profit_loss_id
  FROM customers
  WHERE phone = 'PROFIT_LOSS_ACCOUNT';

  IF v_profit_loss_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.commission_recipient_id IS NOT NULL THEN
    IF NEW.commission_recipient_id <> NEW.to_customer_id THEN
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        is_commission_movement,
        related_commission_movement_id,
        source_user_id,
        created_by_user_id,
        created_by_user_name,
        pending_approval,
        approval_status,
        approved_by_user_id,
        approved_at,
        reject_reason,
        void_type,
        void_reason,
        is_voided
      ) VALUES (
        generate_movement_number(),
        NEW.commission_recipient_id,
        'incoming',
        NEW.commission,
        NEW.commission_currency,
        'عمولة من حركة ' || NEW.movement_number,
        true,
        NEW.id,
        NEW.source_user_id,
        NEW.created_by_user_id,
        NEW.created_by_user_name,
        (get_movement_approval_status(NEW.approval_status, NEW.pending_approval) = 'pending'),
        get_movement_approval_status(NEW.approval_status, NEW.pending_approval),
        NEW.approved_by_user_id,
        NEW.approved_at,
        NEW.reject_reason,
        NEW.void_type,
        NEW.void_reason,
        COALESCE(NEW.is_voided, false)
      )
      RETURNING id INTO v_recipient_movement_id;
    END IF;

    INSERT INTO account_movements (
      movement_number,
      customer_id,
      movement_type,
      amount,
      currency,
      notes,
      is_commission_movement,
      related_commission_movement_id,
      source_user_id,
      created_by_user_id,
      created_by_user_name,
      pending_approval,
      approval_status,
      approved_by_user_id,
      approved_at,
      reject_reason,
      void_type,
      void_reason,
      is_voided
    ) VALUES (
      generate_movement_number(),
      v_profit_loss_id,
      'outgoing',
      NEW.commission,
      NEW.commission_currency,
      'دفع عمولة للحركة ' || NEW.movement_number,
      true,
      NEW.id,
      NEW.source_user_id,
      NEW.created_by_user_id,
      NEW.created_by_user_name,
      (get_movement_approval_status(NEW.approval_status, NEW.pending_approval) = 'pending'),
      get_movement_approval_status(NEW.approval_status, NEW.pending_approval),
      NEW.approved_by_user_id,
      NEW.approved_at,
      NEW.reject_reason,
      NEW.void_type,
      NEW.void_reason,
      COALESCE(NEW.is_voided, false)
    )
    RETURNING id INTO v_commission_movement_id;
  ELSE
    INSERT INTO account_movements (
      movement_number,
      customer_id,
      movement_type,
      amount,
      currency,
      notes,
      is_commission_movement,
      related_commission_movement_id,
      source_user_id,
      created_by_user_id,
      created_by_user_name,
      pending_approval,
      approval_status,
      approved_by_user_id,
      approved_at,
      reject_reason,
      void_type,
      void_reason,
      is_voided
    ) VALUES (
      generate_movement_number(),
      v_profit_loss_id,
      'incoming',
      NEW.commission,
      NEW.commission_currency,
      'عمولة من حركة ' || NEW.movement_number,
      true,
      NEW.id,
      NEW.source_user_id,
      NEW.created_by_user_id,
      NEW.created_by_user_name,
      (get_movement_approval_status(NEW.approval_status, NEW.pending_approval) = 'pending'),
      get_movement_approval_status(NEW.approval_status, NEW.pending_approval),
      NEW.approved_by_user_id,
      NEW.approved_at,
      NEW.reject_reason,
      NEW.void_type,
      NEW.void_reason,
      COALESCE(NEW.is_voided, false)
    )
    RETURNING id INTO v_commission_movement_id;
  END IF;

  RETURN NEW;
END;
$$;

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
      'created_by_user_id', am.created_by_user_id,
      'created_by_user_name', am.created_by_user_name,
      'related_commission_movement_id', am.related_commission_movement_id,
      'pending_approval', (get_movement_approval_status(am.approval_status, am.pending_approval) = 'pending'),
      'approval_status', get_movement_approval_status(am.approval_status, am.pending_approval),
      'approved_by_user_id', am.approved_by_user_id,
      'approved_at', am.approved_at,
      'reject_reason', am.reject_reason,
      'void_type', am.void_type,
      'void_reason', am.void_reason,
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

CREATE OR REPLACE VIEW customer_accounts AS
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
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
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
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
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
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
        THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) AS balance,
  COUNT(am.id) FILTER (
    WHERE COALESCE(am.is_commission_movement, false) = false
      AND COALESCE(am.is_voided, false) = false
      AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
  ) AS total_movements,
  c.created_at,
  c.updated_at
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.created_at, c.updated_at;

DROP VIEW IF EXISTS customer_balances;
CREATE OR REPLACE VIEW customer_balances AS
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
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
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
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
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
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
        THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) AS balance,
  am.currency,
  MAX(am.created_at) FILTER (
    WHERE COALESCE(am.is_commission_movement, false) = false
      AND COALESCE(am.is_voided, false) = false
      AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
  ) AS last_activity
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.user_id, c.linked_user_id, c.is_profit_loss_account, am.currency
HAVING c.is_profit_loss_account = true
  OR COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
        THEN am.amount
        WHEN am.movement_type = 'outgoing'
          AND COALESCE(am.is_commission_movement, false) = false
          AND COALESCE(am.is_voided, false) = false
          AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
        THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) <> 0;

DROP VIEW IF EXISTS customer_balances_by_currency;
CREATE OR REPLACE VIEW customer_balances_by_currency AS
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
  AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
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

CREATE OR REPLACE VIEW total_balances_by_currency AS
WITH posted_movements AS (
  SELECT *
  FROM account_movements am
  WHERE COALESCE(am.is_voided, false) = false
    AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
)
SELECT
  currency,
  COALESCE(SUM(incoming_amount), 0) AS total_incoming,
  COALESCE(SUM(outgoing_amount), 0) AS total_outgoing,
  COALESCE(SUM(outgoing_amount) - SUM(incoming_amount), 0) AS balance
FROM (
  SELECT
    pm.currency,
    CASE WHEN pm.movement_type = 'incoming' THEN pm.amount ELSE 0 END AS incoming_amount,
    CASE WHEN pm.movement_type = 'outgoing' THEN pm.amount ELSE 0 END AS outgoing_amount
  FROM posted_movements pm

  UNION ALL

  SELECT
    pm.commission_currency AS currency,
    0 AS incoming_amount,
    CASE
      WHEN pm.commission IS NOT NULL AND pm.commission > 0 THEN pm.commission
      ELSE 0
    END AS outgoing_amount
  FROM posted_movements pm
  WHERE pm.commission IS NOT NULL
    AND pm.commission > 0
) all_currency_movements
WHERE currency IS NOT NULL
GROUP BY currency
ORDER BY currency;

DROP VIEW IF EXISTS user_linked_accounts;
CREATE OR REPLACE VIEW user_linked_accounts AS
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
      AND get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
  ) AS total_balance
FROM customers c
INNER JOIN app_security owner ON c.user_id = owner.id
INNER JOIN app_security linked ON c.linked_user_id = linked.id
WHERE c.linked_user_id IS NOT NULL;

GRANT EXECUTE ON FUNCTION insert_movement_with_user(text, uuid, text, numeric, text, text, text, text, numeric, text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION approve_movement(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION reject_movement_with_reason(uuid, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION create_internal_transfer(uuid, uuid, numeric, text, text, numeric, text, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_customer_movements_with_user(text, uuid) TO anon, authenticated;

GRANT SELECT ON customer_accounts TO anon, authenticated;
GRANT SELECT ON customer_balances TO anon, authenticated;
GRANT SELECT ON customer_balances_by_currency TO anon, authenticated;
GRANT SELECT ON total_balances_by_currency TO anon, authenticated;
GRANT SELECT ON user_linked_accounts TO anon, authenticated;

COMMIT;
