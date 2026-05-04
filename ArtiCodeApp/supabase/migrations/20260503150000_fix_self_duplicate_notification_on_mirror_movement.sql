/*
  Fix: duplicate "أنت قيدت لـ <self>" pending notification.

  Problem
  -------
  When user Saleh creates a movement on customer "Safa" (linked account), two rows
  end up in movement_notifications with user_id = Saleh:

    1) for the ORIGINAL movement on customer Safa
       => "أنت قيدت على Safa مبلغ 900 ..."  (correct)
    2) for the MIRROR movement on the linked customer "saleh" (in Safa's books)
       => "أنت قيدت لـ saleh مبلغ 900 ..."  (WRONG — duplicate from the wrong perspective)

  Root cause
  ----------
  The trigger trg_ensure_creator_pending_movement_notification fires on every
  insert/update of account_movements. The mirror movement still carries the
  original creator's user id in created_by_user_id / source_user_id, so the
  trigger inserts a creator-pending notification for it too — but its customer_id
  points to a customer record that is owned by the COUNTERPARTY (Safa), not the
  creator (Saleh). That second notification is the visible duplicate.

  The client-side regex de-duplication (apply_fix_notification_self_duplicate.js)
  cannot fix this case because the two rows have different movement_id values,
  which is what the dedupe key is built from.

  Fix
  ---
  1) Skip notification creation in the trigger whenever the movement's customer
     does NOT belong to the creator (i.e. it is the mirror side).
  2) Hard-delete already-stored duplicate rows that match this pattern, so the
     existing UI clears up immediately.

  Safe behaviour preserved
  ------------------------
  - The counterparty (Safa) still receives her "approval_needed" notification
    via create_mirror_movement_v2 — that path is independent of this trigger.
  - The original-side notification for the creator (the correct one) still gets
    created/updated as before.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Replace the trigger function: ignore mirror movements
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_creator_pending_movement_notification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_creator_user_id uuid;
  v_customer_owner_id uuid;
  v_customer_name text;
  v_actor_name text;
  v_status text;
  v_is_pending boolean;
  v_pending_message text;
  v_final_title text;
  v_final_message text;
BEGIN
  v_creator_user_id := COALESCE(NEW.created_by_user_id, NEW.source_user_id);

  IF v_creator_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Look up the customer for this movement and its owner.
  SELECT c.name, c.user_id
    INTO v_customer_name, v_customer_owner_id
  FROM public.customers c
  WHERE c.id = NEW.customer_id;

  -- KEY FIX:
  -- Only emit a creator-side pending notification when the movement is on the
  -- creator's OWN books. If the customer belongs to someone else, this row is
  -- the mirror-side projection of the movement and does not deserve its own
  -- "أنت قيدت لـ <self>" notification for the creator.
  IF v_customer_owner_id IS DISTINCT FROM v_creator_user_id THEN
    RETURN NEW;
  END IF;

  v_actor_name := NULLIF(trim(COALESCE(NEW.created_by_user_name, '')), '');
  IF v_actor_name IS NULL THEN
    v_actor_name := v_customer_name;
  END IF;

  v_status := lower(
    COALESCE(
      NULLIF(trim(COALESCE(NEW.approval_status::text, '')), ''),
      CASE WHEN COALESCE(NEW.pending_approval, false) THEN 'pending' ELSE '' END
    )
  );

  v_is_pending := COALESCE(NEW.pending_approval, false) OR v_status = 'pending';

  v_pending_message := CASE
    WHEN COALESCE(v_customer_name, '') <> '' THEN
      format('تم إرسال هذه الحركة إلى %s وهي بانتظار الموافقة قبل دخولها في الإجماليات.', v_customer_name)
    ELSE
      'تم إرسال هذه الحركة وهي بانتظار موافقة الطرف الآخر قبل دخولها في الإجماليات.'
  END;

  IF v_is_pending THEN
    UPDATE public.movement_notifications
       SET status = 'pending',
           title = 'عملية معلقة',
           message = v_pending_message,
           action_required = false,
           recipient_user_id = v_creator_user_id,
           sender_user_id = COALESCE(NEW.source_user_id, NEW.created_by_user_id, v_creator_user_id),
           customer_id = NEW.customer_id,
           movement_number = NEW.movement_number,
           amount = NEW.amount,
           currency = NEW.currency,
           movement_type = NEW.movement_type,
           customer_name = v_customer_name,
           actor_name = v_actor_name,
           deleted_at = NULL,
           extra_data = COALESCE(extra_data, '{}'::jsonb) || jsonb_strip_nulls(
             jsonb_build_object(
               'approval_status', 'pending',
               'created_by_user_id', v_creator_user_id,
               'source_user_id', COALESCE(NEW.source_user_id, NEW.created_by_user_id),
               'created_by_name', NEW.created_by_user_name,
               'creator_user_name', NEW.created_by_user_name,
               'customer_name', v_customer_name,
               'note', NEW.notes
             )
           )
     WHERE movement_id = NEW.id
       AND user_id = v_creator_user_id
       AND notification_type = 'approval_needed'
       AND COALESCE(action_required, false) = false;

    IF NOT FOUND THEN
      INSERT INTO public.movement_notifications (
        user_id,
        recipient_user_id,
        sender_user_id,
        customer_id,
        movement_id,
        notification_type,
        title,
        message,
        is_read,
        status,
        action_required,
        created_at,
        movement_number,
        amount,
        currency,
        movement_type,
        customer_name,
        actor_name,
        extra_data
      )
      VALUES (
        v_creator_user_id,
        v_creator_user_id,
        COALESCE(NEW.source_user_id, NEW.created_by_user_id, v_creator_user_id),
        NEW.customer_id,
        NEW.id,
        'approval_needed',
        'عملية معلقة',
        v_pending_message,
        false,
        'pending',
        false,
        now(),
        NEW.movement_number,
        NEW.amount,
        NEW.currency,
        NEW.movement_type,
        v_customer_name,
        v_actor_name,
        jsonb_strip_nulls(
          jsonb_build_object(
            'approval_status', 'pending',
            'created_by_user_id', v_creator_user_id,
            'source_user_id', COALESCE(NEW.source_user_id, NEW.created_by_user_id),
            'created_by_name', NEW.created_by_user_name,
            'creator_user_name', NEW.created_by_user_name,
            'customer_name', v_customer_name,
            'note', NEW.notes
          )
        )
      );
    END IF;
  ELSIF v_status IN ('approved', 'rejected', 'done') THEN
    v_final_title := CASE
      WHEN v_status = 'approved' THEN 'تمت الموافقة على الحركة'
      WHEN v_status = 'rejected' THEN 'تم رفض الحركة'
      ELSE 'تم تحديث الحركة'
    END;

    v_final_message := CASE
      WHEN v_status = 'approved' AND COALESCE(v_customer_name, '') <> '' THEN format('وافق %s على هذه الحركة.', v_customer_name)
      WHEN v_status = 'approved' THEN 'تمت الموافقة على هذه الحركة.'
      WHEN v_status = 'rejected' AND COALESCE(v_customer_name, '') <> '' THEN format('رفض %s هذه الحركة.', v_customer_name)
      WHEN v_status = 'rejected' THEN 'تم رفض هذه الحركة.'
      ELSE 'تم تحديث حالة هذه الحركة.'
    END;

    UPDATE public.movement_notifications
       SET status = v_status,
           title = v_final_title,
           message = v_final_message,
           action_required = false,
           acted_at = COALESCE(acted_at, now()),
           recipient_user_id = v_creator_user_id,
           sender_user_id = COALESCE(NEW.source_user_id, NEW.created_by_user_id, v_creator_user_id),
           customer_id = NEW.customer_id,
           movement_number = NEW.movement_number,
           amount = NEW.amount,
           currency = NEW.currency,
           movement_type = NEW.movement_type,
           customer_name = v_customer_name,
           actor_name = v_actor_name,
           extra_data = COALESCE(extra_data, '{}'::jsonb) || jsonb_strip_nulls(
             jsonb_build_object(
               'approval_status', v_status,
               'reject_reason', NEW.reject_reason,
               'reason', NEW.reject_reason
             )
           )
     WHERE movement_id = NEW.id
       AND user_id = v_creator_user_id
       AND notification_type = 'approval_needed'
       AND COALESCE(action_required, false) = false;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ensure_creator_pending_movement_notification ON public.account_movements;
CREATE TRIGGER trg_ensure_creator_pending_movement_notification
AFTER INSERT OR UPDATE OF approval_status, pending_approval, reject_reason
ON public.account_movements
FOR EACH ROW
EXECUTE FUNCTION public.ensure_creator_pending_movement_notification();

-- ---------------------------------------------------------------------------
-- 2) Hard-delete the rows that the buggy trigger already produced.
--    A bad row is a creator-side notification whose movement points to a
--    customer that is NOT owned by the notification's user.
-- ---------------------------------------------------------------------------
DELETE FROM public.movement_notifications mn
USING public.account_movements am,
      public.customers c
WHERE mn.movement_id = am.id
  AND am.customer_id = c.id
  AND mn.notification_type = 'approval_needed'
  AND COALESCE(mn.action_required, false) = false  -- creator-side rows
  AND c.user_id IS DISTINCT FROM mn.user_id;        -- customer is not owned by user => mirror-side

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'self_duplicate_notification_on_mirror_movement_fixed' AS status;