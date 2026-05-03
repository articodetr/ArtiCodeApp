import { supabase } from '../lib/supabase';
import type {
  AdminSession,
  OverviewData,
  UserDetailData,
  UserRow,
  SubscriptionRow,
  PaymentRow,
  TransferMovementsData,
  SavePaymentInput,
  SaveSubscriptionInput,
} from '../types';

const SESSION_KEY = 'articode_admin_session';

function ensureData<T>(data: T | null, error: unknown, fallbackMessage: string): T {
  if (error) {
    const message = typeof error === 'object' && error && 'message' in error ? String((error as { message?: string }).message) : fallbackMessage;
    throw new Error(message);
  }
  if (data === null || data === undefined) throw new Error(fallbackMessage);
  return data;
}

export function getStoredSession(): AdminSession | null {
  try {
    const raw = localStorage.getItem(SESSION_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as AdminSession;
    if (!parsed?.token || !parsed?.admin?.id) return null;
    if (parsed.expires_at && new Date(parsed.expires_at).getTime() < Date.now()) {
      localStorage.removeItem(SESSION_KEY);
      return null;
    }
    return parsed;
  } catch {
    localStorage.removeItem(SESSION_KEY);
    return null;
  }
}

export function storeSession(session: AdminSession) {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session));
}

export function clearSession() {
  localStorage.removeItem(SESSION_KEY);
}

export async function login(userName: string, pin: string): Promise<AdminSession> {
  const { data, error } = await supabase.rpc('admin_dashboard_login', {
    p_user_name: userName,
    p_pin: pin,
    p_device_info: navigator.userAgent,
    p_ip_address: null,
  });

  const result = ensureData<any>(data, error, 'فشل تسجيل الدخول');
  if (!result.success) {
    throw new Error(result.message || 'فشل تسجيل الدخول');
  }

  const session: AdminSession = {
    token: result.token,
    expires_at: result.expires_at,
    admin: result.admin,
  };
  storeSession(session);
  return session;
}

export async function logout(token: string) {
  try {
    await supabase.rpc('admin_dashboard_logout', { p_token: token });
  } finally {
    clearSession();
  }
}

export async function getOverview(token: string): Promise<OverviewData> {
  const { data, error } = await supabase.rpc('admin_dashboard_get_overview', { p_token: token });
  const result = ensureData<any>(data, error, 'تعذر جلب بيانات لوحة التحكم');
  return {
    stats: result.stats || {},
    subscription_growth: result.subscription_growth || [],
    billing_breakdown: result.billing_breakdown || { monthly: 0, yearly: 0 },
    recent_users: result.recent_users || [],
    ending_soon_list: result.ending_soon_list || [],
    recent_activity: result.recent_activity || [],
  } as OverviewData;
}

export async function getUsers(token: string, search = ''): Promise<UserRow[]> {
  const { data, error } = await supabase.rpc('admin_dashboard_get_users', {
    p_token: token,
    p_search: search || null,
    p_limit: 300,
  });
  const result = ensureData<any>(data, error, 'تعذر جلب المستخدمين');
  return result.users || [];
}

export async function getSubscriptions(token: string, search = '', status = 'all'): Promise<SubscriptionRow[]> {
  const { data, error } = await supabase.rpc('admin_dashboard_get_subscriptions', {
    p_token: token,
    p_search: search || null,
    p_status: status,
    p_limit: 300,
  });
  const result = ensureData<any>(data, error, 'تعذر جلب الاشتراكات');
  return result.subscriptions || [];
}

export async function getPayments(token: string, search = '', status = 'all'): Promise<PaymentRow[]> {
  const { data, error } = await supabase.rpc('admin_dashboard_get_payments', {
    p_token: token,
    p_search: search || null,
    p_status: status,
    p_limit: 300,
  });
  const result = ensureData<any>(data, error, 'تعذر جلب المدفوعات');
  return result.payments || [];
}


export async function getTransfers(token: string, search = '', direction = 'all', status = 'all'): Promise<TransferMovementsData> {
  const { data, error } = await supabase.rpc('admin_dashboard_get_transfer_movements', {
    p_token: token,
    p_search: search || null,
    p_direction: direction,
    p_status: status,
    p_limit: 500,
  });
  const result = ensureData<any>(data, error, 'تعذر جلب حركة الحوالات');
  return {
    stats: result.stats || {
      total_movements: 0,
      incoming_movements: 0,
      outgoing_movements: 0,
      customer_to_customer: 0,
      shop_to_customer: 0,
      customer_to_shop: 0,
      pending_approval: 0,
      approved_movements: 0,
      rejected_movements: 0,
      total_amount_by_currency: [],
    },
    movements: result.movements || [],
    user_summary: result.user_summary || [],
  } as TransferMovementsData;
}


export async function getUserQuota(token: string, userId: string) {
  const { data, error } = await supabase.rpc('admin_dashboard_get_user_quota', {
    p_token: token,
    p_user_id: userId,
  });
  const result = ensureData<any>(data, error, 'تعذر جلب حد العملاء للمستخدم');
  return result || {};
}

export async function getUserDetail(token: string, userId: string): Promise<UserDetailData> {
  const { data, error } = await supabase.rpc('admin_dashboard_get_user_detail', {
    p_token: token,
    p_user_id: userId,
  });
  const result = ensureData<any>(data, error, 'تعذر جلب تفاصيل المستخدم');
  let quota = {} as Record<string, unknown>;
  try {
    quota = result.user?.id ? await getUserQuota(token, result.user.id) : {};
  } catch {
    quota = {};
  }
  return {
    user: result.user ? { ...result.user, ...quota } : null,
    subscriptions: result.subscriptions || [],
    payments: result.payments || [],
    activity: result.activity || [],
    transfers: result.transfers || [],
  };
}

export async function saveSubscription(token: string, input: SaveSubscriptionInput) {
  const { data, error } = await supabase.rpc('admin_dashboard_save_subscription', {
    p_token: token,
    p_subscription_id: input.subscriptionId || null,
    p_user_id: input.userId,
    p_plan_name: input.planName,
    p_billing_cycle: input.billingCycle,
    p_start_date: input.startDate,
    p_end_date: input.endDate,
    p_amount: input.amount,
    p_currency: input.currency,
    p_status: input.status,
    p_auto_renew: input.autoRenew,
    p_max_customers: input.maxCustomers ?? 999999,
    p_notes: input.notes || null,
  });
  const result = ensureData<any>(data, error, 'تعذر حفظ الاشتراك');
  if (!result.success) throw new Error(result.message || 'تعذر حفظ الاشتراك');
  return result.subscription;
}


export async function cancelSubscription(token: string, userId: string, subscriptionId?: string | null, reason?: string) {
  const { data, error } = await supabase.rpc('admin_dashboard_cancel_subscription', {
    p_token: token,
    p_user_id: userId,
    p_subscription_id: subscriptionId || null,
    p_reason: reason || 'تم إلغاء الاشتراك يدويًا من لوحة الإدارة',
  });
  const result = ensureData<any>(data, error, 'تعذر إلغاء الاشتراك');
  if (!result.success) throw new Error(result.message || 'تعذر إلغاء الاشتراك');
  return result.subscription;
}

export async function savePayment(token: string, input: SavePaymentInput) {
  const { data, error } = await supabase.rpc('admin_dashboard_save_payment', {
    p_token: token,
    p_user_id: input.userId,
    p_subscription_id: input.subscriptionId || null,
    p_amount: input.amount,
    p_currency: input.currency,
    p_status: input.status,
    p_paid_at: input.paidAt,
    p_invoice_no: input.invoiceNo || null,
    p_payment_method: input.paymentMethod || null,
    p_notes: input.notes || null,
  });
  const result = ensureData<any>(data, error, 'تعذر تسجيل الدفعة');
  if (!result.success) throw new Error(result.message || 'تعذر تسجيل الدفعة');
  return result.payment;
}
