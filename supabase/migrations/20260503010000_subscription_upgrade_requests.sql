-- ArtiCodeApp: تسجيل طلبات تفعيل الاشتراك من التطبيق وعرضها في الداشبورد
-- شغّل هذا الملف مرة واحدة من Supabase SQL Editor بعد ملفات الاشتراكات السابقة.

CREATE TABLE IF NOT EXISTS public.subscription_upgrade_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.app_security(id) ON DELETE SET NULL,
  full_name text,
  user_name text,
  account_number text,
  customer_count integer,
  customer_limit integer,
  whatsapp_number text,
  request_message text,
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'contacted', 'activated', 'closed')),
  source text NOT NULL DEFAULT 'app_whatsapp',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscription_upgrade_requests_status_created
  ON public.subscription_upgrade_requests(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_subscription_upgrade_requests_user_created
  ON public.subscription_upgrade_requests(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.app_create_subscription_request(
  p_user_id uuid DEFAULT NULL,
  p_user_name text DEFAULT NULL,
  p_full_name text DEFAULT NULL,
  p_account_number text DEFAULT NULL,
  p_customer_count integer DEFAULT NULL,
  p_customer_limit integer DEFAULT NULL,
  p_whatsapp_number text DEFAULT NULL,
  p_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_request public.subscription_upgrade_requests%ROWTYPE;
  v_user public.app_security%ROWTYPE;
BEGIN
  IF p_user_id IS NOT NULL THEN
    SELECT * INTO v_user
    FROM public.app_security
    WHERE id = p_user_id
    LIMIT 1;
  END IF;

  INSERT INTO public.subscription_upgrade_requests(
    user_id,
    full_name,
    user_name,
    account_number,
    customer_count,
    customer_limit,
    whatsapp_number,
    request_message,
    status,
    source
  )
  VALUES (
    p_user_id,
    COALESCE(NULLIF(p_full_name, ''), v_user.full_name),
    COALESCE(NULLIF(p_user_name, ''), v_user.user_name),
    COALESCE(NULLIF(p_account_number, ''), v_user.account_number),
    p_customer_count,
    p_customer_limit,
    NULLIF(p_whatsapp_number, ''),
    NULLIF(p_message, ''),
    'new',
    'app_whatsapp'
  )
  RETURNING * INTO v_request;

  -- نسجلها أيضًا في سجل نشاط الإدارة حتى تظهر في آخر حركة.
  BEGIN
    INSERT INTO public.admin_activity_logs(user_id, action, details)
    VALUES (
      p_user_id,
      'subscription_upgrade_requested',
      jsonb_build_object(
        'request_id', v_request.id,
        'user_name', v_request.user_name,
        'full_name', v_request.full_name,
        'account_number', v_request.account_number,
        'customer_count', v_request.customer_count,
        'customer_limit', v_request.customer_limit,
        'whatsapp_number', v_request.whatsapp_number,
        'source', v_request.source
      )
    );
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;

  RETURN jsonb_build_object('success', true, 'request', to_jsonb(v_request));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_get_subscription_requests(
  p_token text,
  p_status text DEFAULT 'all',
  p_limit integer DEFAULT 300
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_admin_id uuid;
  v_requests jsonb;
BEGIN
  v_admin_id := public.admin_dashboard_require_session(p_token);

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_requests
  FROM (
    SELECT
      r.id,
      r.user_id,
      COALESCE(a.full_name, r.full_name) AS full_name,
      COALESCE(a.user_name, r.user_name) AS user_name,
      COALESCE(a.account_number, r.account_number) AS account_number,
      r.customer_count,
      r.customer_limit,
      r.whatsapp_number,
      r.request_message,
      r.status,
      r.source,
      r.created_at,
      r.updated_at,
      public.admin_dashboard_effective_subscription_status(s.status, s.end_date) AS subscription_status,
      s.end_date
    FROM public.subscription_upgrade_requests r
    LEFT JOIN public.app_security a ON a.id = r.user_id
    LEFT JOIN LATERAL (
      SELECT status, end_date
      FROM public.admin_subscriptions sub
      WHERE sub.user_id = r.user_id
      ORDER BY sub.end_date DESC, sub.created_at DESC
      LIMIT 1
    ) s ON true
    WHERE p_status = 'all' OR r.status = p_status
    ORDER BY r.created_at DESC
    LIMIT LEAST(COALESCE(p_limit, 300), 1000)
  ) t;

  RETURN jsonb_build_object('requests', v_requests);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_update_subscription_request_status(
  p_token text,
  p_request_id uuid,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_admin_id uuid;
  v_request public.subscription_upgrade_requests%ROWTYPE;
BEGIN
  v_admin_id := public.admin_dashboard_require_session(p_token);

  IF p_status NOT IN ('new', 'contacted', 'activated', 'closed') THEN
    RAISE EXCEPTION 'Invalid subscription request status: %', p_status;
  END IF;

  UPDATE public.subscription_upgrade_requests
  SET status = p_status,
      updated_at = now()
  WHERE id = p_request_id
  RETURNING * INTO v_request;

  IF v_request.id IS NULL THEN
    RAISE EXCEPTION 'Subscription request not found';
  END IF;

  INSERT INTO public.admin_activity_logs(user_id, actor_admin_id, action, details)
  VALUES (
    v_request.user_id,
    v_admin_id,
    'subscription_request_status_updated',
    jsonb_build_object('request_id', v_request.id, 'status', p_status)
  );

  RETURN jsonb_build_object('success', true, 'request', to_jsonb(v_request));
END;
$$;

GRANT EXECUTE ON FUNCTION public.app_create_subscription_request(uuid, text, text, text, integer, integer, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_subscription_requests(text, text, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_update_subscription_request_status(text, uuid, text) TO anon, authenticated;
