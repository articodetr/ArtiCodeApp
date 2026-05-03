/*
  Clean final override for linked customer approval workflow.

  What this migration enforces:
  - Any linked-customer movement (له / عليه) starts pending for both parties.
  - Pending or rejected movements never affect totals, balances, or statistics.
  - Only the counterparty can approve or reject the movement.
  - Both the original and mirror rows are updated together.
  - Uses app_security consistently instead of public.users.
*/

BEGIN;

ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS pending_approval boolean DEFAULT false;
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS approval_status text DEFAULT 'approved';
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS approved_at timestamptz;
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS approved_by_user_id uuid;
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS reject_reason text;
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS mirror_movement_id uuid;
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS source_user_id uuid;
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS created_by_user_id uuid;
ALTER TABLE IF EXISTS public.account_movements
  ADD COLUMN IF NOT EXISTS created_by_user_name text;

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

ALTER TABLE IF EXISTS public.movement_notifications
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

CREATE OR REPLACE FUNCTION public.get_movement_approval_status(
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

CREATE OR REPLACE FUNCTION public.movement_requires_counterparty_approval(
  p_customer_id uuid,
  p_actor_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.customers c
    WHERE c.id = p_customer_id
      AND c.linked_user_id IS NOT NULL
      AND c.linked_user_id IS DISTINCT FROM c.user_id
      AND c.linked_user_id IS DISTINCT FROM p_actor_user_id
  );
$$;

UPDATE public.account_movements
SET
  approval_status = public.get_movement_approval_status(approval_status, pending_approval),
  pending_approval = (public.get_movement_approval_status(approval_status, pending_approval) = 'pending')
WHERE approval_status IS NULL
   OR pending_approval IS DISTINCT FROM (
     public.get_movement_approval_status(approval_status, pending_approval) = 'pending'
   );

UPDATE public.account_movements
SET notes = COALESCE(NULLIF(trim(notes), ''), 'حركة قديمة بدون ملاحظة')
WHERE NULLIF(trim(COALESCE(notes, '')), '') IS NULL;

CREATE OR REPLACE FUNCTION public.sync_account_movement_approval_state()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_status text;
BEGIN
  v_status := public.get_movement_approval_status(NEW.approval_status, NEW.pending_approval);
  NEW.approval_status := v_status;
  NEW.pending_approval := (v_status = 'pending');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_sync_account_movement_approval_state ON public.account_movements;
CREATE TRIGGER trigger_sync_account_movement_approval_state
  BEFORE INSERT OR UPDATE ON public.account_movements
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_account_movement_approval_state();

CREATE OR REPLACE FUNCTION public.insert_movement_with_user(
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
  SELECT a.id, COALESCE(NULLIF(trim(a.full_name), ''), a.user_name)
  INTO v_user_id, v_user_full_name
  FROM public.app_security a
  WHERE a.user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT c.*
  INTO v_customer
  FROM public.customers c
  WHERE c.id = p_customer_id;

  IF v_customer IS NULL THEN
    RAISE EXCEPTION 'Customer not found: %', p_customer_id;
  END IF;

  v_notes := NULLIF(trim(COALESCE(p_notes, '')), '');
  IF v_notes IS NULL THEN
    RAISE EXCEPTION 'الملاحظة مطلوبة';
  END IF;

  v_needs_approval := public.movement_requires_counterparty_approval(p_customer_id, v_user_id);
  v_approval_status := CASE WHEN v_needs_approval THEN 'pending' ELSE 'approved' END;
  v_movement_number := public.generate_movement_number();

  INSERT INTO public.account_movements (
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
    approved_by_user_id,
    approved_at,
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
    CASE WHEN v_needs_approval THEN NULL ELSE v_user_id END,
    CASE WHEN v_needs_approval THEN NULL ELSE now() END,
    false
  )
  RETURNING account_movements.id, account_movements.movement_number, account_movements.receipt_number
  INTO v_movement_id, v_movement_number, v_receipt_number;

  IF v_needs_approval THEN
    PERFORM public.create_notification(
      v_movement_id,
      v_user_id,
      'movement_added',
      format(
        'تم تسجيل حركة %s مع %s بانتظار موافقة الطرف الآخر',
        CASE WHEN p_movement_type = 'incoming' THEN 'له' ELSE 'عليه' END,
        COALESCE(v_customer.name, 'الطرف الآخر')
      ),
      v_movement_number,
      p_amount,
      p_currency,
      v_customer.name,
      NULL,
      p_movement_type,
      jsonb_build_object('approval_status', 'pending', 'requires_action', false)
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

CREATE OR REPLACE FUNCTION public.create_mirror_movement_v2(p_movement_id uuid)
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
  v_actor_name text;
BEGIN
  SELECT am.*, c.user_id AS customer_owner_id, c.linked_user_id, c.name AS customer_name
  INTO v_original_movement
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = p_movement_id;

  IF v_original_movement IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_original_movement.mirror_movement_id IS NOT NULL
     OR EXISTS (SELECT 1 FROM public.account_movements x WHERE x.mirror_movement_id = p_movement_id) THEN
    RETURN COALESCE(
      v_original_movement.mirror_movement_id,
      (SELECT x.id FROM public.account_movements x WHERE x.mirror_movement_id = p_movement_id LIMIT 1)
    );
  END IF;

  SELECT *
  INTO v_customer
  FROM public.customers
  WHERE id = v_original_movement.customer_id;

  IF v_customer IS NULL OR v_customer.linked_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.movement_requires_counterparty_approval(v_original_movement.customer_id, COALESCE(v_original_movement.source_user_id, v_original_movement.created_by_user_id)) THEN
    RETURN NULL;
  END IF;

  SELECT c.id
  INTO v_linked_customer_id
  FROM public.customers c
  WHERE c.user_id = v_customer.linked_user_id
    AND c.linked_user_id = v_customer.user_id
  ORDER BY c.created_at ASC
  LIMIT 1;

  IF v_linked_customer_id IS NULL THEN
    INSERT INTO public.customers (
      user_id,
      linked_user_id,
      name,
      phone,
      notes
    ) VALUES (
      v_customer.linked_user_id,
      v_customer.user_id,
      COALESCE(v_original_movement.created_by_user_name, v_customer.name, 'الطرف المقابل'),
      '',
      'تم إنشاؤه تلقائيًا للحركات المرتبطة'
    )
    RETURNING id INTO v_linked_customer_id;
  END IF;

  v_mirror_type := CASE
    WHEN v_original_movement.movement_type = 'outgoing' THEN 'incoming'
    ELSE 'outgoing'
  END;

  INSERT INTO public.account_movements (
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
    mirror_movement_id,
    pending_approval,
    approval_status,
    approved_by_user_id,
    approved_at,
    is_voided
  ) VALUES (
    public.generate_movement_number(),
    v_linked_customer_id,
    v_mirror_type,
    v_original_movement.amount,
    v_original_movement.currency,
    v_original_movement.notes,
    v_original_movement.sender_name,
    v_original_movement.beneficiary_name,
    v_original_movement.commission,
    v_original_movement.commission_currency,
    v_original_movement.commission_recipient_id,
    v_original_movement.source_user_id,
    v_original_movement.created_by_user_id,
    v_original_movement.created_by_user_name,
    p_movement_id,
    true,
    'pending',
    NULL,
    NULL,
    false
  )
  RETURNING id INTO v_mirror_movement_id;

  UPDATE public.account_movements
  SET mirror_movement_id = v_mirror_movement_id
  WHERE id = p_movement_id;

  v_actor_name := COALESCE(v_original_movement.created_by_user_name, 'الطرف الآخر');

  PERFORM public.create_notification(
    v_mirror_movement_id,
    v_customer.linked_user_id,
    'approval_needed',
    format(
      '%s %s مبلغ %s %s',
      CASE WHEN v_mirror_type = 'incoming' THEN 'قيّد لك' ELSE 'قيّد عليك' END,
      v_actor_name,
      trim(to_char(v_original_movement.amount, 'FM999999999990.00')),
      v_original_movement.currency
    ),
    v_original_movement.movement_number,
    v_original_movement.amount,
    v_original_movement.currency,
    v_customer.name,
    v_actor_name,
    v_mirror_type,
    jsonb_build_object('approval_status', 'pending', 'requires_action', true)
  );

  RETURN v_mirror_movement_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.trigger_create_mirror_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF COALESCE(NEW.is_commission_movement, false) = false
     AND NEW.mirror_movement_id IS NULL
     AND NEW.transfer_direction IS NULL
     AND NEW.from_customer_id IS NULL
     AND NEW.to_customer_id IS NULL
     AND public.movement_requires_counterparty_approval(NEW.customer_id, COALESCE(NEW.source_user_id, NEW.created_by_user_id))
  THEN
    PERFORM public.create_mirror_movement_v2(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS after_movement_approval_create_mirror ON public.account_movements;
DROP TRIGGER IF EXISTS after_movement_insert_create_mirror ON public.account_movements;
DROP TRIGGER IF EXISTS trigger_create_mirror_movement ON public.account_movements;
CREATE TRIGGER after_movement_insert_create_mirror
  AFTER INSERT ON public.account_movements
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_create_mirror_movement();

DROP FUNCTION IF EXISTS public.approve_movement(uuid, text);
CREATE FUNCTION public.approve_movement(
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
  SELECT a.id, COALESCE(NULLIF(trim(a.full_name), ''), a.user_name)
  INTO v_user_id, v_user_full_name
  FROM public.app_security a
  WHERE a.user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT am.*, c.user_id AS customer_owner_id, c.name AS customer_name
  INTO v_movement
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  IF public.get_movement_approval_status(v_movement.approval_status, v_movement.pending_approval) <> 'pending' THEN
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
    (SELECT am.id FROM public.account_movements am WHERE am.mirror_movement_id = v_movement.id LIMIT 1)
  );

  v_creator_user_id := COALESCE(
    v_movement.created_by_user_id,
    (SELECT created_by_user_id FROM public.account_movements WHERE id = v_pair_id)
  );

  SELECT am.id, am.movement_number, am.amount, am.currency, am.movement_type, c.name AS customer_name
  INTO v_creator_movement_id, v_creator_movement_number, v_creator_movement_amount, v_creator_movement_currency, v_creator_movement_type, v_creator_customer_name
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id IN (v_movement.id, v_pair_id)
    AND c.user_id = v_creator_user_id
  LIMIT 1;

  IF v_creator_movement_id IS NULL THEN
    SELECT am.id, am.movement_number, am.amount, am.currency, am.movement_type, c.name AS customer_name
    INTO v_creator_movement_id, v_creator_movement_number, v_creator_movement_amount, v_creator_movement_currency, v_creator_movement_type, v_creator_customer_name
    FROM public.account_movements am
    JOIN public.customers c ON c.id = am.customer_id
    WHERE am.id = COALESCE(v_pair_id, v_movement.id)
    LIMIT 1;
  END IF;

  UPDATE public.account_movements
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

  UPDATE public.account_movements
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

  DELETE FROM public.movement_notifications
  WHERE notification_type = 'approval_needed'
    AND (movement_id = v_movement.id OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id));

  IF v_creator_user_id IS NOT NULL THEN
    DELETE FROM public.movement_notifications
    WHERE user_id = v_creator_user_id
      AND notification_type = 'movement_added'
      AND (
        movement_id = v_movement.id
        OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id)
        OR (v_creator_movement_id IS NOT NULL AND movement_id = v_creator_movement_id)
      );
  END IF;

  IF v_creator_user_id IS NOT NULL AND v_creator_user_id <> v_user_id THEN
    PERFORM public.create_notification(
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
        'approved_at', now(),
        'requires_action', false
      )
    );
  END IF;

  PERFORM public.create_notification(
    p_movement_id,
    v_user_id,
    'movement_approved',
    'تم اعتماد الحركة وأصبحت مؤثرة في الإجماليات',
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

  RETURN json_build_object('success', true, 'movement_id', p_movement_id, 'status', 'approved');
END;
$$;

DROP FUNCTION IF EXISTS public.reject_movement_with_reason(uuid, text, text);
CREATE FUNCTION public.reject_movement_with_reason(
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
    RAISE EXCEPTION 'Reject reason is required';
  END IF;

  SELECT a.id, COALESCE(NULLIF(trim(a.full_name), ''), a.user_name)
  INTO v_user_id, v_user_full_name
  FROM public.app_security a
  WHERE a.user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  SELECT am.*, c.user_id AS customer_owner_id, c.name AS customer_name
  INTO v_movement
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  IF public.get_movement_approval_status(v_movement.approval_status, v_movement.pending_approval) <> 'pending' THEN
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
    (SELECT am.id FROM public.account_movements am WHERE am.mirror_movement_id = v_movement.id LIMIT 1)
  );

  v_creator_user_id := COALESCE(
    v_movement.created_by_user_id,
    (SELECT created_by_user_id FROM public.account_movements WHERE id = v_pair_id)
  );

  SELECT am.id, am.movement_number, am.amount, am.currency, am.movement_type, c.name AS customer_name
  INTO v_creator_movement_id, v_creator_movement_number, v_creator_movement_amount, v_creator_movement_currency, v_creator_movement_type, v_creator_customer_name
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id IN (v_movement.id, v_pair_id)
    AND c.user_id = v_creator_user_id
  LIMIT 1;

  IF v_creator_movement_id IS NULL THEN
    SELECT am.id, am.movement_number, am.amount, am.currency, am.movement_type, c.name AS customer_name
    INTO v_creator_movement_id, v_creator_movement_number, v_creator_movement_amount, v_creator_movement_currency, v_creator_movement_type, v_creator_customer_name
    FROM public.account_movements am
    JOIN public.customers c ON c.id = am.customer_id
    WHERE am.id = COALESCE(v_pair_id, v_movement.id)
    LIMIT 1;
  END IF;

  UPDATE public.account_movements
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

  UPDATE public.account_movements
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

  DELETE FROM public.movement_notifications
  WHERE notification_type = 'approval_needed'
    AND (movement_id = v_movement.id OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id));

  IF v_creator_user_id IS NOT NULL THEN
    DELETE FROM public.movement_notifications
    WHERE user_id = v_creator_user_id
      AND notification_type = 'movement_added'
      AND (
        movement_id = v_movement.id
        OR (v_pair_id IS NOT NULL AND movement_id = v_pair_id)
        OR (v_creator_movement_id IS NOT NULL AND movement_id = v_creator_movement_id)
      );
  END IF;

  IF v_creator_user_id IS NOT NULL AND v_creator_user_id <> v_user_id THEN
    PERFORM public.create_notification(
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

  PERFORM public.create_notification(
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

  RETURN json_build_object('success', true, 'movement_id', p_movement_id, 'status', 'rejected', 'reject_reason', v_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_customer_movements_with_user(
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
      'pending_approval', (public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'pending'),
      'approval_status', public.get_movement_approval_status(am.approval_status, am.pending_approval),
      'approved_by_user_id', am.approved_by_user_id,
      'approved_at', am.approved_at,
      'reject_reason', am.reject_reason,
      'void_type', am.void_type,
      'void_reason', am.void_reason,
      'is_voided', COALESCE(am.is_voided, false),
      'is_internal_transfer', CASE WHEN am.from_customer_id IS NOT NULL OR am.to_customer_id IS NOT NULL THEN true ELSE false END,
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
  FROM public.account_movements am
  LEFT JOIN public.customers c ON am.customer_id = c.id
  LEFT JOIN public.app_security lu ON c.linked_user_id = lu.id
  WHERE am.customer_id = p_customer_id
    AND COALESCE(am.is_voided, false) = false;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

DROP VIEW IF EXISTS public.customer_accounts CASCADE;
CREATE OR REPLACE VIEW public.customer_accounts AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.email,
  c.address,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN am.amount WHEN am.movement_type = 'outgoing' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN -am.amount ELSE 0 END), 0) AS balance,
  COUNT(am.id) FILTER (WHERE COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved') AS total_movements,
  c.created_at,
  c.updated_at
FROM public.customers c
LEFT JOIN public.account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.created_at, c.updated_at;

DROP VIEW IF EXISTS public.customer_balances CASCADE;
CREATE OR REPLACE VIEW public.customer_balances AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.user_id,
  c.linked_user_id,
  c.is_profit_loss_account,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN am.amount WHEN am.movement_type = 'outgoing' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN -am.amount ELSE 0 END), 0) AS balance,
  am.currency,
  MAX(am.created_at) FILTER (WHERE COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved') AS last_activity
FROM public.customers c
LEFT JOIN public.account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.user_id, c.linked_user_id, c.is_profit_loss_account, am.currency
HAVING c.is_profit_loss_account = true
   OR COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN am.amount WHEN am.movement_type = 'outgoing' AND COALESCE(am.is_commission_movement, false) = false AND COALESCE(am.is_voided, false) = false AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved' THEN -am.amount ELSE 0 END), 0) <> 0;

DROP VIEW IF EXISTS public.customer_balances_by_currency CASCADE;
CREATE OR REPLACE VIEW public.customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  c.user_id,
  c.linked_user_id,
  am.currency,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount WHEN am.movement_type = 'outgoing' THEN -am.amount ELSE 0 END), 0) AS balance,
  MAX(am.created_at) AS last_movement_date,
  COUNT(am.id) AS movement_count
FROM public.customers c
LEFT JOIN public.account_movements am
  ON c.id = am.customer_id
  AND COALESCE(am.is_voided, false) = false
  AND COALESCE(am.is_commission_movement, false) = false
  AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
GROUP BY c.id, c.name, c.user_id, c.linked_user_id, am.currency
HAVING am.currency IS NOT NULL
  AND (
    COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount WHEN am.movement_type = 'outgoing' THEN -am.amount ELSE 0 END), 0) <> 0
    OR EXISTS (
      SELECT 1 FROM public.customers c2 WHERE c2.id = c.id AND COALESCE(c2.is_profit_loss_account, false) = true
    )
  );

DROP VIEW IF EXISTS public.total_balances_by_currency CASCADE;
CREATE OR REPLACE VIEW public.total_balances_by_currency AS
WITH posted_movements AS (
  SELECT *
  FROM public.account_movements am
  WHERE COALESCE(am.is_voided, false) = false
    AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved'
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
    CASE WHEN pm.commission IS NOT NULL AND pm.commission > 0 THEN pm.commission ELSE 0 END AS outgoing_amount
  FROM posted_movements pm
  WHERE pm.commission IS NOT NULL AND pm.commission > 0
) all_currency_movements
WHERE currency IS NOT NULL
GROUP BY currency
ORDER BY currency;

GRANT EXECUTE ON FUNCTION public.get_movement_approval_status(text, boolean) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.movement_requires_counterparty_approval(uuid, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.insert_movement_with_user(text, uuid, text, numeric, text, text, text, text, numeric, text, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_mirror_movement_v2(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_movement(uuid, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_movement_with_reason(uuid, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_customer_movements_with_user(text, uuid) TO anon, authenticated, service_role;

COMMIT;
