/*
  ArtiCodeApp - Notification creator label metadata fix

  Goal:
  - If the current user created the movement, the app should display: "أنشأها: أنا".
  - If the other party created it, display their name.
  - Prevent old/corrupted creator-side approval notifications from looking like
    they were created by "الطرف الآخر".

  Safe:
  - Does not delete customers, movements, or notifications.
  - Only enriches notification metadata and protects future notification rows.
*/

ALTER TABLE IF EXISTS public.movement_notifications
  ADD COLUMN IF NOT EXISTS sender_user_id uuid,
  ADD COLUMN IF NOT EXISTS recipient_user_id uuid,
  ADD COLUMN IF NOT EXISTS customer_id uuid,
  ADD COLUMN IF NOT EXISTS actor_name text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'unread',
  ADD COLUMN IF NOT EXISTS action_required boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS extra_data jsonb DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS read_at timestamptz,
  ADD COLUMN IF NOT EXISTS acted_at timestamptz;

-- 1) Backfill existing notifications with real creator metadata from account_movements.
UPDATE public.movement_notifications mn
SET
  sender_user_id = COALESCE(mn.sender_user_id, am.source_user_id, am.created_by_user_id),
  recipient_user_id = COALESCE(mn.recipient_user_id, mn.user_id),
  customer_id = COALESCE(mn.customer_id, am.customer_id),
  actor_name = COALESCE(
    NULLIF(trim(mn.actor_name), ''),
    NULLIF(trim(am.created_by_user_name), ''),
    NULLIF(trim(creator.full_name), ''),
    NULLIF(trim(creator.user_name), ''),
    mn.actor_name
  ),
  extra_data = COALESCE(mn.extra_data, '{}'::jsonb)
    || jsonb_strip_nulls(
      jsonb_build_object(
        'created_by_user_id', COALESCE(am.source_user_id, am.created_by_user_id),
        'source_user_id', am.source_user_id,
        'created_by_name', COALESCE(
          NULLIF(trim(am.created_by_user_name), ''),
          NULLIF(trim(creator.full_name), ''),
          NULLIF(trim(creator.user_name), '')
        ),
        'creator_user_name', NULLIF(trim(creator.user_name), ''),
        'creator_full_name', NULLIF(trim(creator.full_name), ''),
        'approval_status', COALESCE(
          am.approval_status,
          CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE NULL END
        )
      )
    )
FROM public.account_movements am
LEFT JOIN public.app_security creator
  ON creator.id = COALESCE(am.source_user_id, am.created_by_user_id)
WHERE mn.movement_id = am.id;

-- 2) If old rows sent an approval notification to the creator, convert them to
-- informational "waiting for the other party" notifications instead of showing
-- approve/reject behavior or "الطرف الآخر".
UPDATE public.movement_notifications mn
SET
  notification_type = CASE
    WHEN mn.notification_type = 'approval_needed' THEN 'movement_added'
    ELSE mn.notification_type
  END,
  action_required = false,
  status = CASE
    WHEN COALESCE(am.approval_status, CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END) = 'pending'
      THEN 'pending'
    ELSE COALESCE(mn.status, 'unread')
  END,
  title = COALESCE(NULLIF(trim(mn.title), ''), 'حركة بانتظار موافقة الطرف الآخر'),
  message = COALESCE(NULLIF(trim(mn.message), ''), 'تم تسجيل الحركة وهي بانتظار موافقة الطرف الآخر.'),
  extra_data = COALESCE(mn.extra_data, '{}'::jsonb)
    || jsonb_build_object('creator_side', true, 'requires_action', false)
FROM public.account_movements am
WHERE mn.movement_id = am.id
  AND mn.user_id = COALESCE(am.source_user_id, am.created_by_user_id)
  AND (
    COALESCE(am.pending_approval, false) = true
    OR am.approval_status = 'pending'
  );

-- 3) Normalize future notification rows before saving them.
DROP TRIGGER IF EXISTS normalize_movement_notification_creator_metadata_trigger
ON public.movement_notifications;
DROP FUNCTION IF EXISTS public.normalize_movement_notification_creator_metadata();

CREATE FUNCTION public.normalize_movement_notification_creator_metadata()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_source_user_id uuid;
  v_created_by_user_id uuid;
  v_creator_id uuid;
  v_creator_name text;
  v_creator_user_name text;
  v_creator_full_name text;
  v_customer_id uuid;
  v_approval_status text;
  v_pending boolean;
BEGIN
  IF NEW.movement_id IS NULL THEN
    NEW.extra_data := COALESCE(NEW.extra_data, '{}'::jsonb);
    NEW.recipient_user_id := COALESCE(NEW.recipient_user_id, NEW.user_id);
    RETURN NEW;
  END IF;

  SELECT
    am.source_user_id,
    am.created_by_user_id,
    COALESCE(am.source_user_id, am.created_by_user_id),
    COALESCE(
      NULLIF(trim(am.created_by_user_name), ''),
      NULLIF(trim(creator.full_name), ''),
      NULLIF(trim(creator.user_name), '')
    ),
    NULLIF(trim(creator.user_name), ''),
    NULLIF(trim(creator.full_name), ''),
    am.customer_id,
    COALESCE(am.approval_status, CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END),
    COALESCE(am.pending_approval, false)
  INTO
    v_source_user_id,
    v_created_by_user_id,
    v_creator_id,
    v_creator_name,
    v_creator_user_name,
    v_creator_full_name,
    v_customer_id,
    v_approval_status,
    v_pending
  FROM public.account_movements am
  LEFT JOIN public.app_security creator
    ON creator.id = COALESCE(am.source_user_id, am.created_by_user_id)
  WHERE am.id = NEW.movement_id;

  NEW.recipient_user_id := COALESCE(NEW.recipient_user_id, NEW.user_id);
  NEW.sender_user_id := COALESCE(NEW.sender_user_id, v_creator_id);
  NEW.customer_id := COALESCE(NEW.customer_id, v_customer_id);
  NEW.actor_name := COALESCE(NULLIF(trim(NEW.actor_name), ''), v_creator_name, NEW.actor_name);
  NEW.extra_data := COALESCE(NEW.extra_data, '{}'::jsonb)
    || jsonb_strip_nulls(
      jsonb_build_object(
        'created_by_user_id', v_creator_id,
        'source_user_id', v_source_user_id,
        'created_by_name', v_creator_name,
        'creator_user_name', v_creator_user_name,
        'creator_full_name', v_creator_full_name,
        'approval_status', v_approval_status
      )
    );

  IF NEW.user_id = v_creator_id
     AND (v_pending = true OR v_approval_status = 'pending')
     AND NEW.notification_type = 'approval_needed' THEN
    NEW.notification_type := 'movement_added';
    NEW.action_required := false;
    NEW.status := COALESCE(NEW.status, 'pending');
    NEW.title := COALESCE(NULLIF(trim(NEW.title), ''), 'حركة بانتظار موافقة الطرف الآخر');
    NEW.message := COALESCE(NULLIF(trim(NEW.message), ''), 'تم تسجيل الحركة وهي بانتظار موافقة الطرف الآخر.');
    NEW.extra_data := NEW.extra_data || jsonb_build_object('creator_side', true, 'requires_action', false);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER normalize_movement_notification_creator_metadata_trigger
BEFORE INSERT OR UPDATE OF movement_id, actor_name, sender_user_id, user_id, recipient_user_id, notification_type, action_required, extra_data
ON public.movement_notifications
FOR EACH ROW
EXECUTE FUNCTION public.normalize_movement_notification_creator_metadata();

SELECT 'notification_creator_label_metadata_fixed' AS status;
