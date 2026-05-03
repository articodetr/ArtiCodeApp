/*
  Subscription quota and manual billing hardening
  - Adds customer limits per subscription (max_customers)
  - Adds admin RPCs used by the dashboard: quota, cancel subscription, save subscription with max_customers
  - Adds application RPC for adding local customers with quota enforcement
  - Updates linked-customer creation to respect the owner user's quota
*/

SET search_path = public, extensions;

ALTER TABLE public.admin_subscriptions
  ADD COLUMN IF NOT EXISTS max_customers integer NOT NULL DEFAULT 999999;

CREATE INDEX IF NOT EXISTS idx_admin_subscriptions_max_customers
  ON public.admin_subscriptions(max_customers);

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

DROP FUNCTION IF EXISTS public.admin_dashboard_save_subscription(text, uuid, uuid, text, text, date, date, numeric, text, text, boolean, text);

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

  IF v_sub.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'تعذر حفظ الاشتراك');
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
      notes = NULLIF(trim(COALESCE(notes, '') || E'\n' || COALESCE(p_reason, 'تم إلغاء الاشتراك يدويًا من لوحة الإدارة')), '')
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

CREATE OR REPLACE FUNCTION public.create_regular_customer_with_quota_check(
  p_user_id uuid,
  p_name text,
  p_phone text,
  p_email text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_account_number text DEFAULT NULL
)
RETURNS TABLE (
  success boolean,
  customer_id uuid,
  message text,
  customer_count integer,
  customer_limit integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_customer_id uuid;
  v_quota jsonb;
  v_customer_count integer;
  v_customer_limit integer;
  v_can_add boolean;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, 'يجب تسجيل الدخول أولاً'::text, 0::integer, 5::integer;
    RETURN;
  END IF;

  IF NULLIF(trim(COALESCE(p_name, '')), '') IS NULL OR NULLIF(trim(COALESCE(p_phone, '')), '') IS NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, 'الاسم ورقم الهاتف مطلوبان'::text, 0::integer, 5::integer;
    RETURN;
  END IF;

  v_quota := public.admin_dashboard_get_customer_quota_snapshot(p_user_id);
  v_customer_count := COALESCE((v_quota->>'customer_count')::integer, 0);
  v_customer_limit := COALESCE((v_quota->>'customer_limit')::integer, 5);
  v_can_add := COALESCE((v_quota->>'can_add_customer')::boolean, false);

  IF NOT v_can_add THEN
    RETURN QUERY SELECT false, NULL::uuid, COALESCE(v_quota->>'quota_message', 'وصلت إلى الحد المسموح من العملاء')::text, v_customer_count, v_customer_limit;
    RETURN;
  END IF;

  INSERT INTO public.customers (
    user_id,
    name,
    phone,
    email,
    address,
    notes,
    account_number
  ) VALUES (
    p_user_id,
    trim(p_name),
    trim(p_phone),
    NULLIF(trim(COALESCE(p_email, '')), ''),
    NULLIF(trim(COALESCE(p_address, '')), ''),
    NULLIF(trim(COALESCE(p_notes, '')), ''),
    NULLIF(trim(COALESCE(p_account_number, '')), '')
  ) RETURNING id INTO v_customer_id;

  RETURN QUERY SELECT true, v_customer_id, 'تم إضافة العميل بنجاح'::text, v_customer_count + 1, v_customer_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_linked_customer(
  p_owner_user_id uuid,
  p_linked_user_id uuid,
  p_customer_name text
)
RETURNS TABLE (
  success boolean,
  customer_id uuid,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_customer_id uuid;
  v_reciprocal_customer_id uuid;
  v_linked_user_name text;
  v_owner_user_name text;
  v_linked_account_number text;
  v_owner_account_number text;
  v_existing_link uuid;
  v_existing_reciprocal_link uuid;
  v_quota jsonb;
BEGIN
  IF p_owner_user_id = p_linked_user_id THEN
    RETURN QUERY SELECT false, NULL::uuid, 'لا يمكن ربط نفسك كعميل'::text;
    RETURN;
  END IF;

  v_quota := public.admin_dashboard_get_customer_quota_snapshot(p_owner_user_id);
  IF COALESCE((v_quota->>'can_add_customer')::boolean, false) = false THEN
    RETURN QUERY SELECT false, NULL::uuid, COALESCE(v_quota->>'quota_message', 'وصلت إلى الحد المسموح من العملاء')::text;
    RETURN;
  END IF;

  SELECT id INTO v_existing_link
  FROM public.customers
  WHERE user_id = p_owner_user_id
    AND linked_user_id = p_linked_user_id;

  IF v_existing_link IS NOT NULL THEN
    RETURN QUERY SELECT false, v_existing_link, 'هذا المستخدم مربوط بالفعل'::text;
    RETURN;
  END IF;

  SELECT full_name, account_number INTO v_linked_user_name, v_linked_account_number
  FROM public.app_security
  WHERE id = p_linked_user_id;

  IF v_linked_user_name IS NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, 'المستخدم المحدد غير موجود'::text;
    RETURN;
  END IF;

  SELECT full_name, account_number INTO v_owner_user_name, v_owner_account_number
  FROM public.app_security
  WHERE id = p_owner_user_id;

  INSERT INTO public.customers (
    user_id,
    linked_user_id,
    name,
    phone,
    account_number,
    notes
  ) VALUES (
    p_owner_user_id,
    p_linked_user_id,
    COALESCE(NULLIF(trim(p_customer_name), ''), v_linked_user_name),
    'LINKED_USER_' || v_linked_account_number,
    v_linked_account_number,
    'عميل مرتبط بمستخدم مسجل - رقم الحساب الحقيقي: ' || v_linked_account_number
  ) RETURNING id INTO v_customer_id;

  INSERT INTO public.user_customer_links (
    owner_user_id,
    linked_user_id,
    customer_id,
    status,
    notes
  ) VALUES (
    p_owner_user_id,
    p_linked_user_id,
    v_customer_id,
    'active',
    'ربط تلقائي عند إضافة العميل'
  );

  SELECT id INTO v_existing_reciprocal_link
  FROM public.customers
  WHERE user_id = p_linked_user_id
    AND linked_user_id = p_owner_user_id;

  IF v_existing_reciprocal_link IS NULL THEN
    INSERT INTO public.customers (
      user_id,
      linked_user_id,
      name,
      phone,
      account_number,
      notes
    ) VALUES (
      p_linked_user_id,
      p_owner_user_id,
      v_owner_user_name,
      'LINKED_USER_' || v_owner_account_number,
      v_owner_account_number,
      'تم إنشاؤه تلقائياً كحساب متبادل - رقم الحساب الحقيقي: ' || v_owner_account_number
    ) RETURNING id INTO v_reciprocal_customer_id;

    INSERT INTO public.user_customer_links (
      owner_user_id,
      linked_user_id,
      customer_id,
      status,
      notes
    ) VALUES (
      p_linked_user_id,
      p_owner_user_id,
      v_reciprocal_customer_id,
      'active',
      'ربط متبادل تلقائي'
    );

    PERFORM public.create_notification(
      NULL,
      p_linked_user_id,
      'customer_added',
      'تم إضافتك كحساب مرتبط من قبل ' || v_owner_user_name || ' (رقم الحساب: ' || v_owner_account_number || ')'
    );
  END IF;

  RETURN QUERY SELECT true, v_customer_id, 'تم ربط المستخدم كعميل بنجاح - رقم الحساب: ' || v_linked_account_number::text;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_customer_quota_snapshot(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_user_quota(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_get_users(text, text, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_save_subscription(text, uuid, uuid, text, text, date, date, numeric, text, text, boolean, integer, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_cancel_subscription(text, uuid, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_regular_customer_with_quota_check(uuid, text, text, text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_linked_customer(uuid, uuid, text) TO anon, authenticated;
