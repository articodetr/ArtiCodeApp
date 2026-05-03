import { useCallback, useEffect, useMemo, useState } from 'react';
import type { FormEvent, ReactNode } from 'react';
import type {
  ActivityRow,
  AdminSession,
  OverviewData,
  PaymentRow,
  SavePaymentInput,
  SaveSubscriptionInput,
  SubscriptionRow,
  TransferMovementsData,
  TransferMovementRow,
  UserDetailData,
  UserRow,
} from './types';
import {
  actionLabel,
  daysLeft,
  formatDate,
  formatDateTime,
  formatMoney,
  formatNumber,
  statusLabel,
} from './utils/format';
import * as adminService from './services/adminService';

type PageKey = 'overview' | 'users' | 'subscriptions' | 'payments' | 'transfers' | 'activity' | 'user_detail';

const emptyTransferData: TransferMovementsData = {
  stats: {
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
  movements: [],
  user_summary: [],
};

const emptyOverview: OverviewData = {
  stats: {
    total_users: 0,
    active_users: 0,
    active_subscribers: 0,
    monthly_subscriptions: 0,
    yearly_subscriptions: 0,
    ending_soon: 0,
    expired_subscriptions: 0,
    monthly_revenue: 0,
    total_revenue: 0,
  },
  subscription_growth: [],
  billing_breakdown: { monthly: 0, yearly: 0 },
  recent_users: [],
  ending_soon_list: [],
  recent_activity: [],
};

function today() {
  return new Date().toISOString().slice(0, 10);
}

function addMonths(dateString: string, months: number) {
  const date = new Date(dateString + 'T00:00:00');
  date.setMonth(date.getMonth() + months);
  return date.toISOString().slice(0, 10);
}

function badgeClass(status?: string | null) {
  if (status === 'active' || status === 'paid') return 'badge badge-green';
  if (status === 'ending_soon' || status === 'pending' || status === 'trial') return 'badge badge-orange';
  if (status === 'expired' || status === 'failed') return 'badge badge-red';
  if (status === 'canceled' || status === 'refunded') return 'badge badge-gray';
  return 'badge badge-blue';
}

function billingLabel(cycle?: string | null) {
  if (cycle === 'monthly') return 'شهري';
  if (cycle === 'yearly') return 'سنوي';
  return '—';
}

function movementLabel(type?: string | null) {
  if (type === 'incoming') return 'له';
  if (type === 'outgoing') return 'عليه';
  return '—';
}

function directionLabel(direction?: string | null) {
  if (direction === 'customer_to_customer') return 'عميل ← عميل';
  if (direction === 'shop_to_customer') return 'المحل ← عميل';
  if (direction === 'customer_to_shop') return 'عميل ← المحل';
  return 'حركة حساب';
}

function approvalLabel(status?: string | null, pending?: boolean | null) {
  if (status === 'approved') return 'معتمدة';
  if (status === 'rejected') return 'مرفوضة';
  if (status === 'pending' || pending) return 'معلقة';
  return 'معتمدة';
}

function approvalBadgeClass(status?: string | null, pending?: boolean | null) {
  if (status === 'rejected') return 'badge badge-red';
  if (status === 'pending' || pending) return 'badge badge-orange';
  return 'badge badge-green';
}


type TransferTypeFilter = 'all' | 'incoming' | 'outgoing';
type TransferStatusFilter = 'all' | 'approved' | 'pending' | 'rejected';
type TransferDirectionFilter = 'all' | 'customer_to_customer' | 'shop_to_customer' | 'customer_to_shop';
type ActivityFilter = 'all' | 'login' | 'transfer' | 'subscription' | 'payment' | 'account' | 'admin';

function activityFilterLabel(filter: ActivityFilter) {
  const labels: Record<ActivityFilter, string> = {
    all: 'كل الحركات',
    login: 'الدخول والخروج',
    transfer: 'الحوالات',
    subscription: 'الاشتراكات',
    payment: 'المدفوعات',
    account: 'تعديل الحساب',
    admin: 'نشاط الإدارة',
  };
  return labels[filter];
}

function getActivityCategory(row: ActivityRow): ActivityFilter {
  const text = `${row.source || ''} ${row.action || ''} ${JSON.stringify(row.details || {})}`.toLowerCase();
  if (text.includes('login') || text.includes('logout') || text.includes('signin') || text.includes('sign_in') || text.includes('تسجيل')) return 'login';
  if (text.includes('transfer') || text.includes('movement') || text.includes('حوال') || text.includes('movement_number')) return 'transfer';
  if (text.includes('subscription') || text.includes('اشتراك')) return 'subscription';
  if (text.includes('payment') || text.includes('invoice') || text.includes('paid') || text.includes('دفع') || text.includes('فاتورة')) return 'payment';
  if (text.includes('profile') || text.includes('account') || text.includes('update') || text.includes('تحديث') || text.includes('حساب')) return 'account';
  if (text.includes('admin')) return 'admin';
  return 'account';
}

function countTransfersByStatus(rows: TransferMovementRow[], status: TransferStatusFilter) {
  return rows.filter((row) => {
    if (status === 'approved') return row.approval_status === 'approved' || (!row.pending_approval && row.approval_status !== 'rejected' && row.approval_status !== 'pending');
    if (status === 'pending') return row.approval_status === 'pending' || !!row.pending_approval;
    if (status === 'rejected') return row.approval_status === 'rejected';
    return true;
  }).length;
}

function partyText(row: TransferMovementRow, side: 'from' | 'to') {
  if (side === 'from') {
    return row.sender_name || row.from_customer_name || (row.transfer_direction === 'shop_to_customer' ? 'المحل' : '—');
  }
  return row.beneficiary_name || row.to_customer_name || (row.transfer_direction === 'customer_to_shop' ? 'المحل' : '—');
}

function getInitials(name?: string | null) {
  if (!name) return '؟';
  const parts = name.trim().split(/\s+/).slice(0, 2);
  return parts.map((part) => part.charAt(0)).join('').toUpperCase();
}

function quotaValue(user?: UserRow | null) {
  const used = Number(user?.customer_count || 0);
  const limit = user?.customer_limit ?? 5;
  const unlimited = Number(limit) >= 999999;
  return {
    used,
    limit,
    unlimited,
    text: unlimited ? `${formatNumber(used)} / غير محدود` : `${formatNumber(used)} / ${formatNumber(Number(limit))}`,
  };
}

function customerLimitText(limit?: number | null) {
  const normalized = Number(limit ?? 5);
  return normalized >= 999999 ? 'غير محدود' : formatNumber(normalized);
}

function hasActiveSubscription(user?: UserRow | null, sub?: SubscriptionRow | null) {
  const status = user?.subscription_status || sub?.effective_status || sub?.status;
  if (!status) return false;
  return ['active', 'ending_soon', 'trial'].includes(status);
}

function LoginScreen({ onLogin }: { onLogin: (session: AdminSession) => void }) {
  const [userName, setUserName] = useState('');
  const [pin, setPin] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      const session = await adminService.login(userName, pin);
      onLogin(session);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'فشل تسجيل الدخول');
    } finally {
      setLoading(false);
    }
  }

  return (
    <main className="login-shell">
      <section className="login-card">
        <img className="brand-mark" src="/articode-logo.png" alt="ArtiCodeApp" />
        <h1>لوحة تحكم ArtiCodeApp</h1>
        <p>سجل دخولك بحساب مدير النظام الموجود في جدول app_security.</p>
        <form onSubmit={submit} className="login-form">
          <label>
            اسم المستخدم
            <input value={userName} onChange={(e) => setUserName(e.target.value)} placeholder="مثال: Ali" autoComplete="username" />
          </label>
          <label>
            كلمة المرور / PIN
            <input value={pin} onChange={(e) => setPin(e.target.value)} type="password" placeholder="••••" autoComplete="current-password" />
          </label>
          {error ? <div className="alert alert-error">{error}</div> : null}
          <button className="primary-btn" disabled={loading || !userName || !pin}>
            {loading ? 'جاري التحقق...' : 'دخول لوحة الإدارة'}
          </button>
        </form>
        <div className="hint-box">
          قبل الدخول يجب تشغيل ملف SQL المرفق مرة واحدة داخل Supabase حتى تُنشأ دوال لوحة الإدارة.
        </div>
      </section>
    </main>
  );
}

function StatCard({ title, value, icon, tone, foot }: { title: string; value: string; icon: string; tone: string; foot?: string }) {
  return (
    <div className="stat-card">
      <div className={`stat-icon ${tone}`}>{icon}</div>
      <p>{title}</p>
      <strong>{value}</strong>
      {foot ? <span>{foot}</span> : null}
    </div>
  );
}

function LineChart({ data }: { data: { month: string; count: number }[] }) {
  const max = Math.max(...data.map((item) => Number(item.count || 0)), 1);
  const points = data.map((item, idx) => {
    const x = data.length <= 1 ? 20 : 20 + (idx * 360) / (data.length - 1);
    const y = 160 - (Number(item.count || 0) / max) * 120;
    return { x, y, ...item };
  });
  const line = points.map((p) => `${p.x},${p.y}`).join(' ');
  const area = points.length ? `20,170 ${line} 380,170` : '';

  return (
    <div className="chart-card">
      <div className="card-head">
        <h3>نمو الاشتراكات</h3>
        <span>آخر 6 أشهر</span>
      </div>
      <svg className="line-chart" viewBox="0 0 400 190" role="img" aria-label="Subscription growth chart">
        <defs>
          <linearGradient id="lineFill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="#6d5dfc" stopOpacity="0.22" />
            <stop offset="100%" stopColor="#6d5dfc" stopOpacity="0" />
          </linearGradient>
        </defs>
        {[0, 1, 2, 3].map((i) => (
          <line key={i} x1="20" x2="380" y1={45 + i * 35} y2={45 + i * 35} stroke="#e8ebf4" />
        ))}
        {area ? <polygon points={area} fill="url(#lineFill)" /> : null}
        {line ? <polyline points={line} fill="none" stroke="#6d5dfc" strokeWidth="4" strokeLinecap="round" /> : null}
        {points.map((p) => (
          <g key={p.month}>
            <circle cx={p.x} cy={p.y} r="5" fill="#6d5dfc" />
            <text x={p.x} y={p.y - 10} textAnchor="middle" className="chart-label">{p.count}</text>
            <text x={p.x} y="185" textAnchor="middle" className="chart-label month-label">{p.month}</text>
          </g>
        ))}
      </svg>
    </div>
  );
}

function DonutChart({ monthly, yearly }: { monthly: number; yearly: number }) {
  const total = monthly + yearly || 1;
  const monthlyPercent = Math.round((monthly / total) * 100);
  const yearlyPercent = 100 - monthlyPercent;
  return (
    <div className="chart-card donut-wrap">
      <div className="card-head">
        <h3>شهري مقابل سنوي</h3>
        <span>حسب الاشتراكات النشطة</span>
      </div>
      <div className="donut-row">
        <div className="donut" style={{ background: `conic-gradient(#6d5dfc 0 ${monthlyPercent}%, #54a3ff ${monthlyPercent}% 100%)` }}>
          <span>{monthlyPercent}%</span>
        </div>
        <div className="legend-list">
          <div><i className="dot purple" /> شهري <b>{formatNumber(monthly)}</b></div>
          <div><i className="dot blue" /> سنوي <b>{formatNumber(yearly)}</b></div>
          <div className="muted">السنوي: {yearlyPercent}%</div>
        </div>
      </div>
    </div>
  );
}

function UsersTable({ users, onOpenUser, onCreateSubscription }: { users: UserRow[]; onOpenUser: (user: UserRow) => void; onCreateSubscription: (user: UserRow) => void }) {
  return (
    <div className="table-card">
      <div className="table-responsive">
        <table>
          <thead>
            <tr>
              <th>المستخدم</th>
              <th>رقم الحساب</th>
              <th>الصلاحية</th>
              <th>العملاء</th>
              <th>الاشتراك</th>
              <th>تاريخ الانتهاء</th>
              <th>آخر دخول</th>
              <th>إجراءات</th>
            </tr>
          </thead>
          <tbody>
            {users.length === 0 ? (
              <tr><td colSpan={8} className="empty-cell">لا توجد بيانات حالياً</td></tr>
            ) : users.map((user) => (
              <tr key={user.id}>
                <td>
                  <div className="user-cell">
                    <div className="avatar">{getInitials(user.full_name)}</div>
                    <div>
                      <b>{user.full_name}</b>
                      <small>{user.user_name}</small>
                    </div>
                  </div>
                </td>
                <td>{user.account_number || '—'}</td>
                <td><span className="pill">{user.role}</span></td>
                <td>
                  <span className={user.can_add_customer === false ? 'badge badge-orange' : 'badge badge-green'}>{quotaValue(user).text}</span>
                  <small className="subline">{user.quota_message || (user.has_active_subscription ? 'ضمن الاشتراك' : 'الحد المجاني')}</small>
                </td>
                <td>
                  <span className={badgeClass(user.subscription_status)}>{statusLabel(user.subscription_status)}</span>
                  <small className="subline">{user.plan_name || 'بدون خطة'} · {billingLabel(user.billing_cycle)}</small>
                </td>
                <td>{formatDate(user.end_date)}</td>
                <td>{formatDateTime(user.last_login)}</td>
                <td className="actions-cell">
                  <button className="ghost-btn" onClick={() => onOpenUser(user)}>التفاصيل</button>
                  <button className="soft-btn" onClick={() => onCreateSubscription(user)}>اشتراك</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function SubscriptionsTable({ rows, onCancel }: { rows: SubscriptionRow[]; onCancel?: (userId: string, subscriptionId?: string | null) => Promise<void> }) {
  return (
    <div className="table-card">
      <div className="table-responsive">
        <table>
          <thead>
            <tr>
              <th>العميل</th>
              <th>الخطة</th>
              <th>نوع الاشتراك</th>
              <th>البداية</th>
              <th>الانتهاء</th>
              <th>المبلغ</th>
              <th>حد العملاء</th>
              <th>الحالة</th>
              <th>تجديد تلقائي</th>
              {onCancel ? <th>إجراءات</th> : null}
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? <tr><td colSpan={onCancel ? 10 : 9} className="empty-cell">لا توجد اشتراكات بعد</td></tr> : rows.map((row) => (
              <tr key={row.id}>
                <td>
                  <b>{row.full_name}</b>
                  <small className="subline">{row.user_name} · {row.account_number || 'بدون رقم'}</small>
                </td>
                <td>{row.plan_name}</td>
                <td>{billingLabel(row.billing_cycle)}</td>
                <td>{formatDate(row.start_date)}</td>
                <td>
                  {formatDate(row.end_date)}
                  {row.effective_status === 'ending_soon' ? <small className="subline warning">باقي {daysLeft(row.end_date)} يوم</small> : null}
                </td>
                <td>{formatMoney(row.amount, row.currency)}</td>
                <td>{customerLimitText(row.max_customers)}</td>
                <td><span className={badgeClass(row.effective_status)}>{statusLabel(row.effective_status)}</span></td>
                <td>{row.auto_renew ? 'نعم' : 'لا'}</td>
                {onCancel ? (
                  <td>
                    {['active', 'ending_soon', 'trial'].includes(String(row.effective_status || row.status)) ? (
                      <button className="danger-btn compact-btn" onClick={() => onCancel(row.user_id, row.id)}>إلغاء</button>
                    ) : <span className="muted">—</span>}
                  </td>
                ) : null}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function PaymentsTable({ rows }: { rows: PaymentRow[] }) {
  return (
    <div className="table-card">
      <div className="table-responsive">
        <table>
          <thead>
            <tr>
              <th>العميل</th>
              <th>الفاتورة</th>
              <th>المبلغ</th>
              <th>الحالة</th>
              <th>طريقة الدفع</th>
              <th>تاريخ الدفع</th>
              <th>الخطة</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? <tr><td colSpan={8} className="empty-cell">لا توجد مدفوعات بعد</td></tr> : rows.map((row) => (
              <tr key={row.id}>
                <td>
                  <b>{row.full_name}</b>
                  <small className="subline">{row.user_name}</small>
                </td>
                <td>{row.invoice_no || '—'}</td>
                <td>{formatMoney(row.amount, row.currency)}</td>
                <td><span className={badgeClass(row.status)}>{statusLabel(row.status)}</span></td>
                <td>{row.payment_method || '—'}</td>
                <td>{formatDateTime(row.paid_at)}</td>
                <td>{row.plan_name || '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}


function TransferCurrencySummary({ rows }: { rows: TransferMovementsData['stats']['total_amount_by_currency'] }) {
  if (!rows?.length) return <div className="empty-state compact">لا توجد مبالغ مجمعة بعد</div>;
  return (
    <div className="currency-summary">
      {rows.map((row) => (
        <div className="currency-card" key={row.currency}>
          <span>{row.currency}</span>
          <b>{formatMoney(row.net_amount, row.currency)}</b>
          <small>له: {formatMoney(row.incoming_amount, row.currency)} · عليه: {formatMoney(row.outgoing_amount, row.currency)}</small>
        </div>
      ))}
    </div>
  );
}

function getMovementUserId(row: TransferMovementRow) {
  return row.owner_user_id || row.linked_user_id || row.created_by_user_id || row.source_user_id || null;
}

function TransfersTable({ rows, title = 'جدول الحوالات' }: { rows: TransferMovementRow[]; title?: string }) {
  return (
    <div className="table-card">
      <div className="table-responsive">
        <table className="transfers-table">
          <thead>
            <tr>
              <th>{title}</th>
              <th>صاحب الحساب</th>
              <th>من</th>
              <th>إلى</th>
              <th>النوع</th>
              <th>المبلغ</th>
              <th>الحالة</th>
              <th>التاريخ</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? <tr><td colSpan={8} className="empty-cell">لا توجد حوالات أو حركات مالية مطابقة</td></tr> : rows.map((row) => (
              <tr key={row.id}>
                <td>
                  <b>{row.transfer_number || row.movement_number || 'بدون رقم'}</b>
                  <small className="subline">{directionLabel(row.transfer_direction)} · {row.customer_name || 'حساب غير محدد'}</small>
                </td>
                <td>
                  <b>{row.owner_full_name || row.created_by_user_name || row.source_user_name || row.linked_full_name || '—'}</b>
                  <small className="subline">{row.owner_user_name || row.linked_user_name || row.owner_account_number || row.customer_account_number || '—'}</small>
                </td>
                <td>{partyText(row, 'from')}</td>
                <td>{partyText(row, 'to')}</td>
                <td><span className={row.movement_type === 'incoming' ? 'badge badge-green' : 'badge badge-blue'}>{movementLabel(row.movement_type)}</span></td>
                <td>
                  <b>{formatMoney(row.amount, row.currency)}</b>
                  {Number(row.commission || 0) > 0 ? <small className="subline">عمولة: {formatMoney(Number(row.commission), row.commission_currency || row.currency)}</small> : null}
                </td>
                <td><span className={approvalBadgeClass(row.approval_status, row.pending_approval)}>{approvalLabel(row.approval_status, row.pending_approval)}</span></td>
                <td>{formatDateTime(row.created_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function TransferUsersSummary({ rows, onOpenUser }: { rows: TransferMovementsData['user_summary']; onOpenUser?: (userId: string) => void }) {
  return (
    <div className="table-card user-transfer-summary-card">
      <div className="table-responsive">
        <table className="user-transfer-summary-table">
          <thead>
            <tr>
              <th>المستخدم</th>
              <th>إجمالي الحركات</th>
              <th>له</th>
              <th>عليه</th>
              <th>آخر حركة</th>
              <th>التفاصيل الكاملة</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? <tr><td colSpan={6} className="empty-cell">لا يوجد ملخص مستخدمين بعد</td></tr> : rows.map((row) => (
              <tr key={row.user_id || row.full_name || row.user_name}>
                <td>
                  <div className="user-cell">
                    <div className="avatar">{getInitials(row.full_name || row.user_name)}</div>
                    <div>
                      <b>{row.full_name || 'غير مرتبط بمستخدم'}</b>
                      <small>{row.user_name || row.account_number || '—'}</small>
                    </div>
                  </div>
                </td>
                <td><b>{formatNumber(row.total_movements)}</b></td>
                <td><span className="badge badge-green">{formatNumber(row.incoming_movements)}</span></td>
                <td><span className="badge badge-blue">{formatNumber(row.outgoing_movements)}</span></td>
                <td>{formatDateTime(row.last_movement_at)}</td>
                <td>
                  {row.user_id && onOpenUser ? (
                    <button className="primary-btn small-btn" onClick={() => onOpenUser(row.user_id!)}>عرض كل التفاصيل والحركات</button>
                  ) : <span className="muted">غير مرتبط</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function TransfersPage({ data, onOpenUser }: { data: TransferMovementsData; onOpenUser: (userId: string) => void }) {
  const stats = data.stats || emptyTransferData.stats;
  return (
    <div className="page-grid transfers-page">
      <div className="stats-grid">
        <StatCard title="إجمالي الحركات" value={formatNumber(stats.total_movements)} icon="🔁" tone="purple" foot="من account_movements" />
        <StatCard title="له" value={formatNumber(stats.incoming_movements)} icon="⬇️" tone="green" foot="رصيد له" />
        <StatCard title="عليه" value={formatNumber(stats.outgoing_movements)} icon="⬆️" tone="blue" foot="رصيد عليه" />
        <StatCard title="عميل إلى عميل" value={formatNumber(stats.customer_to_customer)} icon="👥" tone="purple" foot="تحويلات داخلية" />
        <StatCard title="معلقة" value={formatNumber(stats.pending_approval)} icon="⏳" tone="orange" foot="تنتظر اعتماد" />
        <StatCard title="مرفوضة" value={formatNumber(stats.rejected_movements)} icon="🚫" tone="orange" foot="Rejected" />
      </div>

      <section className="panel-card focus-users-panel">
        <div className="card-head">
          <div>
            <h3>المستخدمون أصحاب الحوالات</h3>
            <span>كل مستخدم يظهر مرة واحدة فقط. اضغط على الزر لفتح صفحته ومشاهدة كل بياناته وحركاته.</span>
          </div>
          <span>{formatNumber(data.user_summary?.length || 0)} مستخدم</span>
        </div>
        <TransferUsersSummary rows={data.user_summary || []} onOpenUser={onOpenUser} />
      </section>

      <section className="panel-card">
        <div className="card-head"><h3>الحوالات حسب العملة</h3><span>صافي له وعليه للبيانات المعروضة</span></div>
        <TransferCurrencySummary rows={stats.total_amount_by_currency || []} />
      </section>

      <section className="panel-card compact-movements-panel">
        <div className="card-head"><h3>آخر الحركات العامة</h3><span>للمراجعة السريعة فقط — التفاصيل الكاملة من زر المستخدم</span></div>
        <TransfersTable rows={(data.movements || []).slice(0, 20)} title="آخر 20 حركة" />
      </section>
    </div>
  );
}

function ActivityTimeline({ rows }: { rows: ActivityRow[] }) {
  return (
    <div className="activity-list">
      {rows.length === 0 ? <div className="empty-state">لا توجد حركة مسجلة لهذا المستخدم</div> : rows.map((row) => (
        <div className="activity-item" key={`${row.source}-${row.id}-${row.created_at}`}>
          <div className="activity-icon">•</div>
          <div>
            <b>{actionLabel(row.action)}</b>
            <p>{describeActivity(row)}</p>
            <small>{formatDateTime(row.created_at)} {row.device ? `· ${row.device.slice(0, 50)}` : ''}</small>
          </div>
        </div>
      ))}
    </div>
  );
}

function describeActivity(row: ActivityRow) {
  const details = row.details || {};
  const amount = details.amount ? `${details.amount} ${details.currency || ''}` : '';
  const invoice = details.invoice_no ? `فاتورة ${String(details.invoice_no)}` : '';
  const movement = details.movement_number ? `رقم الحركة ${String(details.movement_number)}` : '';
  return String(details.message || invoice || movement || amount || row.source || 'نشاط داخل النظام');
}

function UserDetailPanel({ detail, onClose }: { detail: UserDetailData; onClose: () => void }) {
  const user = detail.user;
  if (!user) return null;
  return (
    <div className="drawer-backdrop" onClick={onClose}>
      <aside className="drawer" onClick={(e) => e.stopPropagation()}>
        <div className="drawer-head">
          <div className="user-cell">
            <div className="avatar big">{getInitials(user.full_name)}</div>
            <div>
              <h2>{user.full_name}</h2>
              <p>{user.user_name} · {user.account_number || 'بدون رقم حساب'}</p>
            </div>
          </div>
          <button className="icon-btn" onClick={onClose}>×</button>
        </div>

        <div className="mini-grid">
          <div><span>الصلاحية</span><b>{user.role}</b></div>
          <div><span>الحالة</span><b>{user.is_active ? 'نشط' : 'غير نشط'}</b></div>
          <div><span>تاريخ الإنشاء</span><b>{formatDate(user.created_at)}</b></div>
          <div><span>آخر دخول</span><b>{formatDateTime(user.last_login)}</b></div>
        </div>

        <h3>الاشتراكات</h3>
        <SubscriptionsTable rows={detail.subscriptions} />

        <h3>المدفوعات</h3>
        <PaymentsTable rows={detail.payments} />

        <h3>حركة الحوالات المالية</h3>
        <TransfersTable rows={detail.transfers || []} title="الحوالات" />

        <h3>حركة الحساب</h3>
        <ActivityTimeline rows={detail.activity} />
      </aside>
    </div>
  );
}

function UserDetailPage({ detail, onBack, onRefresh, onCreateSubscription, onCancelSubscription }: { detail: UserDetailData; onBack: () => void; onRefresh: () => void; onCreateSubscription: (user: UserRow) => void; onCancelSubscription: (userId: string, subscriptionId?: string | null) => Promise<void> }) {
  const user = detail.user;
  const [transferTypeFilter, setTransferTypeFilter] = useState<TransferTypeFilter>('all');
  const [transferStatusFilter, setTransferStatusFilter] = useState<TransferStatusFilter>('all');
  const [transferDirectionFilter, setTransferDirectionFilter] = useState<TransferDirectionFilter>('all');
  const [currencyFilter, setCurrencyFilter] = useState('all');
  const [activityFilter, setActivityFilter] = useState<ActivityFilter>('all');
  const [activitySearch, setActivitySearch] = useState('');

  if (!user) {
    return (
      <section className="panel-card">
        <div className="empty-state">تعذر تحميل بيانات المستخدم</div>
      </section>
    );
  }

  const allTransfers = detail.transfers || [];
  const allActivity = detail.activity || [];
  const incoming = allTransfers.filter((row) => row.movement_type === 'incoming');
  const outgoing = allTransfers.filter((row) => row.movement_type === 'outgoing');
  const latestSubscription = detail.subscriptions?.[0];
  const activeSubscription = detail.subscriptions?.find((item) => ['active', 'ending_soon', 'trial'].includes(String(item.effective_status || item.status)));
  const quota = quotaValue(user);
  const subscriptionActive = hasActiveSubscription(user, activeSubscription || latestSubscription);
  const currencies = Array.from(new Set(allTransfers.map((row) => row.currency || 'USD'))).filter(Boolean);

  const filteredTransfers = allTransfers.filter((row) => {
    const typeMatch = transferTypeFilter === 'all' || row.movement_type === transferTypeFilter;
    const statusMatch = transferStatusFilter === 'all' || countTransfersByStatus([row], transferStatusFilter) === 1;
    const directionMatch = transferDirectionFilter === 'all' || row.transfer_direction === transferDirectionFilter;
    const currencyMatch = currencyFilter === 'all' || (row.currency || 'USD') === currencyFilter;
    return typeMatch && statusMatch && directionMatch && currencyMatch;
  });

  const filteredActivity = allActivity.filter((row) => {
    const categoryMatch = activityFilter === 'all' || getActivityCategory(row) === activityFilter;
    const text = `${actionLabel(row.action)} ${describeActivity(row)} ${row.device || ''} ${row.ip_address || ''}`.toLowerCase();
    const searchMatch = !activitySearch.trim() || text.includes(activitySearch.trim().toLowerCase());
    return categoryMatch && searchMatch;
  });

  function totalByCurrency(rows: TransferMovementRow[], currency: string) {
    return rows.filter((row) => (row.currency || 'USD') === currency).reduce((sum, row) => sum + Number(row.amount || 0), 0);
  }

  function resetTransferFilters() {
    setTransferTypeFilter('all');
    setTransferStatusFilter('all');
    setTransferDirectionFilter('all');
    setCurrencyFilter('all');
  }

  function resetActivityFilters() {
    setActivityFilter('all');
    setActivitySearch('');
  }

  return (
    <div className="user-detail-page page-grid">
      <section className="profile-hero">
        <div className="profile-main">
          <div className="avatar profile-avatar">{getInitials(user.full_name)}</div>
          <div>
            <h2>{user.full_name}</h2>
            <p>{user.user_name} · رقم الحساب: {user.account_number || 'غير محدد'}</p>
            <div className="profile-badges">
              <span className="pill">{user.role}</span>
              <span className={user.is_active ? 'badge badge-green' : 'badge badge-gray'}>{user.is_active ? 'نشط' : 'غير نشط'}</span>
              <span className={badgeClass(user.subscription_status || latestSubscription?.effective_status)}>{statusLabel(user.subscription_status || latestSubscription?.effective_status)}</span>
            </div>
          </div>
        </div>
        <div className="profile-actions">
          <button className="ghost-btn" onClick={onBack}>رجوع</button>
          <button className="soft-btn" onClick={onRefresh}>تحديث بيانات المستخدم</button>
          <button className="primary-btn" onClick={() => onCreateSubscription(user)}>تفعيل / تجديد اشتراك</button>
          {activeSubscription ? (
            <button className="danger-btn" onClick={() => onCancelSubscription(user.id, activeSubscription.id)}>إلغاء الاشتراك</button>
          ) : null}
        </div>
      </section>

      <div className="stats-grid user-stats-grid">
        <StatCard title="إجمالي الحوالات" value={formatNumber(allTransfers.length)} icon="🔁" tone="purple" foot="له وعليه" />
        <StatCard title="العملاء المسموحون" value={quota.text} icon="👤" tone={user.can_add_customer === false ? 'orange' : 'green'} foot={subscriptionActive ? 'اشتراك نشط' : 'الحد المجاني 5 عملاء'} />
        <StatCard title="له" value={formatNumber(incoming.length)} icon="⬇️" tone="green" foot="رصيد له" />
        <StatCard title="عليه" value={formatNumber(outgoing.length)} icon="⬆️" tone="blue" foot="رصيد عليه" />
        <StatCard title="حركة الحساب" value={formatNumber(allActivity.length)} icon="🕘" tone="orange" foot="دخول، خروج، عمليات" />
        <StatCard title="المدفوعات" value={formatNumber(detail.payments?.length || 0)} icon="💳" tone="green" foot="فواتير ودفعات" />
        <StatCard title="الاشتراكات" value={formatNumber(detail.subscriptions?.length || 0)} icon="📅" tone="purple" foot={latestSubscription ? `${billingLabel(latestSubscription.billing_cycle)} · ${formatDate(latestSubscription.end_date)}` : 'بدون اشتراك'} />
      </div>

      <section className="panel-card subscription-control-panel">
        <div className="card-head">
          <div>
            <h3>إدارة الاشتراك وحد العملاء</h3>
            <span>تستطيع تفعيل الاشتراك أو إلغاؤه يدويًا، والحد المجاني بدون اشتراك هو 5 عملاء.</span>
          </div>
          <span className={subscriptionActive ? 'badge badge-green' : 'badge badge-orange'}>{subscriptionActive ? 'مشترك نشط' : 'يحتاج اشتراك بعد الحد المجاني'}</span>
        </div>
        <div className="quota-grid">
          <div className="quota-box"><span>عدد العملاء الحالي</span><b>{formatNumber(quota.used)}</b></div>
          <div className="quota-box"><span>الحد المسموح</span><b>{quota.unlimited ? 'غير محدود' : formatNumber(Number(quota.limit))}</b></div>
          <div className="quota-box"><span>حالة الإضافة</span><b>{user.can_add_customer === false ? 'موقوف حتى الاشتراك' : 'مسموح'}</b></div>
          <div className="quota-box"><span>آخر اشتراك</span><b>{latestSubscription ? `${billingLabel(latestSubscription.billing_cycle)} · ${formatDate(latestSubscription.end_date)}` : 'لا يوجد'}</b></div>
        </div>
        <div className="inline-actions">
          <button className="primary-btn" onClick={() => onCreateSubscription(user)}>تفعيل / تجديد اشتراك</button>
          {activeSubscription ? <button className="danger-btn" onClick={() => onCancelSubscription(user.id, activeSubscription.id)}>إلغاء الاشتراك لهذا المستخدم</button> : null}
        </div>
      </section>

      <section className="panel-card">
        <div className="card-head"><h3>ملخص مبالغ الحوالات حسب العملة</h3><span>صافي له وعليه لهذا المستخدم</span></div>
        {currencies.length === 0 ? <div className="empty-state compact">لا توجد مبالغ لهذا المستخدم</div> : (
          <div className="currency-summary">
            {currencies.map((currency) => {
              const incomingAmount = totalByCurrency(incoming, currency);
              const outgoingAmount = totalByCurrency(outgoing, currency);
              return (
                <div className="currency-card" key={currency}>
                  <span>{currency}</span>
                  <b>{formatMoney(incomingAmount - outgoingAmount, currency)}</b>
                  <small>له: {formatMoney(incomingAmount, currency)} · عليه: {formatMoney(outgoingAmount, currency)}</small>
                </div>
              );
            })}
          </div>
        )}
      </section>

      <section className="panel-card">
        <div className="card-head"><h3>بيانات الحساب</h3><span>معلومات المستخدم الأساسية</span></div>
        <div className="mini-grid profile-info-grid">
          <div><span>اسم المستخدم</span><b>{user.user_name}</b></div>
          <div><span>الاسم الكامل</span><b>{user.full_name}</b></div>
          <div><span>رقم الحساب</span><b>{user.account_number || '—'}</b></div>
          <div><span>الصلاحية</span><b>{user.role}</b></div>
          <div><span>الحالة</span><b>{user.is_active ? 'نشط' : 'غير نشط'}</b></div>
          <div><span>تاريخ الإنشاء</span><b>{formatDate(user.created_at)}</b></div>
          <div><span>آخر تحديث</span><b>{formatDateTime(user.updated_at)}</b></div>
          <div><span>آخر دخول</span><b>{formatDateTime(user.last_login)}</b></div>
        </div>
      </section>

      <section className="panel-card">
        <div className="card-head filters-head">
          <div>
            <h3>حركة الحوالات المالية</h3>
            <span>فلتر حسب له وعليه، الحالة، نوع التحويل، والعملة</span>
          </div>
          <span>{formatNumber(filteredTransfers.length)} من {formatNumber(allTransfers.length)} حركة</span>
        </div>
        <div className="filter-toolbar transfer-filter-toolbar">
          <label>
            النوع
            <select value={transferTypeFilter} onChange={(e) => setTransferTypeFilter(e.target.value as TransferTypeFilter)}>
              <option value="all">كل الحركات</option>
              <option value="incoming">له فقط</option>
              <option value="outgoing">عليه فقط</option>
            </select>
          </label>
          <label>
            الحالة
            <select value={transferStatusFilter} onChange={(e) => setTransferStatusFilter(e.target.value as TransferStatusFilter)}>
              <option value="all">كل الحالات</option>
              <option value="approved">المقبولة / المعتمدة</option>
              <option value="pending">المعلقة</option>
              <option value="rejected">المرفوضة</option>
            </select>
          </label>
          <label>
            اتجاه التحويل
            <select value={transferDirectionFilter} onChange={(e) => setTransferDirectionFilter(e.target.value as TransferDirectionFilter)}>
              <option value="all">كل الاتجاهات</option>
              <option value="customer_to_customer">عميل إلى عميل</option>
              <option value="shop_to_customer">المحل إلى عميل</option>
              <option value="customer_to_shop">عميل إلى المحل</option>
            </select>
          </label>
          <label>
            العملة
            <select value={currencyFilter} onChange={(e) => setCurrencyFilter(e.target.value)}>
              <option value="all">كل العملات</option>
              {currencies.map((currency) => <option key={currency} value={currency}>{currency}</option>)}
            </select>
          </label>
          <button className="ghost-btn reset-filters-btn" onClick={resetTransferFilters}>مسح الفلاتر</button>
        </div>
        <div className="filter-summary">
          <span className="badge badge-green">له: {formatNumber(filteredTransfers.filter((row) => row.movement_type === 'incoming').length)}</span>
          <span className="badge badge-blue">عليه: {formatNumber(filteredTransfers.filter((row) => row.movement_type === 'outgoing').length)}</span>
          <span className="badge badge-green">معتمدة: {formatNumber(countTransfersByStatus(filteredTransfers, 'approved'))}</span>
          <span className="badge badge-orange">معلقة: {formatNumber(countTransfersByStatus(filteredTransfers, 'pending'))}</span>
          <span className="badge badge-red">مرفوضة: {formatNumber(countTransfersByStatus(filteredTransfers, 'rejected'))}</span>
        </div>
        <TransfersTable rows={filteredTransfers} title="حوالات المستخدم" />
      </section>

      <div className="dashboard-two-cols lower">
        <section className="panel-card">
          <div className="card-head filters-head">
            <div>
              <h3>حركة الحساب</h3>
              <span>فلتر نشاط المستخدم حسب الدخول، الحوالات، الاشتراكات، المدفوعات، أو البحث النصي</span>
            </div>
            <span>{formatNumber(filteredActivity.length)} من {formatNumber(allActivity.length)} حركة</span>
          </div>
          <div className="filter-toolbar activity-filter-toolbar">
            <label>
              نوع الحركة
              <select value={activityFilter} onChange={(e) => setActivityFilter(e.target.value as ActivityFilter)}>
                <option value="all">كل الحركات</option>
                <option value="login">الدخول والخروج</option>
                <option value="transfer">الحوالات</option>
                <option value="subscription">الاشتراكات</option>
                <option value="payment">المدفوعات</option>
                <option value="account">تعديل الحساب</option>
                <option value="admin">نشاط الإدارة</option>
              </select>
            </label>
            <label className="filter-search-label">
              بحث داخل الحركة
              <input value={activitySearch} onChange={(e) => setActivitySearch(e.target.value)} placeholder="مثال: تسجيل دخول، فاتورة، رقم حركة..." />
            </label>
            <button className="ghost-btn reset-filters-btn" onClick={resetActivityFilters}>مسح الفلاتر</button>
          </div>
          {activityFilter !== 'all' ? <div className="active-filter-note">يعرض الآن: {activityFilterLabel(activityFilter)}</div> : null}
          <ActivityTimeline rows={filteredActivity} />
        </section>
        <section className="panel-card stacked-sections">
          <div className="card-head"><h3>الاشتراكات والمدفوعات</h3><span>مرتبطة بهذا المستخدم</span></div>
          <h4>الاشتراكات</h4>
          <SubscriptionsTable rows={detail.subscriptions || []} onCancel={onCancelSubscription} />
          <h4>المدفوعات</h4>
          <PaymentsTable rows={detail.payments || []} />
        </section>
      </div>
    </div>
  );
}

function SubscriptionModal({ users, selectedUser, onClose, onSave }: { users: UserRow[]; selectedUser?: UserRow | null; onClose: () => void; onSave: (input: SaveSubscriptionInput) => Promise<void> }) {
  const [userId, setUserId] = useState(selectedUser?.id || users[0]?.id || '');
  const [billingCycle, setBillingCycle] = useState<'monthly' | 'yearly'>('monthly');
  const [startDate, setStartDate] = useState(today());
  const [endDate, setEndDate] = useState(addMonths(today(), 1));
  const [amount, setAmount] = useState(25);
  const [currency, setCurrency] = useState('USD');
  const [planName, setPlanName] = useState('الخطة الأساسية');
  const [status, setStatus] = useState<'active' | 'expired' | 'canceled' | 'trial'>('active');
  const [autoRenew, setAutoRenew] = useState(false);
  const [maxCustomers, setMaxCustomers] = useState(selectedUser?.customer_limit && selectedUser.customer_limit > 5 ? selectedUser.customer_limit : 999999);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    setEndDate(addMonths(startDate, billingCycle === 'yearly' ? 12 : 1));
  }, [billingCycle, startDate]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await onSave({ userId, planName, billingCycle, startDate, endDate, amount, currency, status, autoRenew, maxCustomers });
      onClose();
    } finally {
      setLoading(false);
    }
  }

  return (
    <Modal title="إضافة اشتراك" onClose={onClose}>
      <form className="modal-form" onSubmit={submit}>
        <label>المستخدم
          <select value={userId} onChange={(e) => setUserId(e.target.value)} required>
            {users.map((u) => <option key={u.id} value={u.id}>{u.full_name} — {u.user_name}</option>)}
          </select>
        </label>
        <label>اسم الخطة<input value={planName} onChange={(e) => setPlanName(e.target.value)} /></label>
        <div className="form-row">
          <label>نوع الاشتراك
            <select value={billingCycle} onChange={(e) => setBillingCycle(e.target.value as 'monthly' | 'yearly')}>
              <option value="monthly">شهري</option>
              <option value="yearly">سنوي</option>
            </select>
          </label>
          <label>الحالة
            <select value={status} onChange={(e) => setStatus(e.target.value as any)}>
              <option value="active">نشط</option>
              <option value="trial">تجريبي</option>
              <option value="expired">منتهي</option>
              <option value="canceled">ملغي</option>
            </select>
          </label>
        </div>
        <div className="form-row">
          <label>تاريخ البداية<input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} /></label>
          <label>تاريخ الانتهاء<input type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} /></label>
        </div>
        <div className="form-row">
          <label>المبلغ<input type="number" min="0" step="0.01" value={amount} onChange={(e) => setAmount(Number(e.target.value))} /></label>
          <label>العملة<input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} /></label>
        </div>
        <div className="form-row">
          <label>حد العملاء المسموح<input type="number" min="5" step="1" value={maxCustomers} onChange={(e) => setMaxCustomers(Number(e.target.value))} /></label>
          <label>ملاحظة<input value={maxCustomers >= 999999 ? 'غير محدود' : `حتى ${maxCustomers} عميل`} readOnly /></label>
        </div>
        <div className="quick-limit-row">
          {[5, 20, 50, 100, 999999].map((limit) => (
            <button key={limit} type="button" className="ghost-btn compact-btn" onClick={() => setMaxCustomers(limit)}>
              {limit >= 999999 ? 'غير محدود' : `${limit} عملاء`}
            </button>
          ))}
        </div>
        <label className="checkbox-label"><input type="checkbox" checked={autoRenew} onChange={(e) => setAutoRenew(e.target.checked)} /> تجديد تلقائي</label>
        <button className="primary-btn" disabled={loading || !userId}>{loading ? 'جاري الحفظ...' : 'حفظ الاشتراك'}</button>
      </form>
    </Modal>
  );
}

function PaymentModal({ users, subscriptions, onClose, onSave }: { users: UserRow[]; subscriptions: SubscriptionRow[]; onClose: () => void; onSave: (input: SavePaymentInput) => Promise<void> }) {
  const [userId, setUserId] = useState(users[0]?.id || '');
  const userSubscriptions = subscriptions.filter((s) => s.user_id === userId);
  const [subscriptionId, setSubscriptionId] = useState<string>('');
  const [amount, setAmount] = useState(25);
  const [currency, setCurrency] = useState('USD');
  const [status, setStatus] = useState<'paid' | 'pending' | 'failed' | 'refunded'>('paid');
  const [invoiceNo, setInvoiceNo] = useState(`INV-${new Date().getFullYear()}-${Math.floor(Math.random() * 9000 + 1000)}`);
  const [paymentMethod, setPaymentMethod] = useState('Cash');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    setSubscriptionId(userSubscriptions[0]?.id || '');
  }, [userId]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await onSave({ userId, subscriptionId: subscriptionId || null, amount, currency, status, paidAt: new Date().toISOString(), invoiceNo, paymentMethod });
      onClose();
    } finally {
      setLoading(false);
    }
  }

  return (
    <Modal title="تسجيل دفعة" onClose={onClose}>
      <form className="modal-form" onSubmit={submit}>
        <label>المستخدم
          <select value={userId} onChange={(e) => setUserId(e.target.value)} required>
            {users.map((u) => <option key={u.id} value={u.id}>{u.full_name} — {u.user_name}</option>)}
          </select>
        </label>
        <label>الاشتراك
          <select value={subscriptionId} onChange={(e) => setSubscriptionId(e.target.value)}>
            <option value="">بدون ربط باشتراك</option>
            {userSubscriptions.map((s) => <option key={s.id} value={s.id}>{s.plan_name} — {billingLabel(s.billing_cycle)}</option>)}
          </select>
        </label>
        <div className="form-row">
          <label>المبلغ<input type="number" min="0" step="0.01" value={amount} onChange={(e) => setAmount(Number(e.target.value))} /></label>
          <label>العملة<input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} /></label>
        </div>
        <div className="form-row">
          <label>الحالة
            <select value={status} onChange={(e) => setStatus(e.target.value as any)}>
              <option value="paid">مدفوع</option>
              <option value="pending">معلق</option>
              <option value="failed">فشل</option>
              <option value="refunded">مسترجع</option>
            </select>
          </label>
          <label>طريقة الدفع<input value={paymentMethod} onChange={(e) => setPaymentMethod(e.target.value)} /></label>
        </div>
        <label>رقم الفاتورة<input value={invoiceNo} onChange={(e) => setInvoiceNo(e.target.value)} /></label>
        <button className="primary-btn" disabled={loading || !userId}>{loading ? 'جاري الحفظ...' : 'حفظ الدفعة'}</button>
      </form>
    </Modal>
  );
}

function Modal({ title, children, onClose }: { title: string; children: ReactNode; onClose: () => void }) {
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <section className="modal-card" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2>{title}</h2>
          <button className="icon-btn" onClick={onClose}>×</button>
        </div>
        {children}
      </section>
    </div>
  );
}

function GlobalSearchResults({
  query,
  users,
  subscriptions,
  payments,
  transfers,
  onOpenUser,
  onGoPage,
}: {
  query: string;
  users: UserRow[];
  subscriptions: SubscriptionRow[];
  payments: PaymentRow[];
  transfers: TransferMovementsData;
  onOpenUser: (user: UserRow) => void;
  onGoPage: (page: PageKey) => void;
}) {
  const movementRows = transfers.movements || [];
  const totalResults = users.length + subscriptions.length + payments.length + movementRows.length;

  if (!query.trim()) return null;

  return (
    <section className="panel-card search-results-panel">
      <div className="card-head">
        <div>
          <h3>نتائج البحث عن: {query}</h3>
          <span>يعرض البحث النتائج من المستخدمين، الاشتراكات، الفواتير، وحركة الحوالات.</span>
        </div>
        <span>{formatNumber(totalResults)} نتيجة</span>
      </div>

      <div className="search-summary-grid">
        <button type="button" className="search-summary-card" onClick={() => onGoPage('users')}>
          <span>المستخدمون</span>
          <b>{formatNumber(users.length)}</b>
        </button>
        <button type="button" className="search-summary-card" onClick={() => onGoPage('subscriptions')}>
          <span>الاشتراكات</span>
          <b>{formatNumber(subscriptions.length)}</b>
        </button>
        <button type="button" className="search-summary-card" onClick={() => onGoPage('payments')}>
          <span>الفواتير / الدفعات</span>
          <b>{formatNumber(payments.length)}</b>
        </button>
        <button type="button" className="search-summary-card" onClick={() => onGoPage('transfers')}>
          <span>حركة الحوالات</span>
          <b>{formatNumber(movementRows.length)}</b>
        </button>
      </div>

      {totalResults === 0 ? (
        <div className="empty-state compact">لا توجد نتائج مطابقة. جرّب البحث بالاسم، اسم المستخدم، رقم الحساب، رقم الفاتورة، أو رقم الحركة.</div>
      ) : (
        <div className="search-preview-grid">
          <div className="search-preview-card">
            <h4>أقرب المستخدمين</h4>
            {users.slice(0, 5).map((user) => (
              <div className="search-mini-row" key={user.id}>
                <div className="user-cell">
                  <div className="avatar">{getInitials(user.full_name)}</div>
                  <div>
                    <b>{user.full_name}</b>
                    <small>{user.user_name} · {user.account_number || 'بدون رقم'}</small>
                  </div>
                </div>
                <button type="button" className="ghost-btn small-btn" onClick={() => onOpenUser(user)}>فتح</button>
              </div>
            ))}
            {users.length === 0 ? <small className="muted">لا توجد نتائج مستخدمين</small> : null}
          </div>

          <div className="search-preview-card">
            <h4>الفواتير والدفعات</h4>
            {payments.slice(0, 5).map((payment) => (
              <div className="search-mini-row" key={payment.id}>
                <div>
                  <b>{payment.invoice_no || 'بدون رقم فاتورة'}</b>
                  <small>{payment.full_name} · {formatMoney(payment.amount, payment.currency)}</small>
                </div>
                <span className={badgeClass(payment.status)}>{statusLabel(payment.status)}</span>
              </div>
            ))}
            {payments.length === 0 ? <small className="muted">لا توجد نتائج فواتير</small> : null}
          </div>

          <div className="search-preview-card">
            <h4>حركة الحوالات</h4>
            {movementRows.slice(0, 5).map((movement) => (
              <div className="search-mini-row" key={movement.id}>
                <div>
                  <b>{movement.transfer_number || movement.movement_number || 'بدون رقم'}</b>
                  <small>{movement.owner_full_name || movement.customer_name || '—'} · {movementLabel(movement.movement_type)} · {formatMoney(movement.amount, movement.currency)}</small>
                </div>
                <span className={approvalBadgeClass(movement.approval_status, movement.pending_approval)}>{approvalLabel(movement.approval_status, movement.pending_approval)}</span>
              </div>
            ))}
            {movementRows.length === 0 ? <small className="muted">لا توجد نتائج حوالات</small> : null}
          </div>

          <div className="search-preview-card">
            <h4>الاشتراكات</h4>
            {subscriptions.slice(0, 5).map((subscription) => (
              <div className="search-mini-row" key={subscription.id}>
                <div>
                  <b>{subscription.full_name}</b>
                  <small>{subscription.plan_name} · {billingLabel(subscription.billing_cycle)} · ينتهي {formatDate(subscription.end_date)}</small>
                </div>
                <span className={badgeClass(subscription.effective_status)}>{statusLabel(subscription.effective_status)}</span>
              </div>
            ))}
            {subscriptions.length === 0 ? <small className="muted">لا توجد نتائج اشتراكات</small> : null}
          </div>
        </div>
      )}
    </section>
  );
}

function OverviewPage({ overview, users, onOpenUser, onCreateSubscription }: { overview: OverviewData; users: UserRow[]; onOpenUser: (user: UserRow) => void; onCreateSubscription: (user: UserRow) => void }) {
  const stats = overview.stats || emptyOverview.stats;
  return (
    <div className="page-grid">
      <div className="stats-grid">
        <StatCard title="إجمالي المستخدمين" value={formatNumber(stats.total_users)} icon="👥" tone="purple" foot={`${formatNumber(stats.active_users)} حساب نشط`} />
        <StatCard title="المشتركون النشطون" value={formatNumber(stats.active_subscribers)} icon="✅" tone="green" foot="من الاشتراكات الحالية" />
        <StatCard title="الاشتراكات الشهرية" value={formatNumber(stats.monthly_subscriptions)} icon="📅" tone="blue" foot="Monthly" />
        <StatCard title="الاشتراكات السنوية" value={formatNumber(stats.yearly_subscriptions)} icon="🛡️" tone="purple" foot="Yearly" />
        <StatCard title="قريب الانتهاء" value={formatNumber(stats.ending_soon)} icon="⏱️" tone="orange" foot="خلال 7 أيام" />
        <StatCard title="إيرادات الشهر" value={formatMoney(stats.monthly_revenue)} icon="💵" tone="green" foot={`الإجمالي ${formatMoney(stats.total_revenue)}`} />
      </div>

      <div className="dashboard-two-cols">
        <LineChart data={overview.subscription_growth} />
        <DonutChart monthly={overview.billing_breakdown.monthly} yearly={overview.billing_breakdown.yearly} />
      </div>

      <div className="dashboard-two-cols lower">
        <section className="panel-card">
          <div className="card-head"><h3>المستخدمون الأخيرون</h3><span>{users.length} مستخدم</span></div>
          <UsersTable users={overview.recent_users} onOpenUser={onOpenUser} onCreateSubscription={onCreateSubscription} />
        </section>
        <section className="panel-card">
          <div className="card-head"><h3>آخر حركة حساب</h3><span>نشاط الإدارة</span></div>
          <ActivityTimeline rows={overview.recent_activity} />
        </section>
      </div>
    </div>
  );
}

export default function App() {
  const [session, setSession] = useState<AdminSession | null>(() => adminService.getStoredSession());
  const [page, setPage] = useState<PageKey>('overview');
  const [overview, setOverview] = useState<OverviewData>(emptyOverview);
  const [users, setUsers] = useState<UserRow[]>([]);
  const [subscriptions, setSubscriptions] = useState<SubscriptionRow[]>([]);
  const [payments, setPayments] = useState<PaymentRow[]>([]);
  const [transfersData, setTransfersData] = useState<TransferMovementsData>(emptyTransferData);
  const [searchDraft, setSearchDraft] = useState('');
  const [search, setSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [transferDirectionFilter, setTransferDirectionFilter] = useState('all');
  const [transferStatusFilter, setTransferStatusFilter] = useState('all');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [selectedUser, setSelectedUser] = useState<UserRow | null>(null);
  const [userDetail, setUserDetail] = useState<UserDetailData | null>(null);
  const [showSubscriptionModal, setShowSubscriptionModal] = useState(false);
  const [showPaymentModal, setShowPaymentModal] = useState(false);

  const token = session?.token || '';

  const refreshAll = useCallback(async () => {
    if (!token) return;
    setLoading(true);
    setError('');
    try {
      // ملاحظة مهمة:
      // لا نحمل حركة الحوالات هنا لأنها قد تكون جدولًا كبيرًا جدًا.
      // يتم تحميلها فقط عند فتح صفحة "حركة الحوالات" حتى لا يظهر خطأ statement timeout في الصفحة الرئيسية.
      const shouldLoadTransferResults = search.trim().length > 0;
      const [nextOverview, nextUsers, nextSubscriptions, nextPayments, nextTransfers] = await Promise.all([
        adminService.getOverview(token),
        adminService.getUsers(token, search),
        adminService.getSubscriptions(token, search, statusFilter),
        adminService.getPayments(token, search, statusFilter),
        shouldLoadTransferResults
          ? adminService.getTransfers(token, search, transferDirectionFilter, transferStatusFilter)
          : Promise.resolve(null),
      ]);
      setOverview(nextOverview);
      setUsers(nextUsers);
      setSubscriptions(nextSubscriptions);
      setPayments(nextPayments);
      if (nextTransfers) setTransfersData(nextTransfers);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'حدث خطأ أثناء تحميل البيانات');
    } finally {
      setLoading(false);
    }
  }, [token, search, statusFilter, transferDirectionFilter, transferStatusFilter]);

  const loadTransfers = useCallback(async () => {
    if (!token) return;
    setLoading(true);
    setError('');
    try {
      const nextTransfers = await adminService.getTransfers(token, search, transferDirectionFilter, transferStatusFilter);
      setTransfersData(nextTransfers);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'حدث خطأ أثناء تحميل حركة الحوالات');
    } finally {
      setLoading(false);
    }
  }, [token, search, transferDirectionFilter, transferStatusFilter]);

  useEffect(() => {
    refreshAll();
  }, [refreshAll]);

  useEffect(() => {
    if (page === 'transfers') {
      loadTransfers();
    }
  }, [page, loadTransfers]);

  async function openUser(user: UserRow) {
    await openUserById(user.id, user);
  }

  async function openUserById(userId: string, baseUser?: UserRow) {
    if (!token) return;
    setSelectedUser(baseUser || users.find((user) => user.id === userId) || null);
    setUserDetail(null);
    setPage('user_detail');
    setLoading(true);
    setError('');
    try {
      const detail = await adminService.getUserDetail(token, userId);
      setUserDetail(detail);
      if (detail.user) setSelectedUser(detail.user);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'تعذر فتح تفاصيل المستخدم');
    } finally {
      setLoading(false);
    }
  }

  async function refreshUserDetail() {
    const userId = userDetail?.user?.id || selectedUser?.id;
    if (userId) await openUserById(userId, selectedUser || undefined);
  }

  function handleSearchSubmit(e: FormEvent) {
    e.preventDefault();
    const normalized = searchDraft.trim();
    setSearch(normalized);
  }

  function clearSearch() {
    setSearchDraft('');
    setSearch('');
    if (page !== 'transfers') {
      setTransfersData(emptyTransferData);
    }
  }

  async function handleLogout() {
    if (token) await adminService.logout(token);
    setSession(null);
  }

  async function handleSaveSubscription(input: SaveSubscriptionInput) {
    await adminService.saveSubscription(token, input);
    await refreshAll();
    if (page === 'user_detail') await refreshUserDetail();
  }

  async function handleCancelSubscription(userId: string, subscriptionId?: string | null) {
    const confirmed = window.confirm('هل تريد إلغاء اشتراك هذا المستخدم الآن؟ سيتم إيقاف السماح بإضافة أكثر من 5 عملاء إذا لم يوجد اشتراك آخر نشط.');
    if (!confirmed) return;
    setLoading(true);
    setError('');
    try {
      await adminService.cancelSubscription(token, userId, subscriptionId);
      await refreshAll();
      if (page === 'user_detail') await refreshUserDetail();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'تعذر إلغاء الاشتراك');
    } finally {
      setLoading(false);
    }
  }

  async function handleSavePayment(input: SavePaymentInput) {
    await adminService.savePayment(token, input);
    await refreshAll();
  }

  const activePageTitle = useMemo(() => {
    const titles: Record<PageKey, string> = {
      overview: 'نظرة عامة',
      users: 'المستخدمون',
      subscriptions: 'الاشتراكات',
      payments: 'المدفوعات',
      transfers: 'حركة الحوالات',
      activity: 'حركة الحساب',
      user_detail: userDetail?.user?.full_name ? `ملف المستخدم: ${userDetail.user.full_name}` : 'تفاصيل المستخدم',
    };
    return titles[page];
  }, [page]);

  const activityRows = useMemo(() => {
    if (userDetail?.activity?.length) return userDetail.activity;
    return overview.recent_activity;
  }, [overview.recent_activity, userDetail?.activity]);

  if (!session) {
    return <LoginScreen onLogin={setSession} />;
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="side-brand"><img className="brand-mark" src="/articode-logo.png" alt="ArtiCodeApp" /><b>ArtiCodeApp</b></div>
        <nav>
          <button className={page === 'overview' ? 'active' : ''} onClick={() => setPage('overview')}>🏠 الرئيسية</button>
          <button className={page === 'subscriptions' ? 'active' : ''} onClick={() => setPage('subscriptions')}>📅 الاشتراكات</button>
          <button className={page === 'users' || page === 'user_detail' ? 'active' : ''} onClick={() => setPage('users')}>👥 المستخدمون</button>
          <button className={page === 'activity' ? 'active' : ''} onClick={() => setPage('activity')}>🕘 حركة الحساب</button>
          <button className={page === 'transfers' ? 'active' : ''} onClick={() => setPage('transfers')}>🔁 حركة الحوالات</button>
          <button className={page === 'payments' ? 'active' : ''} onClick={() => setPage('payments')}>💳 المدفوعات</button>
        </nav>
        <div className="side-footer">
          <b>مدير النظام</b>
          <span>{session.admin.full_name}</span>
          <small>{session.admin.role}</small>
        </div>
      </aside>

      <main className="content">
        <header className="topbar">
          <div>
            <h1>{activePageTitle}</h1>
            <p>بيانات حقيقية من Supabase مرتبطة بتطبيق ArtiCodeApp</p>
          </div>
          <div className="top-actions">
            <form className="search-form" onSubmit={handleSearchSubmit}>
              <input
                value={searchDraft}
                onChange={(e) => setSearchDraft(e.target.value)}
                placeholder="بحث بالاسم، المستخدم، رقم الحساب، الفاتورة، رقم الحركة..."
              />
              <button className="primary-btn search-btn" type="submit" disabled={loading}>بحث</button>
              {search ? <button className="ghost-btn search-clear-btn" type="button" onClick={clearSearch}>مسح</button> : null}
            </form>
            {(page === 'subscriptions' || page === 'payments') && (
              <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}>
                <option value="all">كل الحالات</option>
                <option value="active">نشط</option>
                <option value="ending_soon">قريب الانتهاء</option>
                <option value="expired">منتهي</option>
                <option value="paid">مدفوع</option>
                <option value="pending">معلق</option>
              </select>
            )}
            {page === 'transfers' && (
              <>
                <select value={transferDirectionFilter} onChange={(e) => setTransferDirectionFilter(e.target.value)}>
                  <option value="all">كل الاتجاهات</option>
                  <option value="incoming">له فقط</option>
                  <option value="outgoing">عليه فقط</option>
                  <option value="customer_to_customer">عميل إلى عميل</option>
                  <option value="shop_to_customer">المحل إلى عميل</option>
                  <option value="customer_to_shop">عميل إلى المحل</option>
                </select>
                <select value={transferStatusFilter} onChange={(e) => setTransferStatusFilter(e.target.value)}>
                  <option value="all">كل حالات الحوالات</option>
                  <option value="approved">معتمدة</option>
                  <option value="pending">معلقة</option>
                  <option value="rejected">مرفوضة</option>
                </select>
              </>
            )}
            <button className="soft-btn" onClick={page === 'transfers' ? loadTransfers : page === 'user_detail' ? refreshUserDetail : refreshAll}>{loading ? '...' : 'تحديث'}</button>
            <button className="primary-btn" onClick={() => { setSelectedUser(null); setShowSubscriptionModal(true); }}>+ اشتراك</button>
            <button className="soft-btn" onClick={() => setShowPaymentModal(true)}>+ دفعة</button>
            <button className="ghost-btn" onClick={handleLogout}>خروج</button>
          </div>
        </header>

        {error ? <div className="alert alert-error">{error}</div> : null}

        {search && page !== 'user_detail' ? (
          <GlobalSearchResults
            query={search}
            users={users}
            subscriptions={subscriptions}
            payments={payments}
            transfers={transfersData}
            onOpenUser={openUser}
            onGoPage={setPage}
          />
        ) : null}

        {page === 'overview' && <OverviewPage overview={overview} users={users} onOpenUser={openUser} onCreateSubscription={(user) => { setSelectedUser(user); setShowSubscriptionModal(true); }} />}
        {page === 'users' && <UsersTable users={users} onOpenUser={openUser} onCreateSubscription={(user) => { setSelectedUser(user); setShowSubscriptionModal(true); }} />}
        {page === 'subscriptions' && <SubscriptionsTable rows={subscriptions} onCancel={handleCancelSubscription} />}
        {page === 'payments' && <PaymentsTable rows={payments} />}
        {page === 'transfers' && <TransfersPage data={transfersData} onOpenUser={openUserById} />}
        {page === 'user_detail' && userDetail && <UserDetailPage detail={userDetail} onBack={() => setPage('users')} onRefresh={refreshUserDetail} onCreateSubscription={(user) => { setSelectedUser(user); setShowSubscriptionModal(true); }} onCancelSubscription={handleCancelSubscription} />}
        {page === 'user_detail' && !userDetail && (
          <section className="panel-card"><div className="empty-state">جاري تحميل ملف المستخدم...</div></section>
        )}
        {page === 'activity' && (
          <section className="panel-card">
            <div className="card-head"><h3>حركة الحساب</h3><span>{selectedUser ? selectedUser.full_name : 'آخر نشاط عام'}</span></div>
            <ActivityTimeline rows={activityRows} />
          </section>
        )}
      </main>

      {showSubscriptionModal && <SubscriptionModal users={users} selectedUser={selectedUser} onClose={() => setShowSubscriptionModal(false)} onSave={handleSaveSubscription} />}
      {showPaymentModal && <PaymentModal users={users} subscriptions={subscriptions} onClose={() => setShowPaymentModal(false)} onSave={handleSavePayment} />}
    </div>
  );
}
