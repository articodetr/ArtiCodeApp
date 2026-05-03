/*
  ArtiCodeApp - Rebuild notification separation logic

  هدف هذا التعديل:
  - جدول واحد للإشعارات، وصفحتان منفصلتان في التطبيق:
    1) الإشعارات العامة لكل العملاء
    2) إشعارات عميل واحد فقط
  - عدم حذف إشعار approval_needed بعد القبول أو الرفض.
  - تحويل حالة الإشعار إلى approved / rejected مع بقاء السجل حتى يحذفه المستخدم يدويًا.
  - دعم soft delete عبر deleted_at بدل الحذف النهائي من التطبيق.
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Notification columns and indexes
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
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS extra_data jsonb DEFAULT '{}'::jsonb;

UPDATE public.movement_notifications n
SET customer_id = am.customer_id
FROM public.account_movements am
WHERE n.movement_id = am.id
  AND n.customer_id IS NULL;

UPDATE public.movement_notifications
SET
  recipient_user_id = COALESCE(recipient_user_id, user_id),
  user_id = COALESCE(user_id, recipient_user_id),
  status = COALESCE(status, CASE WHEN COALESCE(is_read, false) THEN 'read' ELSE 'unread' END),
  action_required = COALESCE(action_required, notification_type = 'approval_needed'),
  extra_data = COALESCE(extra_data, '{}'::jsonb),
  title = COALESCE(title, 'إشعار جديد')
WHERE recipient_user_id IS NULL
   OR user_id IS NULL
   OR status IS NULL
   OR action_required IS NULL
   OR extra_data IS NULL
   OR title IS NULL;

CREATE INDEX IF NOT EXISTS movement_notifications_user_visible_idx
  ON public.movement_notifications (user_id, created_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS movement_notifications_user_customer_visible_idx
  ON public.movement_notifications (user_id, customer_id, created_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS movement_notifications_user_attention_idx
  ON public.movement_notifications (user_id, action_required, is_read, status, created_at DESC)
  WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 2) Keep customer_id synchronized for future notifications
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sync_movement_notification_customer_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.customer_id IS NULL AND NEW.movement_id IS NOT NULL THEN
    SELECT am.customer_id
    INTO NEW.customer_id
    FROM public.account_movements am
    WHERE am.id = NEW.movement_id;
  END IF;

  NEW.recipient_user_id := COALESCE(NEW.recipient_user_id, NEW.user_id);
  NEW.user_id := COALESCE(NEW.user_id, NEW.recipient_user_id);
  NEW.status := COALESCE(NEW.status, CASE WHEN COALESCE(NEW.is_read, false) THEN 'read' ELSE 'unread' END);
  NEW.action_required := COALESCE(NEW.action_required, NEW.notification_type = 'approval_needed');
  NEW.extra_data := COALESCE(NEW.extra_data, '{}'::jsonb);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_movement_notification_customer_id ON public.movement_notifications;
CREATE TRIGGER trg_sync_movement_notification_customer_id
BEFORE INSERT OR UPDATE OF movement_id, customer_id, user_id, recipient_user_id, status, action_required, extra_data
ON public.movement_notifications
FOR EACH ROW
EXECUTE FUNCTION public.sync_movement_notification_customer_id();

-- -----------------------------------------------------------------------------
-- 3) Normalize old approval_needed notifications that still exist
-- -----------------------------------------------------------------------------

UPDATE public.movement_notifications n
SET
  status = 'approved',
  is_read = true,
  action_required = false,
  acted_at = COALESCE(n.acted_at, am.approved_at, now()),
  extra_data = COALESCE(n.extra_data, '{}'::jsonb) || jsonb_build_object('approval_status', 'approved', 'requires_action', false)
FROM public.account_movements am
WHERE n.movement_id = am.id
  AND n.notification_type = 'approval_needed'
  AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'approved';

UPDATE public.movement_notifications n
SET
  status = 'rejected',
  is_read = true,
  action_required = false,
  acted_at = COALESCE(n.acted_at, am.rejected_at, now()),
  extra_data = COALESCE(n.extra_data, '{}'::jsonb)
    || jsonb_build_object(
      'approval_status', 'rejected',
      'requires_action', false,
      'reject_reason', COALESCE(am.reject_reason, am.void_reason, n.extra_data->>'reject_reason')
    )
FROM public.account_movements am
WHERE n.movement_id = am.id
  AND n.notification_type = 'approval_needed'
  AND public.get_movement_approval_status(am.approval_status, am.pending_approval) = 'rejected';

-- -----------------------------------------------------------------------------
-- 4) Approval RPC: preserve notification history instead of deleting it
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.approve_movement(
  p_movement_id uuid,
  p_user_name text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_user_full_name text;
  v_related_ids uuid[];
  v_pending_count integer := 0;
  v_rejected_or_voided_count integer := 0;
  v_permission_count integer := 0;
  v_creator_count integer := 0;
BEGIN
  SELECT a.id, COALESCE(NULLIF(trim(a.full_name), ''), a.user_name)
  INTO v_user_id, v_user_full_name
  FROM public.app_security a
  WHERE a.user_name = p_user_name
    AND COALESCE(a.is_active, true) = true
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.account_movements WHERE id = p_movement_id) THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  v_related_ids := public.get_approval_related_movement_ids(p_movement_id);

  SELECT COUNT(*)
  INTO v_permission_count
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = ANY(v_related_ids)
    AND (c.user_id = v_user_id OR c.linked_user_id = v_user_id);

  IF v_permission_count = 0 THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT COUNT(*)
  INTO v_creator_count
  FROM public.account_movements am
  WHERE am.id = ANY(v_related_ids)
    AND COALESCE(am.source_user_id, am.created_by_user_id) IS DISTINCT FROM v_user_id;

  IF v_creator_count = 0 THEN
    RAISE EXCEPTION 'لا يمكن لمنشئ الحركة اعتمادها بنفسه';
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE public.get_movement_approval_status(approval_status, pending_approval) = 'pending'),
    COUNT(*) FILTER (
      WHERE public.get_movement_approval_status(approval_status, pending_approval) = 'rejected'
         OR COALESCE(is_voided, false) = true
    )
  INTO v_pending_count, v_rejected_or_voided_count
  FROM public.account_movements
  WHERE id = ANY(v_related_ids);

  IF v_rejected_or_voided_count > 0 THEN
    RAISE EXCEPTION 'لا يمكن قبول حركة مرفوضة أو ملغاة';
  END IF;

  UPDATE public.account_movements
  SET
    approval_status = 'approved',
    pending_approval = false,
    approved_by_user_id = v_user_id,
    approved_at = COALESCE(approved_at, now()),
    rejected_by_user_id = NULL,
    rejected_at = NULL,
    reject_reason = NULL,
    is_voided = false,
    void_type = NULL,
    void_reason = NULL
  WHERE id = ANY(v_related_ids)
    AND public.get_movement_approval_status(approval_status, pending_approval) <> 'approved';

  -- Preserve approval_needed notifications as history.
  UPDATE public.movement_notifications
  SET
    status = 'approved',
    is_read = true,
    action_required = false,
    acted_at = COALESCE(acted_at, now()),
    extra_data = COALESCE(extra_data, '{}'::jsonb)
      || jsonb_build_object(
        'approval_status', 'approved',
        'requires_action', false,
        'approved_by', COALESCE(v_user_full_name, p_user_name),
        'approved_by_user_id', v_user_id
      )
  WHERE notification_type = 'approval_needed'
    AND movement_id = ANY(v_related_ids);

  UPDATE public.movement_notifications
  SET
    status = 'approved',
    is_read = true,
    action_required = false,
    acted_at = COALESCE(acted_at, now()),
    extra_data = COALESCE(extra_data, '{}'::jsonb)
      || jsonb_build_object('approval_status', 'approved', 'requires_action', false)
  WHERE movement_id = ANY(v_related_ids)
    AND notification_type IN ('movement_added', 'movement_approved');

  RETURN json_build_object(
    'success', true,
    'message', CASE WHEN v_pending_count = 0 THEN 'الحركة معتمدة مسبقًا' ELSE 'تم قبول الحركة بنجاح' END,
    'movement_id', p_movement_id,
    'movement_ids', v_related_ids,
    'approved_by', COALESCE(v_user_full_name, p_user_name),
    'status', 'approved'
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 5) Rejection RPC: preserve notification history instead of deleting it
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reject_movement_with_reason(
  p_movement_id uuid,
  p_user_name text,
  p_reject_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_user_full_name text;
  v_reason text;
  v_related_ids uuid[];
  v_permission_count integer := 0;
  v_creator_count integer := 0;
  v_approved_count integer := 0;
BEGIN
  v_reason := NULLIF(trim(COALESCE(p_reject_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'سبب الرفض مطلوب';
  END IF;

  SELECT a.id, COALESCE(NULLIF(trim(a.full_name), ''), a.user_name)
  INTO v_user_id, v_user_full_name
  FROM public.app_security a
  WHERE a.user_name = p_user_name
    AND COALESCE(a.is_active, true) = true
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.account_movements WHERE id = p_movement_id) THEN
    RAISE EXCEPTION 'Movement not found';
  END IF;

  v_related_ids := public.get_approval_related_movement_ids(p_movement_id);

  SELECT COUNT(*)
  INTO v_permission_count
  FROM public.account_movements am
  JOIN public.customers c ON c.id = am.customer_id
  WHERE am.id = ANY(v_related_ids)
    AND (c.user_id = v_user_id OR c.linked_user_id = v_user_id);

  IF v_permission_count = 0 THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT COUNT(*)
  INTO v_creator_count
  FROM public.account_movements am
  WHERE am.id = ANY(v_related_ids)
    AND COALESCE(am.source_user_id, am.created_by_user_id) IS DISTINCT FROM v_user_id;

  IF v_creator_count = 0 THEN
    RAISE EXCEPTION 'لا يمكن لمنشئ الحركة رفضها بنفسه';
  END IF;

  SELECT COUNT(*)
  INTO v_approved_count
  FROM public.account_movements
  WHERE id = ANY(v_related_ids)
    AND public.get_movement_approval_status(approval_status, pending_approval) = 'approved';

  IF v_approved_count > 0 THEN
    RAISE EXCEPTION 'لا يمكن رفض حركة معتمدة مسبقًا';
  END IF;

  UPDATE public.account_movements
  SET
    approval_status = 'rejected',
    pending_approval = false,
    rejected_by_user_id = v_user_id,
    rejected_at = COALESCE(rejected_at, now()),
    approved_by_user_id = NULL,
    approved_at = NULL,
    reject_reason = v_reason,
    is_voided = true,
    void_type = 'rejected',
    void_reason = v_reason
  WHERE id = ANY(v_related_ids);

  -- Preserve approval_needed notifications as history.
  UPDATE public.movement_notifications
  SET
    status = 'rejected',
    is_read = true,
    action_required = false,
    acted_at = COALESCE(acted_at, now()),
    extra_data = COALESCE(extra_data, '{}'::jsonb)
      || jsonb_build_object(
        'approval_status', 'rejected',
        'requires_action', false,
        'reject_reason', v_reason,
        'rejected_by', COALESCE(v_user_full_name, p_user_name),
        'rejected_by_user_id', v_user_id
      )
  WHERE notification_type = 'approval_needed'
    AND movement_id = ANY(v_related_ids);

  UPDATE public.movement_notifications
  SET
    status = 'rejected',
    is_read = true,
    action_required = false,
    acted_at = COALESCE(acted_at, now()),
    extra_data = COALESCE(extra_data, '{}'::jsonb)
      || jsonb_build_object('approval_status', 'rejected', 'requires_action', false, 'reject_reason', v_reason)
  WHERE movement_id = ANY(v_related_ids)
    AND notification_type IN ('movement_added', 'movement_rejected');

  RETURN json_build_object(
    'success', true,
    'message', 'تم رفض الحركة',
    'movement_id', p_movement_id,
    'movement_ids', v_related_ids,
    'rejected_by', COALESCE(v_user_full_name, p_user_name),
    'status', 'rejected',
    'reject_reason', v_reason
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_movement(
  p_movement_id uuid,
  p_user_name text,
  p_reject_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.reject_movement_with_reason(p_movement_id, p_user_name, p_reject_reason);
END;
$$;

COMMIT;
