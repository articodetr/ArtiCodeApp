/*
  Admin Dashboard for ArtiCodeApp
  - Adds subscription, payment, and activity tracking tables.
  - Adds secure RPC functions used by the standalone web dashboard.
  - Uses existing app_security users table as the real source of users.
*/

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
SET search_path = public, extensions;

-- 1) Tables -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.app_security(id) ON DELETE CASCADE,
  plan_name text NOT NULL DEFAULT 'الخطة الأساسية',
  billing_cycle text NOT NULL DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly', 'yearly')),
  start_date date NOT NULL DEFAULT CURRENT_DATE,
  end_date date NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'canceled', 'trial')),
  amount numeric(12,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  auto_renew boolean NOT NULL DEFAULT false,
  max_customers integer NOT NULL DEFAULT 999999,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_subscriptions_user_id ON public.admin_subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_admin_subscriptions_dates ON public.admin_subscriptions(start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_admin_subscriptions_status ON public.admin_subscriptions(status);
CREATE INDEX IF NOT EXISTS idx_admin_subscriptions_cycle ON public.admin_subscriptions(billing_cycle);
CREATE INDEX IF NOT EXISTS idx_admin_subscriptions_max_customers ON public.admin_subscriptions(max_customers);

CREATE TABLE IF NOT EXISTS public.admin_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.app_security(id) ON DELETE CASCADE,
  subscription_id uuid REFERENCES public.admin_subscriptions(id) ON DELETE SET NULL,
  amount numeric(12,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  status text NOT NULL DEFAULT 'paid' CHECK (status IN ('paid', 'pending', 'failed', 'refunded')),
  paid_at timestamptz NOT NULL DEFAULT now(),
  invoice_no text,
  payment_method text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_payments_user_id ON public.admin_payments(user_id);
CREATE INDEX IF NOT EXISTS idx_admin_payments_subscription_id ON public.admin_payments(subscription_id);
CREATE INDEX IF NOT EXISTS idx_admin_payments_paid_at ON public.admin_payments(paid_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_payments_status ON public.admin_payments(status);

CREATE TABLE IF NOT EXISTS public.admin_activity_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.app_security(id) ON DELETE CASCADE,
  actor_admin_id uuid REFERENCES public.app_security(id) ON DELETE SET NULL,
  action text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  device text,
  ip_address text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_activity_logs_user_id ON public.admin_activity_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_admin_activity_logs_actor ON public.admin_activity_logs(actor_admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_activity_logs_created_at ON public.admin_activity_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_activity_logs_action ON public.admin_activity_logs(action);

CREATE TABLE IF NOT EXISTS public.admin_dashboard_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL REFERENCES public.app_security(id) ON DELETE CASCADE,
  user_name text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  device_info text,
  ip_address text,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '8 hours'),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_dashboard_sessions_hash ON public.admin_dashboard_sessions(token_hash);
CREATE INDEX IF NOT EXISTS idx_admin_dashboard_sessions_user ON public.admin_dashboard_sessions(admin_user_id);
CREATE INDEX IF NOT EXISTS idx_admin_dashboard_sessions_expires ON public.admin_dashboard_sessions(expires_at);

-- 2) Helpers ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_dashboard_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_admin_subscriptions_updated_at ON public.admin_subscriptions;
CREATE TRIGGER trg_admin_subscriptions_updated_at
BEFORE UPDATE ON public.admin_subscriptions
FOR EACH ROW
EXECUTE FUNCTION public.admin_dashboard_set_updated_at();

CREATE OR REPLACE FUNCTION public.admin_dashboard_effective_subscription_status(
  p_status text,
  p_end_date date
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
    WHEN p_status = 'canceled' THEN 'canceled'
    WHEN p_status = 'expired' THEN 'expired'
    WHEN p_end_date < CURRENT_DATE THEN 'expired'
    WHEN p_end_date <= CURRENT_DATE + 7 THEN 'ending_soon'
    ELSE COALESCE(p_status, 'active')
  END;
$$;


-- حدود العملاء حسب الاشتراك الحالي: الخطة المجانية = 5 عملاء، والخطط المدفوعة حسب max_customers.
CREATE OR REPLACE FUNCTION public.admin_dashboard_get_customer_quota_snapshot(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_customer_count integer := 0;
  v_limit integer;
  v_free_limit integer := 5;
  v_has_active boolean := false;
  v_subscription_id uuid;
  v_plan_name text;
  v_end_date date;
  v_effective_status text;
BEGIN
  SELECT COUNT(*)::integer
  INTO v_customer_count
  FROM public.customers c
  WHERE c.user_id = p_user_id
    AND COALESCE(c.is_profit_loss_account, false) = false;

  SELECT
    s.id,
    GREATEST(COALESCE(s.max_customers, 999999), v_free_limit),
    s.plan_name,
    s.end_date,
    public.admin_dashboard_effective_subscription_status(s.status, s.end_date)
  INTO v_subscription_id, v_limit, v_plan_name, v_end_date, v_effective_status
  FROM public.admin_subscriptions s
  WHERE s.user_id = p_user_id
    AND public.admin_dashboard_effective_subscription_status(s.status, s.end_date) IN ('active', 'ending_soon', 'trial')
  ORDER BY s.end_date DESC, s.created_at DESC
  LIMIT 1;

  v_has_active := v_subscription_id IS NOT NULL;
  v_limit := COALESCE(v_limit, v_free_limit);

  RETURN jsonb_build_object(
    'customer_count', v_customer_count,
    'customer_limit', v_limit,
    'free_customer_limit', v_free_limit,
    'has_active_subscription', v_has_active,
    'can_add_customer', v_customer_count < v_limit,
    'subscription_id', v_subscription_id,
    'plan_name', v_plan_name,
    'end_date', v_end_date,
    'subscription_status', v_effective_status,
    'quota_message', CASE
      WHEN v_customer_count >= v_limit AND v_has_active THEN 'وصل المستخدم إلى الحد المسموح في الاشتراك الحالي'
      WHEN v_customer_count >= v_limit THEN 'وصل المستخدم إلى الحد المجاني، يجب تفعيل الاشتراك'
      ELSE 'يمكن إضافة عميل'
    END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_get_user_quota(
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
  RETURN public.admin_dashboard_get_customer_quota_snapshot(p_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_verify_pin(
  p_pin text,
  p_pin_hash text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_salt text;
  v_hash text;
BEGIN
  IF p_pin IS NULL OR p_pin_hash IS NULL THEN
    RETURN false;
  END IF;

  -- New Expo format: salt:sha256(pin + salt)
  IF position(':' in p_pin_hash) > 0 THEN
    v_salt := split_part(p_pin_hash, ':', 1);
    v_hash := split_part(p_pin_hash, ':', 2);
    RETURN encode(digest(p_pin || v_salt, 'sha256'::text), 'hex') = v_hash;
  END IF;

  -- Legacy bcrypt/crypt format, if pgcrypto crypt() can verify it.
  IF p_pin_hash LIKE '$2%' OR p_pin_hash LIKE '$argon2%' THEN
    BEGIN
      RETURN crypt(p_pin, p_pin_hash) = p_pin_hash;
    EXCEPTION WHEN others THEN
      RETURN false;
    END;
  END IF;

  -- Legacy raw SHA256 format.
  RETURN encode(digest(p_pin, 'sha256'::text), 'hex') = p_pin_hash;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_require_session(p_token text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_admin_id uuid;
BEGIN
  IF p_token IS NULL OR length(trim(p_token)) < 20 THEN
    RAISE EXCEPTION 'ADMIN_SESSION_REQUIRED';
  END IF;

  SELECT s.admin_user_id
  INTO v_admin_id
  FROM public.admin_dashboard_sessions s
  JOIN public.app_security u ON u.id = s.admin_user_id
  WHERE s.token_hash = encode(digest(p_token, 'sha256'::text), 'hex')
    AND s.expires_at > now()
    AND u.is_active = true
    AND lower(u.role) IN ('admin', 'super_admin')
  LIMIT 1;

  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SESSION_EXPIRED_OR_INVALID';
  END IF;

  UPDATE public.admin_dashboard_sessions
  SET last_seen_at = now()
  WHERE token_hash = encode(digest(p_token, 'sha256'::text), 'hex');

  RETURN v_admin_id;
END;
$$;

-- 3) Auth RPCs ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_dashboard_login(
  p_user_name text,
  p_pin text,
  p_device_info text DEFAULT NULL,
  p_ip_address text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_user public.app_security%ROWTYPE;
  v_token text;
  v_expires timestamptz;
BEGIN
  DELETE FROM public.admin_dashboard_sessions WHERE expires_at < now();

  SELECT * INTO v_user
  FROM public.app_security
  WHERE lower(user_name) = lower(trim(p_user_name))
  LIMIT 1;

  IF v_user.id IS NULL THEN
    INSERT INTO public.login_attempts(user_name, success, ip_address, device_info)
    VALUES (COALESCE(p_user_name, ''), false, p_ip_address, p_device_info);
    RETURN jsonb_build_object('success', false, 'message', 'اسم المستخدم أو كلمة المرور غير صحيحة');
  END IF;

  IF COALESCE(v_user.is_active, true) = false THEN
    RETURN jsonb_build_object('success', false, 'message', 'الحساب غير نشط');
  END IF;

  IF lower(COALESCE(v_user.role, 'user')) NOT IN ('admin', 'super_admin') THEN
    RETURN jsonb_build_object('success', false, 'message', 'هذا الحساب ليس لديه صلاحية دخول لوحة الإدارة');
  END IF;

  IF NOT public.admin_dashboard_verify_pin(p_pin, v_user.pin_hash) THEN
    INSERT INTO public.login_attempts(user_name, success, ip_address, device_info)
    VALUES (v_user.user_name, false, p_ip_address, p_device_info);
    RETURN jsonb_build_object('success', false, 'message', 'اسم المستخدم أو كلمة المرور غير صحيحة');
  END IF;

  v_token := encode(gen_random_bytes(32), 'hex');
  v_expires := now() + interval '8 hours';

  INSERT INTO public.admin_dashboard_sessions(admin_user_id, user_name, token_hash, device_info, ip_address, expires_at)
  VALUES (v_user.id, v_user.user_name, encode(digest(v_token, 'sha256'::text), 'hex'), p_device_info, p_ip_address, v_expires);

  UPDATE public.app_security SET last_login = now(), updated_at = COALESCE(updated_at, now()) WHERE id = v_user.id;

  INSERT INTO public.login_attempts(user_name, success, ip_address, device_info)
  VALUES (v_user.user_name, true, p_ip_address, p_device_info);

  INSERT INTO public.admin_activity_logs(user_id, actor_admin_id, action, details, device, ip_address)
  VALUES (
    v_user.id,
    v_user.id,
    'admin_login',
    jsonb_build_object('message', 'تسجيل دخول إلى لوحة الإدارة'),
    p_device_info,
    p_ip_address
  );

  RETURN jsonb_build_object(
    'success', true,
    'token', v_token,
    'expires_at', v_expires,
    'admin', jsonb_build_object(
      'id', v_user.id,
      'user_name', v_user.user_name,
      'full_name', COALESCE(v_user.full_name, v_user.user_name),
      'account_number', v_user.account_number,
      'role', v_user.role
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_logout(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  DELETE FROM public.admin_dashboard_sessions
  WHERE token_hash = encode(digest(p_token, 'sha256'::text), 'hex');
  RETURN jsonb_build_object('success', true);
END;
$$;

-- 4) Read RPCs ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_dashboard_get_overview(p_token text)
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

  WITH latest_sub AS (
    SELECT DISTINCT ON (s.user_id)
      s.*,
      public.admin_dashboard_effective_subscription_status(s.status, s.end_date) AS effective_status
    FROM public.admin_subscriptions s
    ORDER BY s.user_id, s.end_date DESC, s.created_at DESC
  ),
  stats AS (
    SELECT
      (SELECT count(*) FROM public.app_security) AS total_users,
      (SELECT count(*) FROM public.app_security WHERE COALESCE(is_active, true) = true) AS active_users,
      (SELECT count(*) FROM latest_sub WHERE effective_status = 'active') AS active_subscribers,
      (SELECT count(*) FROM latest_sub WHERE billing_cycle = 'monthly' AND effective_status IN ('active', 'ending_soon')) AS monthly_subscriptions,
      (SELECT count(*) FROM latest_sub WHERE billing_cycle = 'yearly' AND effective_status IN ('active', 'ending_soon')) AS yearly_subscriptions,
      (SELECT count(*) FROM latest_sub WHERE effective_status = 'ending_soon') AS ending_soon,
      (SELECT count(*) FROM latest_sub WHERE effective_status = 'expired') AS expired_subscriptions,
      COALESCE((SELECT sum(amount) FROM public.admin_payments WHERE status = 'paid' AND paid_at >= date_trunc('month', now())), 0) AS monthly_revenue,
      COALESCE((SELECT sum(amount) FROM public.admin_payments WHERE status = 'paid'), 0) AS total_revenue
  )
  SELECT jsonb_build_object(
    'stats', (SELECT to_jsonb(stats) FROM stats),
    'subscription_growth', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('month', month_label, 'count', count) ORDER BY month_start)
      FROM (
        SELECT
          date_trunc('month', gs)::date AS month_start,
          to_char(date_trunc('month', gs), 'YYYY-MM') AS month_label,
          (SELECT count(*) FROM public.admin_subscriptions s WHERE date_trunc('month', s.created_at)::date = date_trunc('month', gs)::date) AS count
        FROM generate_series(date_trunc('month', now()) - interval '5 months', date_trunc('month', now()), interval '1 month') gs
      ) g
    ), '[]'::jsonb),
    'billing_breakdown', jsonb_build_object(
      'monthly', (SELECT count(*) FROM latest_sub WHERE billing_cycle = 'monthly' AND effective_status IN ('active', 'ending_soon')),
      'yearly', (SELECT count(*) FROM latest_sub WHERE billing_cycle = 'yearly' AND effective_status IN ('active', 'ending_soon'))
    ),
    'recent_users', COALESCE((
      SELECT jsonb_agg(row_to_json(u))
      FROM (
        SELECT
          a.id, a.user_name, COALESCE(a.full_name, a.user_name) AS full_name, a.account_number,
          a.role, a.is_active, a.created_at, a.last_login,
          ls.plan_name, ls.billing_cycle, ls.start_date, ls.end_date, ls.effective_status AS subscription_status
        FROM public.app_security a
        LEFT JOIN latest_sub ls ON ls.user_id = a.id
        ORDER BY a.created_at DESC NULLS LAST
        LIMIT 8
      ) u
    ), '[]'::jsonb),
    'ending_soon_list', COALESCE((
      SELECT jsonb_agg(row_to_json(e))
      FROM (
        SELECT
          a.id AS user_id, COALESCE(a.full_name, a.user_name) AS full_name, a.user_name, a.account_number,
          ls.plan_name, ls.billing_cycle, ls.end_date, ls.amount, ls.currency,
          (ls.end_date - CURRENT_DATE) AS days_left
        FROM latest_sub ls
        JOIN public.app_security a ON a.id = ls.user_id
        WHERE ls.effective_status = 'ending_soon'
        ORDER BY ls.end_date ASC
        LIMIT 10
      ) e
    ), '[]'::jsonb),
    'recent_activity', COALESCE((
      SELECT jsonb_agg(row_to_json(act))
      FROM (
        SELECT * FROM (
          SELECT
            l.id,
            l.user_id,
            COALESCE(a.full_name, a.user_name) AS full_name,
            a.user_name,
            l.action,
            l.details,
            l.device,
            l.ip_address,
            l.created_at
          FROM public.admin_activity_logs l
          LEFT JOIN public.app_security a ON a.id = l.user_id
          ORDER BY l.created_at DESC
          LIMIT 12
        ) x
      ) act
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_get_users(
  p_token text,
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 300
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

  RETURN jsonb_build_object('users', COALESCE((
    WITH latest_sub AS (
      SELECT DISTINCT ON (s.user_id)
        s.*,
        public.admin_dashboard_effective_subscription_status(s.status, s.end_date) AS effective_status
      FROM public.admin_subscriptions s
      ORDER BY s.user_id, s.end_date DESC, s.created_at DESC
    )
    SELECT jsonb_agg(row_to_json(u))
    FROM (
      SELECT
        a.id, a.user_name, COALESCE(a.full_name, a.user_name) AS full_name, a.account_number,
        a.role, a.is_active, a.created_at, a.updated_at, a.last_login,
        ls.id AS subscription_id, ls.plan_name, ls.billing_cycle, ls.start_date, ls.end_date,
        ls.effective_status AS subscription_status, ls.amount, ls.currency, ls.auto_renew, ls.max_customers,
        (q.quota->>'customer_count')::integer AS customer_count,
        (q.quota->>'customer_limit')::integer AS customer_limit,
        (q.quota->>'free_customer_limit')::integer AS free_customer_limit,
        (q.quota->>'has_active_subscription')::boolean AS has_active_subscription,
        (q.quota->>'can_add_customer')::boolean AS can_add_customer,
        q.quota->>'quota_message' AS quota_message,
        COALESCE((SELECT count(*) FROM public.admin_activity_logs l WHERE l.user_id = a.id), 0) AS admin_activity_count,
        COALESCE((SELECT count(*) FROM public.admin_payments p WHERE p.user_id = a.id AND p.status = 'paid'), 0) AS paid_invoices_count
      FROM public.app_security a
      LEFT JOIN latest_sub ls ON ls.user_id = a.id
      CROSS JOIN LATERAL (SELECT public.admin_dashboard_get_customer_quota_snapshot(a.id) AS quota) q
      WHERE p_search IS NULL OR trim(p_search) = '' OR (
        lower(COALESCE(a.full_name, '')) LIKE '%' || lower(trim(p_search)) || '%'
        OR lower(COALESCE(a.user_name, '')) LIKE '%' || lower(trim(p_search)) || '%'
        OR lower(COALESCE(a.account_number, '')) LIKE '%' || lower(trim(p_search)) || '%'
      )
      ORDER BY a.created_at DESC NULLS LAST
      LIMIT LEAST(GREATEST(COALESCE(p_limit, 300), 1), 500)
    ) u
  ), '[]'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_get_subscriptions(
  p_token text,
  p_search text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 300
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

  RETURN jsonb_build_object('subscriptions', COALESCE((
    SELECT jsonb_agg(row_to_json(sx))
    FROM (
      SELECT
        s.*,
        public.admin_dashboard_effective_subscription_status(s.status, s.end_date) AS effective_status,
        a.user_name,
        COALESCE(a.full_name, a.user_name) AS full_name,
        a.account_number,
        a.role,
        a.is_active
      FROM public.admin_subscriptions s
      JOIN public.app_security a ON a.id = s.user_id
      WHERE (p_search IS NULL OR trim(p_search) = '' OR (
        lower(COALESCE(a.full_name, '')) LIKE '%' || lower(trim(p_search)) || '%'
        OR lower(COALESCE(a.user_name, '')) LIKE '%' || lower(trim(p_search)) || '%'
        OR lower(COALESCE(a.account_number, '')) LIKE '%' || lower(trim(p_search)) || '%'
      ))
      AND (p_status IS NULL OR p_status = 'all' OR public.admin_dashboard_effective_subscription_status(s.status, s.end_date) = p_status)
      ORDER BY s.end_date ASC, s.created_at DESC
      LIMIT LEAST(GREATEST(COALESCE(p_limit, 300), 1), 500)
    ) sx
  ), '[]'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_get_payments(
  p_token text,
  p_search text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 300
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

  RETURN jsonb_build_object('payments', COALESCE((
    SELECT jsonb_agg(row_to_json(px))
    FROM (
      SELECT
        p.*,
        a.user_name,
        COALESCE(a.full_name, a.user_name) AS full_name,
        a.account_number,
        s.plan_name,
        s.billing_cycle
      FROM public.admin_payments p
      JOIN public.app_security a ON a.id = p.user_id
      LEFT JOIN public.admin_subscriptions s ON s.id = p.subscription_id
      WHERE (p_search IS NULL OR trim(p_search) = '' OR (
        lower(COALESCE(a.full_name, '')) LIKE '%' || lower(trim(p_search)) || '%'
        OR lower(COALESCE(a.user_name, '')) LIKE '%' || lower(trim(p_search)) || '%'
        OR lower(COALESCE(a.account_number, '')) LIKE '%' || lower(trim(p_search)) || '%'
        OR lower(COALESCE(p.invoice_no, '')) LIKE '%' || lower(trim(p_search)) || '%'
      ))
      AND (p_status IS NULL OR p_status = 'all' OR p.status = p_status)
      ORDER BY p.paid_at DESC
      LIMIT LEAST(GREATEST(COALESCE(p_limit, 300), 1), 500)
    ) px
  ), '[]'::jsonb));
END;
$$;

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
              'movement_type', m.movement_type,
              'amount', m.amount,
              'currency', m.currency,
              'notes', m.notes
            ) AS details,
            NULL::text AS device,
            NULL::text AS ip_address,
            m.created_at
          FROM public.account_movements m
          WHERE m.created_by_user_id = p_user_id OR m.source_user_id = p_user_id
        ) q
        ORDER BY created_at DESC
        LIMIT 150
      ) ax
    ), '[]'::jsonb)
  );
END;
$$;

-- 5) Write RPCs --------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_dashboard_save_subscription(
  p_token text,
  p_subscription_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_plan_name text DEFAULT 'الخطة الأساسية',
  p_billing_cycle text DEFAULT 'monthly',
  p_start_date date DEFAULT CURRENT_DATE,
  p_end_date date DEFAULT NULL,
  p_amount numeric DEFAULT 0,
  p_currency text DEFAULT 'USD',
  p_status text DEFAULT 'active',
  p_auto_renew boolean DEFAULT false,
  p_max_customers integer DEFAULT 999999,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_admin_id uuid;
  v_sub public.admin_subscriptions%ROWTYPE;
BEGIN
  v_admin_id := public.admin_dashboard_require_session(p_token);

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'USER_REQUIRED';
  END IF;

  IF p_end_date IS NULL THEN
    p_end_date := CASE WHEN p_billing_cycle = 'yearly' THEN p_start_date + interval '1 year' ELSE p_start_date + interval '1 month' END;
  END IF;

  IF p_subscription_id IS NULL THEN
    INSERT INTO public.admin_subscriptions(user_id, plan_name, billing_cycle, start_date, end_date, status, amount, currency, auto_renew, max_customers, notes)
    VALUES (p_user_id, p_plan_name, p_billing_cycle, p_start_date, p_end_date, p_status, COALESCE(p_amount, 0), COALESCE(p_currency, 'USD'), COALESCE(p_auto_renew, false), GREATEST(COALESCE(p_max_customers, 999999), 5), p_notes)
    RETURNING * INTO v_sub;

    INSERT INTO public.admin_activity_logs(user_id, actor_admin_id, action, details)
    VALUES (p_user_id, v_admin_id, 'subscription_created', jsonb_build_object('subscription_id', v_sub.id, 'plan_name', v_sub.plan_name, 'billing_cycle', v_sub.billing_cycle, 'end_date', v_sub.end_date, 'max_customers', v_sub.max_customers));
  ELSE
    UPDATE public.admin_subscriptions
    SET plan_name = p_plan_name,
        billing_cycle = p_billing_cycle,
        start_date = p_start_date,
        end_date = p_end_date,
        status = p_status,
        amount = COALESCE(p_amount, 0),
        currency = COALESCE(p_currency, 'USD'),
        auto_renew = COALESCE(p_auto_renew, false),
        max_customers = GREATEST(COALESCE(p_max_customers, 999999), 5),
        notes = p_notes
    WHERE id = p_subscription_id
    RETURNING * INTO v_sub;

    INSERT INTO public.admin_activity_logs(user_id, actor_admin_id, action, details)
    VALUES (p_user_id, v_admin_id, 'subscription_updated', jsonb_build_object('subscription_id', v_sub.id, 'plan_name', v_sub.plan_name, 'billing_cycle', v_sub.billing_cycle, 'end_date', v_sub.end_date, 'max_customers', v_sub.max_customers));
  END IF;

  RETURN jsonb_build_object('success', true, 'subscription', to_jsonb(v_sub));
END;
$$;


CREATE OR REPLACE FUNCTION public.admin_dashboard_cancel_subscription(
  p_token text,
  p_user_id uuid,
  p_subscription_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_admin_id uuid;
  v_target_subscription_id uuid;
  v_sub public.admin_subscriptions%ROWTYPE;
BEGIN
  v_admin_id := public.admin_dashboard_require_session(p_token);

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'USER_REQUIRED';
  END IF;

  IF p_subscription_id IS NOT NULL THEN
    v_target_subscription_id := p_subscription_id;
  ELSE
    SELECT s.id
    INTO v_target_subscription_id
    FROM public.admin_subscriptions s
    WHERE s.user_id = p_user_id
      AND public.admin_dashboard_effective_subscription_status(s.status, s.end_date) IN ('active', 'ending_soon', 'trial')
    ORDER BY s.end_date DESC, s.created_at DESC
    LIMIT 1;
  END IF;

  IF v_target_subscription_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'لا يوجد اشتراك نشط لإلغائه');
  END IF;

  UPDATE public.admin_subscriptions
  SET status = 'canceled',
      auto_renew = false,
      notes = NULLIF(trim(COALESCE(notes, '') || E'
' || COALESCE(p_reason, 'تم إلغاء الاشتراك يدويًا من لوحة الإدارة')), '')
  WHERE id = v_target_subscription_id
    AND user_id = p_user_id
  RETURNING * INTO v_sub;

  IF v_sub.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'تعذر العثور على الاشتراك المطلوب');
  END IF;

  INSERT INTO public.admin_activity_logs(user_id, actor_admin_id, action, details)
  VALUES (
    p_user_id,
    v_admin_id,
    'subscription_canceled',
    jsonb_build_object('subscription_id', v_sub.id, 'plan_name', v_sub.plan_name, 'reason', COALESCE(p_reason, 'إلغاء يدوي'))
  );

  RETURN jsonb_build_object('success', true, 'subscription', to_jsonb(v_sub));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_save_payment(
  p_token text,
  p_user_id uuid,
  p_subscription_id uuid DEFAULT NULL,
  p_amount numeric DEFAULT 0,
  p_currency text DEFAULT 'USD',
  p_status text DEFAULT 'paid',
  p_paid_at timestamptz DEFAULT now(),
  p_invoice_no text DEFAULT NULL,
  p_payment_method text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_admin_id uuid;
  v_payment public.admin_payments%ROWTYPE;
BEGIN
  v_admin_id := public.admin_dashboard_require_session(p_token);

  INSERT INTO public.admin_payments(user_id, subscription_id, amount, currency, status, paid_at, invoice_no, payment_method, notes)
  VALUES (p_user_id, p_subscription_id, COALESCE(p_amount, 0), COALESCE(p_currency, 'USD'), COALESCE(p_status, 'paid'), COALESCE(p_paid_at, now()), p_invoice_no, p_payment_method, p_notes)
  RETURNING * INTO v_payment;

  INSERT INTO public.admin_activity_logs(user_id, actor_admin_id, action, details)
  VALUES (p_user_id, v_admin_id, 'payment_created', jsonb_build_object('payment_id', v_payment.id, 'amount', v_payment.amount, 'currency', v_payment.currency, 'status', v_payment.status, 'invoice_no', v_payment.invoice_no));

  RETURN jsonb_build_object('success', true, 'payment', to_jsonb(v_payment));
END;
$$;

-- 6) RLS and grants ----------------------------------------------------------
ALTER TABLE public.admin_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_activity_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_dashboard_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin dashboard RPC only - subscriptions" ON public.admin_subscriptions;
DROP POLICY IF EXISTS "Admin dashboard RPC only - payments" ON public.admin_payments;
DROP POLICY IF EXISTS "Admin dashboard RPC only - activity" ON public.admin_activity_logs;
DROP POLICY IF EXISTS "Admin dashboard RPC only - sessions" ON public.admin_dashboard_sessions;

-- No direct table access. Dashboard reads/writes through SECURITY DEFINER RPCs above.
CREATE POLICY "Admin dashboard RPC only - subscriptions" ON public.admin_subscriptions FOR ALL USING (false) WITH CHECK (false);
CREATE POLICY "Admin dashboard RPC only - payments" ON public.admin_payments FOR ALL USING (false) WITH CHECK (false);
CREATE POLICY "Admin dashboard RPC only - activity" ON public.admin_activity_logs FOR ALL USING (false) WITH CHECK (false);
CREATE POLICY "Admin dashboard RPC only - sessions" ON public.admin_dashboard_sessions FOR ALL USING (false) WITH CHECK (false);

GRANT EXECUTE ON FUNCTION public.admin_dashboard_login(text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_logout(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_overview(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_users(text, text, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_subscriptions(text, text, text, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_payments(text, text, text, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_user_detail(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_customer_quota_snapshot(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_user_quota(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_save_subscription(text, uuid, uuid, text, text, date, date, numeric, text, text, boolean, integer, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_cancel_subscription(text, uuid, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_save_payment(text, uuid, uuid, numeric, text, text, timestamptz, text, text, text) TO anon, authenticated;
