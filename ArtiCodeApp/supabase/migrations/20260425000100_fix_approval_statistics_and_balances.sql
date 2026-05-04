/*
  Fix approval workflow, statistics visibility, and balance calculation.

  Important compatibility notes:
  - The current Expo app uses custom PIN users and the anon key, so this migration keeps
    permissive RLS for movement_notifications to avoid breaking the existing login flow.
  - The notifications screen expects user_id, is_read, notification_type, message,
    movement_number, amount, currency, movement_type, customer_name, actor_name, extra_data.
  - The notifications screen calls approve_movement with p_user_name and
    reject_movement_with_reason with p_user_name + p_reject_reason.
*/

-- ------------------------------------------------------------
-- 1) account_movements approval columns
-- ------------------------------------------------------------
ALTER TABLE account_movements
  ADD COLUMN IF NOT EXISTS pending_approval boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS approval_status text,
  ADD COLUMN IF NOT EXISTS approved_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS rejected_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS rejected_at timestamptz,
  ADD COLUMN IF NOT EXISTS reject_reason text,
  ADD COLUMN IF NOT EXISTS is_voided boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS void_type text,
  ADD COLUMN IF NOT EXISTS void_reason text,
  ADD COLUMN IF NOT EXISTS created_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS created_by_user_name text,
  ADD COLUMN IF NOT EXISTS source_user_id uuid,
  ADD COLUMN IF NOT EXISTS mirror_movement_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'account_movements_approval_status_check'
  ) THEN
    ALTER TABLE account_movements
      ADD CONSTRAINT account_movements_approval_status_check
      CHECK (approval_status IS NULL OR approval_status IN ('pending', 'approved', 'rejected'));
  END IF;
END $$;

UPDATE account_movements
SET approval_status = CASE
    WHEN COALESCE(pending_approval, false) = true THEN 'pending'
    ELSE 'approved'
  END
WHERE approval_status IS NULL;

UPDATE account_movements
SET pending_approval = (approval_status = 'pending')
WHERE pending_approval IS DISTINCT FROM (approval_status = 'pending');

CREATE INDEX IF NOT EXISTS account_movements_approval_status_idx
  ON account_movements (approval_status);

CREATE INDEX IF NOT EXISTS account_movements_pending_approval_idx
  ON account_movements (pending_approval)
  WHERE pending_approval = true;

CREATE INDEX IF NOT EXISTS account_movements_customer_approval_idx
  ON account_movements (customer_id, approval_status, is_voided);

-- ------------------------------------------------------------
-- 2) movement_notifications table compatible with current app
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS movement_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  movement_id uuid REFERENCES account_movements(id) ON DELETE CASCADE,
  notification_type text NOT NULL DEFAULT 'approval_needed',
  message text NOT NULL DEFAULT '',
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  movement_number text,
  amount decimal(15, 2),
  currency text,
  movement_type text,
  customer_name text,
  actor_name text,
  extra_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  customer_id uuid REFERENCES customers(id) ON DELETE CASCADE,
  sender_user_id uuid,
  recipient_user_id uuid,
  title text,
  status text NOT NULL DEFAULT 'unread',
  action_required boolean NOT NULL DEFAULT true,
  read_at timestamptz,
  acted_at timestamptz
);

ALTER TABLE movement_notifications
  ADD COLUMN IF NOT EXISTS user_id uuid,
  ADD COLUMN IF NOT EXISTS movement_id uuid REFERENCES account_movements(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS notification_type text NOT NULL DEFAULT 'approval_needed',
  ADD COLUMN IF NOT EXISTS message text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS is_read boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS movement_number text,
  ADD COLUMN IF NOT EXISTS amount decimal(15, 2),
  ADD COLUMN IF NOT EXISTS currency text,
  ADD COLUMN IF NOT EXISTS movement_type text,
  ADD COLUMN IF NOT EXISTS customer_name text,
  ADD COLUMN IF NOT EXISTS actor_name text,
  ADD COLUMN IF NOT EXISTS extra_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS customer_id uuid REFERENCES customers(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS sender_user_id uuid,
  ADD COLUMN IF NOT EXISTS recipient_user_id uuid,
  ADD COLUMN IF NOT EXISTS title text,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'unread',
  ADD COLUMN IF NOT EXISTS action_required boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS read_at timestamptz,
  ADD COLUMN IF NOT EXISTS acted_at timestamptz;

UPDATE movement_notifications
SET recipient_user_id = COALESCE(recipient_user_id, user_id),
    user_id = COALESCE(user_id, recipient_user_id),
    title = COALESCE(title, 'إشعار جديد')
WHERE user_id IS NULL OR recipient_user_id IS NULL OR title IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS movement_notifications_unique_approval_idx
  ON movement_notifications (movement_id, user_id, notification_type)
  WHERE notification_type = 'approval_needed';

CREATE INDEX IF NOT EXISTS movement_notifications_user_read_idx
  ON movement_notifications (user_id, is_read, created_at DESC);

CREATE INDEX IF NOT EXISTS movement_notifications_recipient_status_idx
  ON movement_notifications (recipient_user_id, status, created_at DESC);

ALTER TABLE movement_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow all operations on movement_notifications" ON movement_notifications;
CREATE POLICY "Allow all operations on movement_notifications"
  ON movement_notifications
  FOR ALL
  USING (true)
  WITH CHECK (true);

-- ------------------------------------------------------------
-- 3) Related movement helper
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_related_approval_movement_ids(p_movement_id uuid)
RETURNS TABLE (movement_id uuid)
LANGUAGE sql
AS $$
  WITH base AS (
    SELECT id, related_transfer_id, mirror_movement_id
    FROM account_movements
    WHERE id = p_movement_id
  )
  SELECT DISTINCT am.id
  FROM account_movements am, base b
  WHERE am.id = b.id
     OR am.id = b.related_transfer_id
     OR am.related_transfer_id = b.id
     OR am.id = b.mirror_movement_id
     OR am.mirror_movement_id = b.id;
$$;

-- ------------------------------------------------------------
-- 4) Approve / reject RPC functions compatible with current app
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_movement(
  p_movement_id uuid,
  p_user_name text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_movement account_movements%ROWTYPE;
  v_customer customers%ROWTYPE;
  v_related_ids uuid[];
  v_actor_id uuid;
BEGIN
  IF p_user_id IS NOT NULL THEN
    v_actor_id := p_user_id;
  ELSIF p_user_name IS NOT NULL THEN
    SELECT id INTO v_actor_id
    FROM app_security
    WHERE user_name = p_user_name
    LIMIT 1;
  END IF;

  SELECT * INTO v_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'الحركة غير موجودة');
  END IF;

  SELECT * INTO v_customer
  FROM customers
  WHERE id = v_movement.customer_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'العميل غير موجود');
  END IF;

  IF v_actor_id IS NOT NULL
     AND v_customer.linked_user_id IS NOT NULL
     AND v_customer.linked_user_id <> v_actor_id THEN
    RETURN json_build_object('success', false, 'message', 'لا تملك صلاحية الموافقة على هذه الحركة');
  END IF;

  IF COALESCE(v_movement.is_voided, false) = true OR v_movement.approval_status = 'rejected' THEN
    RETURN json_build_object('success', false, 'message', 'لا يمكن قبول حركة مرفوضة أو ملغاة');
  END IF;

  SELECT array_agg(movement_id) INTO v_related_ids
  FROM get_related_approval_movement_ids(p_movement_id);

  UPDATE account_movements
  SET pending_approval = false,
      approval_status = 'approved',
      approved_by_user_id = v_actor_id,
      approved_at = COALESCE(approved_at, now()),
      rejected_by_user_id = NULL,
      rejected_at = NULL,
      reject_reason = NULL,
      is_voided = false,
      void_type = NULL,
      void_reason = NULL
  WHERE id = ANY(v_related_ids);

  UPDATE movement_notifications
  SET status = 'approved',
      is_read = true,
      action_required = false,
      acted_at = COALESCE(acted_at, now())
  WHERE movement_id = ANY(v_related_ids)
    AND notification_type = 'approval_needed';

  INSERT INTO movement_notifications (
    user_id, recipient_user_id, movement_id, customer_id, sender_user_id,
    notification_type, title, message, movement_number, amount, currency,
    movement_type, customer_name, actor_name, status, action_required, extra_data
  )
  SELECT DISTINCT
    COALESCE(am.created_by_user_id, c.user_id),
    COALESCE(am.created_by_user_id, c.user_id),
    am.id,
    am.customer_id,
    v_actor_id,
    'movement_approved',
    'تم اعتماد الحركة',
    'تم اعتماد الحركة الخاصة بـ ' || COALESCE(c.name, 'عميل') || '.',
    am.movement_number,
    am.amount,
    am.currency,
    am.movement_type,
    c.name,
    COALESCE(p_user_name, 'الطرف الآخر'),
    'unread',
    false,
    '{}'::jsonb
  FROM account_movements am
  JOIN customers c ON c.id = am.customer_id
  WHERE am.id = ANY(v_related_ids)
    AND COALESCE(am.created_by_user_id, c.user_id) IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN json_build_object('success', true, 'message', 'تم قبول الحركة بنجاح', 'movement_ids', v_related_ids);
END;
$$;

CREATE OR REPLACE FUNCTION reject_movement_with_reason(
  p_movement_id uuid,
  p_user_name text DEFAULT NULL,
  p_reject_reason text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_movement account_movements%ROWTYPE;
  v_customer customers%ROWTYPE;
  v_related_ids uuid[];
  v_actor_id uuid;
  v_reason text;
BEGIN
  v_reason := NULLIF(trim(COALESCE(p_reject_reason, p_reason, '')), '');

  IF p_user_id IS NOT NULL THEN
    v_actor_id := p_user_id;
  ELSIF p_user_name IS NOT NULL THEN
    SELECT id INTO v_actor_id
    FROM app_security
    WHERE user_name = p_user_name
    LIMIT 1;
  END IF;

  SELECT * INTO v_movement
  FROM account_movements
  WHERE id = p_movement_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'الحركة غير موجودة');
  END IF;

  SELECT * INTO v_customer
  FROM customers
  WHERE id = v_movement.customer_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'العميل غير موجود');
  END IF;

  IF v_actor_id IS NOT NULL
     AND v_customer.linked_user_id IS NOT NULL
     AND v_customer.linked_user_id <> v_actor_id THEN
    RETURN json_build_object('success', false, 'message', 'لا تملك صلاحية رفض هذه الحركة');
  END IF;

  SELECT array_agg(movement_id) INTO v_related_ids
  FROM get_related_approval_movement_ids(p_movement_id);

  UPDATE account_movements
  SET pending_approval = false,
      approval_status = 'rejected',
      rejected_by_user_id = v_actor_id,
      rejected_at = COALESCE(rejected_at, now()),
      reject_reason = v_reason,
      is_voided = true,
      void_type = 'rejected_by_counterparty',
      void_reason = v_reason
  WHERE id = ANY(v_related_ids);

  UPDATE movement_notifications
  SET status = 'rejected',
      is_read = true,
      action_required = false,
      acted_at = COALESCE(acted_at, now()),
      extra_data = COALESCE(extra_data, '{}'::jsonb) || jsonb_build_object('reject_reason', v_reason)
  WHERE movement_id = ANY(v_related_ids)
    AND notification_type = 'approval_needed';

  INSERT INTO movement_notifications (
    user_id, recipient_user_id, movement_id, customer_id, sender_user_id,
    notification_type, title, message, movement_number, amount, currency,
    movement_type, customer_name, actor_name, status, action_required, extra_data
  )
  SELECT DISTINCT
    COALESCE(am.created_by_user_id, c.user_id),
    COALESCE(am.created_by_user_id, c.user_id),
    am.id,
    am.customer_id,
    v_actor_id,
    'movement_rejected',
    'تم رفض الحركة',
    'تم رفض الحركة الخاصة بـ ' || COALESCE(c.name, 'عميل') || '.',
    am.movement_number,
    am.amount,
    am.currency,
    am.movement_type,
    c.name,
    COALESCE(p_user_name, 'الطرف الآخر'),
    'unread',
    false,
    jsonb_build_object('reject_reason', v_reason)
  FROM account_movements am
  JOIN customers c ON c.id = am.customer_id
  WHERE am.id = ANY(v_related_ids)
    AND COALESCE(am.created_by_user_id, c.user_id) IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN json_build_object('success', true, 'message', 'تم رفض الحركة', 'movement_ids', v_related_ids);
END;
$$;

CREATE OR REPLACE FUNCTION reject_movement(
  p_movement_id uuid,
  p_user_name text DEFAULT NULL,
  p_reject_reason text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN reject_movement_with_reason(p_movement_id, p_user_name, p_reject_reason, p_user_id, p_reason);
END;
$$;

-- ------------------------------------------------------------
-- 5) Automatic notification trigger for pending linked movements
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_pending_movement_notification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_customer customers%ROWTYPE;
  v_title text;
  v_message text;
BEGIN
  IF COALESCE(NEW.is_commission_movement, false) = true THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.pending_approval, false) = false
     AND COALESCE(NEW.approval_status, 'approved') <> 'pending' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_customer
  FROM customers
  WHERE id = NEW.customer_id;

  IF NOT FOUND OR v_customer.linked_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_title := 'حركة بانتظار موافقتك';
  v_message := 'توجد حركة على حساب ' || COALESCE(v_customer.name, 'عميل') ||
               ' بمبلغ ' || COALESCE(NEW.amount::text, '0') || ' ' || COALESCE(NEW.currency, '') ||
               ' وتحتاج موافقتك.';

  INSERT INTO movement_notifications (
    user_id, movement_id, customer_id, sender_user_id, recipient_user_id,
    notification_type, title, message, movement_number, amount, currency,
    movement_type, customer_name, actor_name, status, action_required, extra_data
  )
  VALUES (
    v_customer.linked_user_id,
    NEW.id,
    NEW.customer_id,
    COALESCE(NEW.created_by_user_id, v_customer.user_id),
    v_customer.linked_user_id,
    'approval_needed',
    v_title,
    v_message,
    NEW.movement_number,
    NEW.amount,
    NEW.currency,
    NEW.movement_type,
    v_customer.name,
    COALESCE(NEW.created_by_user_name, 'الطرف الآخر'),
    'unread',
    true,
    '{}'::jsonb
  )
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_create_pending_movement_notification ON account_movements;
CREATE TRIGGER trigger_create_pending_movement_notification
AFTER INSERT OR UPDATE OF pending_approval, approval_status
ON account_movements
FOR EACH ROW
EXECUTE FUNCTION create_pending_movement_notification();

INSERT INTO movement_notifications (
  user_id, movement_id, customer_id, sender_user_id, recipient_user_id,
  notification_type, title, message, movement_number, amount, currency,
  movement_type, customer_name, actor_name, status, action_required, extra_data
)
SELECT
  c.linked_user_id,
  am.id,
  am.customer_id,
  COALESCE(am.created_by_user_id, c.user_id),
  c.linked_user_id,
  'approval_needed',
  'حركة بانتظار موافقتك',
  'توجد حركة على حساب ' || COALESCE(c.name, 'عميل') || ' بمبلغ ' || am.amount::text || ' ' || COALESCE(am.currency, '') || ' وتحتاج موافقتك.',
  am.movement_number,
  am.amount,
  am.currency,
  am.movement_type,
  c.name,
  COALESCE(am.created_by_user_name, 'الطرف الآخر'),
  'unread',
  true,
  '{}'::jsonb
FROM account_movements am
JOIN customers c ON c.id = am.customer_id
WHERE c.linked_user_id IS NOT NULL
  AND COALESCE(am.is_commission_movement, false) = false
  AND COALESCE(am.is_voided, false) = false
  AND (COALESCE(am.pending_approval, false) = true OR am.approval_status = 'pending')
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- 6) Balance views: approved movements only
-- ------------------------------------------------------------
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;
CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  c.user_id,
  c.linked_user_id,
  am.currency,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  COALESCE(SUM(
    CASE
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ), 0) AS balance
FROM customers c
JOIN account_movements am
  ON c.id = am.customer_id
  AND COALESCE(am.is_commission_movement, false) = false
  AND COALESCE(am.is_voided, false) = false
  AND COALESCE(
    am.approval_status,
    CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END
  ) = 'approved'
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, c.user_id, c.linked_user_id, am.currency
HAVING COALESCE(SUM(
  CASE
    WHEN am.movement_type = 'incoming' THEN am.amount
    WHEN am.movement_type = 'outgoing' THEN -am.amount
    ELSE 0
  END
), 0) <> 0
OR EXISTS (
  SELECT 1 FROM customers pc
  WHERE pc.id = c.id
    AND (pc.phone = 'PROFIT_LOSS_ACCOUNT' OR COALESCE(pc.is_profit_loss_account, false) = true)
)
ORDER BY c.name, ABS(COALESCE(SUM(
  CASE
    WHEN am.movement_type = 'incoming' THEN am.amount
    WHEN am.movement_type = 'outgoing' THEN -am.amount
    ELSE 0
  END
), 0)) DESC;

CREATE OR REPLACE VIEW customer_balances AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.user_id,
  c.linked_user_id,
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  COALESCE(SUM(
    CASE
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ), 0) AS balance,
  COUNT(am.id) AS total_movements,
  MAX(am.created_at) AS last_activity
FROM customers c
LEFT JOIN account_movements am
  ON c.id = am.customer_id
  AND COALESCE(am.is_commission_movement, false) = false
  AND COALESCE(am.is_voided, false) = false
  AND COALESCE(
    am.approval_status,
    CASE WHEN COALESCE(am.pending_approval, false) THEN 'pending' ELSE 'approved' END
  ) = 'approved'
WHERE c.phone IS DISTINCT FROM 'PROFIT_LOSS_ACCOUNT'
GROUP BY c.id, c.name, c.phone, c.user_id, c.linked_user_id;

COMMENT ON VIEW customer_balances_by_currency IS
  'Balances by currency. Pending, rejected, and voided movements are excluded.';

COMMENT ON VIEW customer_balances IS
  'Customer balances. Pending, rejected, and voided movements are excluded.';

-- ------------------------------------------------------------
-- 7) Realtime
-- ------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE movement_notifications;
  EXCEPTION
    WHEN duplicate_object THEN NULL;
    WHEN undefined_object THEN NULL;
  END;
END $$;
