-- إضافة صفحة حركة الحوالات المالية إلى لوحة تحكم ArtiCodeApp
-- يشغّل مرة واحدة داخل Supabase SQL Editor بعد ملف لوحة الإدارة الأساسي.
-- يعتمد على جدول التطبيق الحالي: public.account_movements

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
SET search_path = public, extensions;

-- دالة جلب كل الحوالات والحركات المالية مع ملخصات الإدارة
CREATE OR REPLACE FUNCTION public.admin_dashboard_get_transfer_movements(
  p_token text,
  p_search text DEFAULT NULL,
  p_direction text DEFAULT 'all',
  p_status text DEFAULT 'all',
  p_limit integer DEFAULT 500
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_admin_id uuid;
  v_result jsonb;
BEGIN
  v_admin_id := public.admin_dashboard_require_session(p_token);

  WITH movement_base AS (
    SELECT
      m.id,
      m.movement_number,
      m.transfer_number,
      m.customer_id,
      c.name AS customer_name,
      c.account_number AS customer_account_number,
      c.user_id AS owner_user_id,
      owner.user_name AS owner_user_name,
      COALESCE(owner.full_name, owner.user_name) AS owner_full_name,
      owner.account_number AS owner_account_number,
      c.linked_user_id,
      linked.user_name AS linked_user_name,
      COALESCE(linked.full_name, linked.user_name) AS linked_full_name,
      m.movement_type,
      m.transfer_direction,
      m.amount,
      m.currency,
      m.commission,
      m.commission_currency,
      m.sender_name,
      m.beneficiary_name,
      m.from_customer_id,
      from_customer.name AS from_customer_name,
      m.to_customer_id,
      to_customer.name AS to_customer_name,
      COALESCE(m.approval_status, CASE WHEN COALESCE(m.pending_approval, false) THEN 'pending' ELSE 'approved' END) AS approval_status,
      COALESCE(m.pending_approval, false) AS pending_approval,
      m.approved_by_user_id,
      m.approved_at,
      m.created_by_user_id,
      COALESCE(created_by.full_name, created_by.user_name) AS created_by_user_name,
      m.source_user_id,
      COALESCE(source_user.full_name, source_user.user_name) AS source_user_name,
      m.related_transfer_id,
      m.mirror_movement_id,
      m.notes,
      m.created_at
    FROM public.account_movements m
    LEFT JOIN public.customers c ON c.id = m.customer_id
    LEFT JOIN public.customers from_customer ON from_customer.id = m.from_customer_id
    LEFT JOIN public.customers to_customer ON to_customer.id = m.to_customer_id
    LEFT JOIN public.app_security owner ON owner.id = c.user_id
    LEFT JOIN public.app_security linked ON linked.id = c.linked_user_id
    LEFT JOIN public.app_security created_by ON created_by.id = m.created_by_user_id
    LEFT JOIN public.app_security source_user ON source_user.id = m.source_user_id
    WHERE COALESCE(m.is_commission_movement, false) = false
      AND (
        p_search IS NULL OR trim(p_search) = '' OR
        lower(COALESCE(m.movement_number, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(m.transfer_number, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(m.sender_name, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(m.beneficiary_name, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(c.name, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(from_customer.name, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(to_customer.name, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(owner.full_name, owner.user_name, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(owner.user_name, '')) LIKE '%' || lower(trim(p_search)) || '%' OR
        lower(COALESCE(owner.account_number, '')) LIKE '%' || lower(trim(p_search)) || '%'
      )
      AND (
        COALESCE(p_direction, 'all') = 'all' OR
        m.movement_type = p_direction OR
        m.transfer_direction = p_direction
      )
      AND (
        COALESCE(p_status, 'all') = 'all' OR
        COALESCE(m.approval_status, CASE WHEN COALESCE(m.pending_approval, false) THEN 'pending' ELSE 'approved' END) = p_status
      )
  ), limited_movements AS (
    SELECT *
    FROM movement_base
    ORDER BY created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 500), 1), 1000)
  )
  SELECT jsonb_build_object(
    'stats', jsonb_build_object(
      'total_movements', COALESCE((SELECT count(*) FROM movement_base), 0),
      'incoming_movements', COALESCE((SELECT count(*) FROM movement_base WHERE movement_type = 'incoming'), 0),
      'outgoing_movements', COALESCE((SELECT count(*) FROM movement_base WHERE movement_type = 'outgoing'), 0),
      'customer_to_customer', COALESCE((SELECT count(*) FROM movement_base WHERE transfer_direction = 'customer_to_customer'), 0),
      'shop_to_customer', COALESCE((SELECT count(*) FROM movement_base WHERE transfer_direction = 'shop_to_customer'), 0),
      'customer_to_shop', COALESCE((SELECT count(*) FROM movement_base WHERE transfer_direction = 'customer_to_shop'), 0),
      'pending_approval', COALESCE((SELECT count(*) FROM movement_base WHERE approval_status = 'pending' OR pending_approval = true), 0),
      'approved_movements', COALESCE((SELECT count(*) FROM movement_base WHERE approval_status = 'approved'), 0),
      'rejected_movements', COALESCE((SELECT count(*) FROM movement_base WHERE approval_status = 'rejected'), 0),
      'total_amount_by_currency', COALESCE((
        SELECT jsonb_agg(row_to_json(cu) ORDER BY cu.currency)
        FROM (
          SELECT
            currency,
            COALESCE(SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE 0 END), 0) AS incoming_amount,
            COALESCE(SUM(CASE WHEN movement_type = 'outgoing' THEN amount ELSE 0 END), 0) AS outgoing_amount,
            COALESCE(SUM(CASE WHEN movement_type = 'incoming' THEN amount ELSE -amount END), 0) AS net_amount
          FROM movement_base
          GROUP BY currency
          ORDER BY currency
        ) cu
      ), '[]'::jsonb)
    ),
    'user_summary', COALESCE((
      SELECT jsonb_agg(row_to_json(us) ORDER BY us.total_movements DESC, us.last_movement_at DESC NULLS LAST)
      FROM (
        SELECT
          COALESCE(owner_user_id, created_by_user_id, source_user_id) AS user_id,
          COALESCE(owner_user_name, created_by_user_name, source_user_name) AS user_name,
          COALESCE(owner_full_name, created_by_user_name, source_user_name, 'غير مرتبط بمستخدم') AS full_name,
          owner_account_number AS account_number,
          count(*) AS total_movements,
          count(*) FILTER (WHERE movement_type = 'incoming') AS incoming_movements,
          count(*) FILTER (WHERE movement_type = 'outgoing') AS outgoing_movements,
          max(created_at) AS last_movement_at
        FROM movement_base
        GROUP BY COALESCE(owner_user_id, created_by_user_id, source_user_id), COALESCE(owner_user_name, created_by_user_name, source_user_name), COALESCE(owner_full_name, created_by_user_name, source_user_name, 'غير مرتبط بمستخدم'), owner_account_number
        ORDER BY count(*) DESC, max(created_at) DESC NULLS LAST
        LIMIT 50
      ) us
    ), '[]'::jsonb),
    'movements', COALESCE((
      SELECT jsonb_agg(row_to_json(lm))
      FROM limited_movements lm
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- تحديث تفاصيل المستخدم حتى تعرض الحوالات داخل Drawer المستخدم
CREATE OR REPLACE FUNCTION public.admin_dashboard_get_user_detail(
  p_token text,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_admin_id uuid;
BEGIN
  v_admin_id := public.admin_dashboard_require_session(p_token);

  RETURN jsonb_build_object(
    'user', (
      SELECT to_jsonb(u)
      FROM (
        SELECT id, user_name, COALESCE(full_name, user_name) AS full_name, account_number, role, is_active, created_at, updated_at, last_login
        FROM public.app_security
        WHERE id = p_user_id
      ) u
    ),
    'subscriptions', COALESCE((
      SELECT jsonb_agg(row_to_json(sx))
      FROM (
        SELECT *, public.admin_dashboard_effective_subscription_status(status, end_date) AS effective_status
        FROM public.admin_subscriptions
        WHERE user_id = p_user_id
        ORDER BY end_date DESC, created_at DESC
      ) sx
    ), '[]'::jsonb),
    'payments', COALESCE((
      SELECT jsonb_agg(row_to_json(px))
      FROM (
        SELECT p.*, s.plan_name, s.billing_cycle
        FROM public.admin_payments p
        LEFT JOIN public.admin_subscriptions s ON s.id = p.subscription_id
        WHERE p.user_id = p_user_id
        ORDER BY p.paid_at DESC
        LIMIT 100
      ) px
    ), '[]'::jsonb),
    'transfers', COALESCE((
      SELECT jsonb_agg(row_to_json(tx))
      FROM (
        SELECT
          m.id,
          m.movement_number,
          m.transfer_number,
          m.customer_id,
          c.name AS customer_name,
          c.account_number AS customer_account_number,
          c.user_id AS owner_user_id,
          owner.user_name AS owner_user_name,
          COALESCE(owner.full_name, owner.user_name) AS owner_full_name,
          owner.account_number AS owner_account_number,
          c.linked_user_id,
          linked.user_name AS linked_user_name,
          COALESCE(linked.full_name, linked.user_name) AS linked_full_name,
          m.movement_type,
          m.transfer_direction,
          m.amount,
          m.currency,
          m.commission,
          m.commission_currency,
          m.sender_name,
          m.beneficiary_name,
          m.from_customer_id,
          from_customer.name AS from_customer_name,
          m.to_customer_id,
          to_customer.name AS to_customer_name,
          COALESCE(m.approval_status, CASE WHEN COALESCE(m.pending_approval, false) THEN 'pending' ELSE 'approved' END) AS approval_status,
          COALESCE(m.pending_approval, false) AS pending_approval,
          m.approved_by_user_id,
          m.approved_at,
          m.created_by_user_id,
          COALESCE(created_by.full_name, created_by.user_name) AS created_by_user_name,
          m.source_user_id,
          COALESCE(source_user.full_name, source_user.user_name) AS source_user_name,
          m.related_transfer_id,
          m.mirror_movement_id,
          m.notes,
          m.created_at
        FROM public.account_movements m
        LEFT JOIN public.customers c ON c.id = m.customer_id
        LEFT JOIN public.customers from_customer ON from_customer.id = m.from_customer_id
        LEFT JOIN public.customers to_customer ON to_customer.id = m.to_customer_id
        LEFT JOIN public.app_security owner ON owner.id = c.user_id
        LEFT JOIN public.app_security linked ON linked.id = c.linked_user_id
        LEFT JOIN public.app_security created_by ON created_by.id = m.created_by_user_id
        LEFT JOIN public.app_security source_user ON source_user.id = m.source_user_id
        WHERE COALESCE(m.is_commission_movement, false) = false
          AND (
            c.user_id = p_user_id OR
            c.linked_user_id = p_user_id OR
            m.created_by_user_id = p_user_id OR
            m.source_user_id = p_user_id
          )
        ORDER BY m.created_at DESC
        LIMIT 200
      ) tx
    ), '[]'::jsonb),
    'activity', COALESCE((
      SELECT jsonb_agg(row_to_json(ax))
      FROM (
        SELECT * FROM (
          SELECT
            l.id::text AS id,
            'admin_activity' AS source,
            l.action,
            l.details,
            l.device,
            l.ip_address,
            l.created_at
          FROM public.admin_activity_logs l
          WHERE l.user_id = p_user_id

          UNION ALL

          SELECT
            la.id::text AS id,
            'login_attempt' AS source,
            CASE WHEN la.success THEN 'login_success' ELSE 'login_failed' END AS action,
            jsonb_build_object('user_name', la.user_name, 'success', la.success) AS details,
            la.device_info AS device,
            la.ip_address,
            la.attempted_at AS created_at
          FROM public.login_attempts la
          JOIN public.app_security a ON lower(a.user_name) = lower(la.user_name)
          WHERE a.id = p_user_id

          UNION ALL

          SELECT
            m.id::text AS id,
            'account_movement' AS source,
            'account_movement_' || m.movement_type AS action,
            jsonb_build_object(
              'movement_number', m.movement_number,
              'transfer_number', m.transfer_number,
              'movement_type', m.movement_type,
              'transfer_direction', m.transfer_direction,
              'amount', m.amount,
              'currency', m.currency,
              'sender_name', m.sender_name,
              'beneficiary_name', m.beneficiary_name,
              'notes', m.notes
            ) AS details,
            NULL::text AS device,
            NULL::text AS ip_address,
            m.created_at
          FROM public.account_movements m
          LEFT JOIN public.customers c ON c.id = m.customer_id
          WHERE c.user_id = p_user_id OR c.linked_user_id = p_user_id OR m.created_by_user_id = p_user_id OR m.source_user_id = p_user_id
        ) q
        ORDER BY created_at DESC
        LIMIT 150
      ) ax
    ), '[]'::jsonb)
  );
END;
$$;
