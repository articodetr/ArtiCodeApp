/*
  Subscription-gated print branding
  - Active/trial/ending-soon subscription: use user's own receipt/letterhead branding.
  - Expired/canceled/no subscription: automatically use the bundled ArtiCode header in printed PDFs.
*/

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION public.app_get_print_branding_status(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_subscription_id uuid;
  v_plan_name text;
  v_end_date date;
  v_effective_status text := 'none';
  v_can_use_custom_branding boolean := false;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'has_active_subscription', false,
      'can_use_custom_branding', false,
      'force_articode_branding', true,
      'subscription_status', 'none',
      'subscription_id', NULL,
      'plan_name', NULL,
      'end_date', NULL,
      'branding_message', 'لا يوجد مستخدم محدد، سيتم استخدام ترويسة ArtiCode'
    );
  END IF;

  SELECT
    s.id,
    s.plan_name,
    s.end_date,
    public.admin_dashboard_effective_subscription_status(s.status, s.end_date)
  INTO
    v_subscription_id,
    v_plan_name,
    v_end_date,
    v_effective_status
  FROM public.admin_subscriptions s
  WHERE s.user_id = p_user_id
  ORDER BY
    CASE
      WHEN public.admin_dashboard_effective_subscription_status(s.status, s.end_date) IN ('active', 'ending_soon', 'trial') THEN 0
      ELSE 1
    END,
    s.end_date DESC NULLS LAST,
    s.created_at DESC NULLS LAST
  LIMIT 1;

  v_effective_status := COALESCE(v_effective_status, 'none');
  v_can_use_custom_branding := v_effective_status IN ('active', 'ending_soon', 'trial');

  RETURN jsonb_build_object(
    'has_active_subscription', v_can_use_custom_branding,
    'can_use_custom_branding', v_can_use_custom_branding,
    'force_articode_branding', NOT v_can_use_custom_branding,
    'subscription_status', v_effective_status,
    'subscription_id', v_subscription_id,
    'plan_name', v_plan_name,
    'end_date', v_end_date,
    'branding_message', CASE
      WHEN v_can_use_custom_branding THEN 'الاشتراك فعال، يمكن استخدام ترويسة العميل'
      WHEN v_effective_status = 'expired' THEN 'الاشتراك منتهي، سيتم استخدام ترويسة ArtiCode في الطباعة'
      WHEN v_effective_status = 'canceled' THEN 'الاشتراك ملغي، سيتم استخدام ترويسة ArtiCode في الطباعة'
      ELSE 'لا يوجد اشتراك فعال، سيتم استخدام ترويسة ArtiCode في الطباعة'
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.app_get_print_branding_status(uuid) TO anon, authenticated;
