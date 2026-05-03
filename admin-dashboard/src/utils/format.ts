export function formatNumber(value: number | null | undefined) {
  return new Intl.NumberFormat('en-US').format(Number(value || 0));
}

export function formatMoney(value: number | null | undefined, currency = 'USD') {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency,
    maximumFractionDigits: 2,
  }).format(Number(value || 0));
}

export function formatDate(value?: string | null) {
  if (!value) return '—';
  try {
    return new Intl.DateTimeFormat('ar', { year: 'numeric', month: 'short', day: 'numeric' }).format(new Date(value));
  } catch {
    return value;
  }
}

export function formatDateTime(value?: string | null) {
  if (!value) return '—';
  try {
    return new Intl.DateTimeFormat('ar', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    }).format(new Date(value));
  } catch {
    return value;
  }
}

export function statusLabel(status?: string | null) {
  const map: Record<string, string> = {
    active: 'نشط',
    ending_soon: 'قريب الانتهاء',
    expired: 'منتهي',
    canceled: 'ملغي',
    trial: 'تجريبي',
    paid: 'مدفوع',
    pending: 'معلق',
    failed: 'فشل',
    refunded: 'مسترجع',
  };
  return status ? map[status] || status : 'بدون اشتراك';
}

export function actionLabel(action?: string | null) {
  const map: Record<string, string> = {
    admin_login: 'تسجيل دخول للوحة الإدارة',
    subscription_created: 'إنشاء اشتراك',
    subscription_updated: 'تحديث اشتراك',
    payment_created: 'تسجيل دفعة',
    login_success: 'تسجيل دخول ناجح',
    login_failed: 'محاولة دخول فاشلة',
    account_movement_incoming: 'حركة حساب له',
    account_movement_outgoing: 'حركة حساب عليه',
  };
  return action ? map[action] || action : 'نشاط';
}

export function daysLeft(endDate?: string | null) {
  if (!endDate) return null;
  const end = new Date(endDate + 'T00:00:00');
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return Math.ceil((end.getTime() - today.getTime()) / (1000 * 60 * 60 * 24));
}
