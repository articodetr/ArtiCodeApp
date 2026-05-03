/*
  ArtiCodeApp - Fix approval notification recipient

  Problem fixed:
  - The creator of a movement sometimes receives an approval_needed notification for
    their own movement, then approve_movement correctly rejects it with:
    "لا يمكن لمنشئ الحركة اعتمادها بنفسه".

  Correct behavior:
  - The creator sees the movement as "بانتظار رد الطرف الآخر" only.
  - Only the counterparty receives an actionable approval_needed notification.

  Safe:
  - Does not delete customers or account movements.
  - Deletes only wrong approval_needed notifications sent to the movement creator
    or attached to the wrong side of a mirrored movement.
*/

-- -----------------------------------------------------------------------------
-- 1) Compatibility columns for notification UI
-- -----------------------------------------------------------------------------

ALTER TABLE IF EXISTS public.movement_notifications
  ADD COLUMN IF NOT EXISTS recipient_user_id uuid,
  ADD COLUMN IF NOT EXISTS sender_user_id uuid,
  ADD COLUMN IF NOT EXISTS customer_id uuid,
  ADD COLUMN IF NOT EXISTS title text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'unread',
  ADD COLUMN IF NOT EXISTS action_required boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS read_at timestamptz,
  ADD COLUMN IF NOT EXISTS acted_at timestamptz,
  ADD COLUMN IF NOT EXISTS extra_data jsonb DEFAULT '{}'::jsonb;

UPDATE public.movement_notifications
SET
  recipient_user_id = COALESCE(recipient_user_id, user_id),
  status = COALESCE(status, CASE WHEN COALESCE(is_read, false) THEN 'read' ELSE 'unread' END),
  action_required = COALESCE(action_required, notification_type = 'approval_needed'),
  extra_data = COALESCE(extra_data, '{}'::jsonb)
WHERE recipient_user_id IS NULL
   OR status IS NULL
   OR action_required IS NULL
   OR extra_data IS NULL;

-- This index is intentionally non-unique. Some older databases already have
-- a partial unique index; this improves lookup speed without fighting old indexes.
CREATE INDEX IF NOT EXISTS movement_notifications_user_type_movement_idx
  ON public.movement_notifications (user_id, notification_type, movement_id)
  WHERE movement_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2) Replace the generic pending-notification trigger with a guarded version
-- -----------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trigger_create_pending_movement_notification ON public.account_movements;
DROP TRIGGER IF EXISTS zzz_trigger_create_pending_movement_notification_guarded ON public.account_movements;
DROP FUNCTION IF EXISTS public.create_pending_movement_notification();

CREATE FUNCTION public.create_pending_movement_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_customer public.customers%ROWTYPE;
  v_creator_id uuid;
  v_recipient_id uuid;
  v_actor_name text;
  v_title text;
  v_message text;
  v_has_mirror boolean := false;
BEGIN
  -- Commission/internal accounting rows do not need counterparty approvals.
  IF COALESCE(NEW.is_commission_movement, false) = true THEN
    RETURN NEW;
  END IF;

  -- Only pending movements create approval-needed notifications.
  IF COALESCE(NEW.pending_approval, false) = false
     AND COALESCE(NEW.approval_status, 'approved') <> 'pending' THEN
    RETURN NEW;
  END IF;

  SELECT *
  INTO v_customer
  FROM public.customers
  WHERE id = NEW.customer_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  v_creator_id := COALESCE(NEW.source_user_id, NEW.created_by_user_id);
  v_actor_name := COALESCE(NEW.created_by_user_name, 'الطرف الآخر');

  /*
    If this row is the mirror row, create_mirror_movement_v2 already creates
    the correct approval_needed notification for the counterparty owner.
    We skip here to avoid duplicates.
  */
  IF NEW.mirror_movement_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  /*
    If this original row already has a mirror row, the actionable notification
    must be attached to the mirror row, not the original row. This prevents the
    creator from seeing an approval button for their own row and prevents the
    counterparty from approving the wrong side.
  */
  SELECT EXISTS (
    SELECT 1
    FROM public.account_movements pair
    WHERE pair.mirror_movement_id = NEW.id
  )
  INTO v_has_mirror;

  IF v_has_mirror THEN
    RETURN NEW;
  END IF;

  /*
    Fallback for pending movements without a mirror row:
    - If the row is not owned by the creator, the owner can approve it.
    - Otherwise, the linked user is the counterparty.
    In all cases, never send approval_needed to the creator.
  */
  IF v_customer.user_id IS NOT NULL AND v_customer.user_id IS DISTINCT FROM v_creator_id THEN
    v_recipient_id := v_customer.user_id;
  ELSIF v_customer.linked_user_id IS NOT NULL AND v_customer.linked_user_id IS DISTINCT FROM v_creator_id THEN
    v_recipient_id := v_customer.linked_user_id;
  ELSE
    RETURN NEW;
  END IF;

  IF v_recipient_id IS NULL OR v_recipient_id = v_creator_id THEN
    RETURN NEW;
  END IF;

  v_title := 'حركة بانتظار موافقتك';
  v_message :=
    'توجد حركة على حساب '
    || COALESCE(v_customer.name, 'عميل')
    || ' بمبلغ '
    || COALESCE(NEW.amount::text, '0')
    || ' '
    || COALESCE(NEW.currency, '')
    || ' وتحتاج موافقتك.';

  INSERT INTO public.movement_notifications (
    user_id,
    recipient_user_id,
    movement_id,
    customer_id,
    sender_user_id,
    notification_type,
    title,
    message,
    movement_number,
    amount,
    currency,
    movement_type,
    customer_name,
    actor_name,
    status,
    is_read,
    action_required,
    extra_data
  )
  VALUES (
    v_recipient_id,
    v_recipient_id,
    NEW.id,
    NEW.customer_id,
    v_creator_id,
    'approval_needed',
    v_title,
    v_message,
    NEW.movement_number,
    NEW.amount,
    NEW.currency,
    NEW.movement_type,
    v_customer.name,
    v_actor_name,
    'unread',
    false,
    true,
    jsonb_build_object('approval_status', 'pending', 'requires_action', true)
  )
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

/*
  The trigger name starts with zzz so it runs after after_movement_insert_create_mirror
  when both are AFTER INSERT triggers. This allows it to see that a mirror row was
  created and avoid creating an original-side approval notification.
*/
CREATE TRIGGER zzz_trigger_create_pending_movement_notification_guarded
AFTER INSERT OR UPDATE OF pending_approval, approval_status
ON public.account_movements
FOR EACH ROW
EXECUTE FUNCTION public.create_pending_movement_notification();

-- -----------------------------------------------------------------------------
-- 3) Remove wrong approval notifications already created
-- -----------------------------------------------------------------------------

-- 3.1 Delete approval notifications sent to the creator of the movement.
DELETE FROM public.movement_notifications n
USING public.account_movements am
WHERE n.movement_id = am.id
  AND n.notification_type = 'approval_needed'
  AND n.user_id = COALESCE(am.source_user_id, am.created_by_user_id);

-- 3.2 Delete approval notifications attached to the original row when a mirror
-- row exists. The actionable notification should be attached to the mirror row.
DELETE FROM public.movement_notifications n
USING public.account_movements am
WHERE n.movement_id = am.id
  AND n.notification_type = 'approval_needed'
  AND EXISTS (
    SELECT 1
    FROM public.account_movements mirror
    WHERE mirror.mirror_movement_id = am.id
  );

-- 3.3 Delete corrupted approval notifications for users who are neither the
-- owner nor the linked counterparty of the movement customer.
DELETE FROM public.movement_notifications n
USING public.account_movements am
JOIN public.customers c ON c.id = am.customer_id
WHERE n.movement_id = am.id
  AND n.notification_type = 'approval_needed'
  AND n.user_id IS DISTINCT FROM c.user_id
  AND n.user_id IS DISTINCT FROM c.linked_user_id;

-- -----------------------------------------------------------------------------
-- 4) Re-create missing correct approval notifications for pending mirror rows
-- -----------------------------------------------------------------------------

INSERT INTO public.movement_notifications (
  user_id,
  recipient_user_id,
  movement_id,
  customer_id,
  sender_user_id,
  notification_type,
  title,
  message,
  movement_number,
  amount,
  currency,
  movement_type,
  customer_name,
  actor_name,
  status,
  is_read,
  action_required,
  extra_data
)
SELECT
  c.user_id,
  c.user_id,
  am.id,
  am.customer_id,
  COALESCE(am.source_user_id, am.created_by_user_id),
  'approval_needed',
  'حركة بانتظار موافقتك',
  'توجد حركة على حساب '
    || COALESCE(c.name, 'عميل')
    || ' بمبلغ '
    || am.amount::text
    || ' '
    || COALESCE(am.currency, '')
    || ' وتحتاج موافقتك.',
  am.movement_number,
  am.amount,
  am.currency,
  am.movement_type,
  c.name,
  COALESCE(am.created_by_user_name, 'الطرف الآخر'),
  'unread',
  false,
  true,
  jsonb_build_object('approval_status', 'pending', 'requires_action', true)
FROM public.account_movements am
JOIN public.customers c ON c.id = am.customer_id
WHERE am.mirror_movement_id IS NOT NULL
  AND COALESCE(am.is_commission_movement, false) = false
  AND COALESCE(am.is_voided, false) = false
  AND (COALESCE(am.pending_approval, false) = true OR am.approval_status = 'pending')
  AND c.user_id IS NOT NULL
  AND c.user_id IS DISTINCT FROM COALESCE(am.source_user_id, am.created_by_user_id)
  AND NOT EXISTS (
    SELECT 1
    FROM public.movement_notifications n
    WHERE n.movement_id = am.id
      AND n.user_id = c.user_id
      AND n.notification_type = 'approval_needed'
  )
ON CONFLICT DO NOTHING;

-- 4.2 Fallback: pending rows without any mirror can still notify the linked user
-- if the linked user is not the creator.
INSERT INTO public.movement_notifications (
  user_id,
  recipient_user_id,
  movement_id,
  customer_id,
  sender_user_id,
  notification_type,
  title,
  message,
  movement_number,
  amount,
  currency,
  movement_type,
  customer_name,
  actor_name,
  status,
  is_read,
  action_required,
  extra_data
)
SELECT
  c.linked_user_id,
  c.linked_user_id,
  am.id,
  am.customer_id,
  COALESCE(am.source_user_id, am.created_by_user_id),
  'approval_needed',
  'حركة بانتظار موافقتك',
  'توجد حركة على حساب '
    || COALESCE(c.name, 'عميل')
    || ' بمبلغ '
    || am.amount::text
    || ' '
    || COALESCE(am.currency, '')
    || ' وتحتاج موافقتك.',
  am.movement_number,
  am.amount,
  am.currency,
  am.movement_type,
  c.name,
  COALESCE(am.created_by_user_name, 'الطرف الآخر'),
  'unread',
  false,
  true,
  jsonb_build_object('approval_status', 'pending', 'requires_action', true)
FROM public.account_movements am
JOIN public.customers c ON c.id = am.customer_id
WHERE am.mirror_movement_id IS NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.account_movements mirror
    WHERE mirror.mirror_movement_id = am.id
  )
  AND COALESCE(am.is_commission_movement, false) = false
  AND COALESCE(am.is_voided, false) = false
  AND (COALESCE(am.pending_approval, false) = true OR am.approval_status = 'pending')
  AND c.linked_user_id IS NOT NULL
  AND c.linked_user_id IS DISTINCT FROM COALESCE(am.source_user_id, am.created_by_user_id)
  AND NOT EXISTS (
    SELECT 1
    FROM public.movement_notifications n
    WHERE n.movement_id = am.id
      AND n.user_id = c.linked_user_id
      AND n.notification_type = 'approval_needed'
  )
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 5) Final sanity result
-- -----------------------------------------------------------------------------

SELECT
  'approval_notification_recipient_fixed' AS status,
  (
    SELECT COUNT(*)
    FROM public.movement_notifications n
    JOIN public.account_movements am ON am.id = n.movement_id
    WHERE n.notification_type = 'approval_needed'
      AND n.user_id = COALESCE(am.source_user_id, am.created_by_user_id)
  ) AS remaining_creator_approval_notifications;
