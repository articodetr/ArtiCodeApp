import { supabase } from '../lib/supabase';

export type NotificationSource = 'general' | 'customer' | 'customer-details';
export type NotificationFilter = 'all' | 'action' | 'unread' | 'pending' | 'approved' | 'rejected';
export type NotificationVisualState = 'action' | 'pending' | 'approved' | 'rejected' | 'info';

export interface NotificationExtraData {
  reason?: string;
  reject_reason?: string;
  note?: string;
  notes?: string;
  description?: string;
  created_by_name?: string;
  created_by_user_id?: string;
  source_user_id?: string;
  creator_user_name?: string;
  creator_full_name?: string;
  approval_status?: string;
  requires_action?: boolean;
  [key: string]: unknown;
}

export interface NotificationCustomer {
  name?: string | null;
  user_id?: string | null;
  linked_user_id?: string | null;
}

export interface NotificationMovement {
  id?: string;
  customer_id?: string | null;
  movement_number?: string | null;
  amount?: number | null;
  currency?: string | null;
  movement_type?: string | null;
  notes?: string | null;
  is_voided?: boolean | null;
  approval_status?: string | null;
  pending_approval?: boolean | null;
  created_by_user_id?: string | null;
  created_by_user_name?: string | null;
  source_user_id?: string | null;
  reject_reason?: string | null;
  customer?: NotificationCustomer | null;
}

export interface MovementNotification {
  id: string;
  user_id?: string | null;
  recipient_user_id?: string | null;
  sender_user_id?: string | null;
  customer_id?: string | null;
  movement_id: string | null;
  notification_type: string;
  title?: string | null;
  message: string;
  is_read: boolean;
  status?: string | null;
  action_required?: boolean | null;
  created_at: string;
  read_at?: string | null;
  acted_at?: string | null;
  deleted_at?: string | null;
  movement_number?: string | null;
  amount?: number | null;
  currency?: string | null;
  movement_type?: string | null;
  customer_name?: string | null;
  actor_name?: string | null;
  extra_data?: NotificationExtraData | null;
  movement?: NotificationMovement | null;
}

export interface CurrentUserLike {
  userId?: string | null;
  userName?: string | null;
  fullName?: string | null;
}

export interface NotificationMeta {
  title: string;
  subtitle: string;
  customerName: string;
  actorName: string;
  amountText: string;
  amountSentenceText: string;
  directionLabel: string;
  directionColor: string;
  statusText: string;
  statusColor: string;
  statusBg: string;
  rowBorderColor: string;
  rowBg: string;
  visualState: NotificationVisualState;
  isUnread: boolean;
  canTakeAction: boolean;
  createdByCurrentUser: boolean;
  noteText?: string;
  rejectReason?: string;
  }

export const NOTIFICATION_SELECT = `
  id,
  user_id,
  recipient_user_id,
  sender_user_id,
  customer_id,
  movement_id,
  notification_type,
  title,
  message,
  is_read,
  status,
  action_required,
  created_at,
  read_at,
  acted_at,
  deleted_at,
  movement_number,
  amount,
  currency,
  movement_type,
  customer_name,
  actor_name,
  extra_data,
  movement:account_movements!movement_id(
    id,
    customer_id,
    movement_number,
    amount,
    currency,
    movement_type,
    notes,
    is_voided,
    approval_status,
    pending_approval,
    created_by_user_id,
    created_by_user_name,
    source_user_id,
    reject_reason,
    customer:customers!customer_id(name, user_id, linked_user_id)
  )
`;

function normalizeNotification(item: MovementNotification): MovementNotification {
  const movement = item.movement || null;

  return {
    ...item,
    customer_id: item.customer_id || movement?.customer_id || null,
    customer_name: movement?.customer?.name || item.customer_name || null,
    movement_number: item.movement_number || movement?.movement_number || null,
    amount: item.amount ?? movement?.amount ?? null,
    currency: item.currency || movement?.currency || null,
    movement_type: item.movement_type || movement?.movement_type || null,
    extra_data: {
      ...(item.extra_data || {}),
      movement_notes: movement?.notes || (item.extra_data as any)?.movement_notes || (item.extra_data as any)?.notes || null,
    },
  };
}

function normalizeText(value?: unknown) {
  return String(value || '').trim().toLowerCase();
}

function sameId(a?: string | null, b?: string | null) {
  return Boolean(a && b && String(a).toLowerCase() === String(b).toLowerCase());
}

function pickText(...values: unknown[]) {
  for (const value of values) {
    const text = String(value || '').trim();
    if (text) return text;
  }
  return '';
}

const CURRENCY_SYMBOLS: Record<string, string> = {
  USD: '$',
  SAR: 'ر.س',
  TRY: '₺',
  YER: 'ر.ي',
  YER_SANA: 'ر.ي',
  YER_ADEN: 'ر.ي',
};

const CURRENCY_ARABIC_NAMES: Record<string, string> = {
  USD: 'دولار',
  SAR: 'ريال سعودي',
  TRY: 'ليرة تركية',
  YER: 'ريال يمني',
  YER_SANA: 'ريال يمني',
  YER_ADEN: 'ريال يمني',
};

function formatSmartNumber(amount: number) {
  return Number(amount).toLocaleString('en-US', {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

export function getCurrencySymbol(currency?: string | null) {
  const key = String(currency || 'USD').toUpperCase();
  return CURRENCY_SYMBOLS[key] || currency || '';
}

export function getCurrencyArabicName(currency?: string | null) {
  const key = String(currency || 'USD').toUpperCase();
  return CURRENCY_ARABIC_NAMES[key] || currency || '';
}

export function formatNotificationAmount(amount?: number | null, currency?: string | null) {
  if (amount == null) return 'بدون مبلغ';
  const numberValue = Number(amount);
  if (!Number.isFinite(numberValue)) return 'بدون مبلغ';
  return `${formatSmartNumber(numberValue)} ${getCurrencySymbol(currency)}`.trim();
}

export function formatNotificationAmountForSentence(amount?: number | null, currency?: string | null) {
  if (amount == null) return 'بدون مبلغ';
  const numberValue = Number(amount);
  if (!Number.isFinite(numberValue)) return 'بدون مبلغ';
  return `${formatSmartNumber(numberValue)} ${getCurrencyArabicName(currency)}`.trim();
}


function getCleanNotificationNote(item: MovementNotification): string {
  const extra = item.extra_data || {};
  const possibleValues = [
    (item as any).notes,
    item.movement?.notes,
    extra.notes,
    extra.note,
    extra.movement_notes,
    extra.movement_note,
  ];

  for (const value of possibleValues) {
    const text = String(value || '').trim();
    if (text && text !== 'null' && text !== 'undefined') {
      return text;
    }
  }

  return 'لا توجد ملاحظة';
}

export function getNotificationCustomerId(item: MovementNotification) {
  return item.customer_id || item.movement?.customer_id || null;
}

export function getNotificationRawStatus(item: MovementNotification) {
  return String(
    item.status || item.extra_data?.approval_status || item.movement?.approval_status || '',
  ).toLowerCase();
}

export function isNotificationUnread(item: MovementNotification) {
  const rawStatus = getNotificationRawStatus(item);
  return !item.is_read || rawStatus === 'unread';
}

export function isNotificationPending(item: MovementNotification) {
  const rawStatus = getNotificationRawStatus(item);

  if (rawStatus === 'approved' || rawStatus === 'rejected' || rawStatus === 'done') {
    return false;
  }

  return (
    rawStatus === 'pending' ||
    item.notification_type === 'approval_needed' ||
    item.notification_type === 'movement_pending' ||
    Boolean(item.movement?.pending_approval)
  );
}

export function isNotificationCreatedByCurrentUser(
  item: MovementNotification,
  currentUser?: CurrentUserLike | null,
) {
  if (!currentUser?.userId && !currentUser?.userName && !currentUser?.fullName) return false;

  const possibleCreatorIds = [
    item.movement?.source_user_id,
    item.movement?.created_by_user_id,
    item.extra_data?.source_user_id as string | undefined,
    item.extra_data?.created_by_user_id as string | undefined,
    item.sender_user_id,
  ].filter(Boolean);

  const possibleCreatorNames = [
    item.movement?.created_by_user_name,
    item.actor_name,
    item.extra_data?.created_by_name as string | undefined,
    item.extra_data?.creator_user_name as string | undefined,
    item.extra_data?.creator_full_name as string | undefined,
  ]
    .map((value) => normalizeText(value))
    .filter(Boolean);

  const currentUserName = normalizeText(currentUser.userName);
  const currentFullName = normalizeText(currentUser.fullName);

  return (
    possibleCreatorIds.some((id) => sameId(id as string, currentUser.userId)) ||
    (Boolean(currentUserName) && possibleCreatorNames.includes(currentUserName)) ||
    (Boolean(currentFullName) && possibleCreatorNames.includes(currentFullName))
  );
}

export function canTakeNotificationAction(
  item: MovementNotification,
  currentUser?: CurrentUserLike | null,
) {
  const rawStatus = getNotificationRawStatus(item);
  const isRecipient = sameId(item.user_id, currentUser?.userId) || sameId(item.recipient_user_id, currentUser?.userId);

  return (
    item.notification_type === 'approval_needed' &&
    Boolean(item.movement_id) &&
    item.action_required !== false &&
    isRecipient &&
    !isNotificationCreatedByCurrentUser(item, currentUser) &&
    rawStatus !== 'approved' &&
    rawStatus !== 'rejected' &&
    rawStatus !== 'done'
  );
}

export function getNotificationNote(item: MovementNotification) {
  return pickText(
    item.extra_data?.note,
    item.extra_data?.notes,
    item.extra_data?.description,
    item.movement?.notes,
  );
}

function buildArabicNotificationTitle(params: {
  actorName: string;
  customerName: string;
  amountSentenceText: string;
  movementType: string;
  createdByCurrentUser: boolean;
  fallbackTitle?: string | null;
}) {
  const { actorName, customerName, amountSentenceText, movementType, createdByCurrentUser, fallbackTitle } = params;
  const isIncoming = movementType === 'incoming';
  const isOutgoing = movementType === 'outgoing';

  if (!isIncoming && !isOutgoing && fallbackTitle) {
    return fallbackTitle;
  }

  if (createdByCurrentUser) {
    if (isIncoming) return `أنت قيدت على ${customerName} مبلغ ${amountSentenceText}`;
  if (isOutgoing) return `أنت قيدت لـ ${customerName} مبلغ ${amountSentenceText}`;
    return `أنت قيدت حركة للعميل ${customerName} بمبلغ ${amountSentenceText}`;
  }

  if (isIncoming) return `${actorName} قيد عليك مبلغ ${amountSentenceText}`;
  if (isOutgoing) return `${actorName} قيد لك مبلغ ${amountSentenceText}`;

  return `${actorName} أنشأ حركة بقيمة ${amountSentenceText}`;
}

export function getNotificationMeta(
  item: MovementNotification,
  currentUser?: CurrentUserLike | null,
): NotificationMeta {
  const amount = item.amount ?? item.movement?.amount ?? null;
  const currency = item.currency || item.movement?.currency || '';
  const movementType = item.movement_type || item.movement?.movement_type || '';
  const amountText = formatNotificationAmount(amount, currency);
  const amountSentenceText = formatNotificationAmountForSentence(amount, currency);
  const customerName = item.customer_name || item.movement?.customer?.name || 'العميل';
  const actorName = item.actor_name || item.movement?.created_by_user_name || 'الطرف الآخر';
  const rawStatus = getNotificationRawStatus(item);
  const pending = isNotificationPending(item);
  const canTakeAction = canTakeNotificationAction(item, currentUser);
  const createdByCurrentUser = isNotificationCreatedByCurrentUser(item, currentUser);
  const rejectReason = pickText(item.extra_data?.reject_reason, item.extra_data?.reason, item.movement?.reject_reason) || undefined;
  const noteText = getCleanNotificationNote(item) || getNotificationNote(item) || undefined;
const isIncoming = movementType === 'incoming';
  const isOutgoing = movementType === 'outgoing';

  let directionLabel = 'حركة';
  let directionColor = '#2563EB';

  if (isIncoming) {
    directionLabel = 'عليه';
    directionColor = '#DC2626';
  } else if (isOutgoing) {
    directionLabel = 'له';
    directionColor = '#059669';
  } else if (movementType === 'internal_transfer') {
    directionLabel = 'تحويل داخلي';
    directionColor = '#7C3AED';
  }

  const title = buildArabicNotificationTitle({
    actorName,
    customerName,
    amountSentenceText,
    movementType,
    createdByCurrentUser,
    fallbackTitle: item.title,
  });

  let subtitle = item.message || '';
  let statusText = 'معلومات';
  let statusColor = '#475569';
  let statusBg = '#F1F5F9';
  let rowBorderColor = '#E5E7EB';
  let rowBg = '#FFFFFF';
  let visualState: NotificationVisualState = 'info';

  if (canTakeAction) {
    subtitle = 'هذه الحركة تحتاج موافقتك قبل أن تدخل في الإجماليات.';
    statusText = 'تحتاج إجراء';
    statusColor = '#B45309';
    statusBg = '#FEF3C7';
    rowBorderColor = '#F59E0B';
    rowBg = '#FFFBEB';
    visualState = 'action';
  } else if (rawStatus === 'approved' || item.notification_type === 'movement_approved') {
    subtitle = createdByCurrentUser ? `تمت موافقة ${customerName} على الحركة.` : 'تمت الموافقة على هذه الحركة.';
    statusText = 'مقبولة';
    statusColor = '#047857';
    statusBg = '#DCFCE7';
    rowBorderColor = '#BBF7D0';
    rowBg = '#F0FDF4';
    visualState = 'approved';
  } else if (rawStatus === 'rejected' || item.notification_type === 'movement_rejected') {
    subtitle = createdByCurrentUser ? `رفض ${customerName} هذه الحركة.` : 'تم رفض هذه الحركة.';
    statusText = 'مرفوضة';
    statusColor = '#B91C1C';
    statusBg = '#FEE2E2';
    rowBorderColor = '#FECACA';
    rowBg = '#FEF2F2';
    visualState = 'rejected';
  } else if (pending) {
  if (createdByCurrentUser) {
    subtitle = customerName
      ? `أنت قيدت على ${customerName}${amountSentenceText ? ` مبلغ ${amountSentenceText}` : ''} وبانتظار موافقته.`
      : 'أنت أضفت هذه الحركة وهي بانتظار موافقة الطرف الآخر.';
  } else {
    subtitle = actorName
      ? `${actorName} قيد عليك${amountSentenceText ? ` مبلغ ${amountSentenceText}` : ''} وبانتظار موافقتك.`
      : 'هذه الحركة بانتظار موافقتك قبل أن تدخل في الإجماليات.';
  }

  statusText = 'معلقة';

  statusColor = '#B45309';

  statusBg = '#FEF3C7';

  rowBorderColor = '#FBBF24';

  rowBg = '#FFFBEB';

  visualState = 'pending';
} else if (!subtitle) {
    subtitle = 'يوجد تحديث جديد على هذه الحركة.';
  }

  return {
    title,
    subtitle,
    customerName,
    actorName,
    amountText,
    amountSentenceText,
    directionLabel,
    directionColor,
    statusText,
    statusColor,
    statusBg,
    rowBorderColor,
    rowBg,
    visualState,
    isUnread: isNotificationUnread(item),
    canTakeAction,
    createdByCurrentUser,
    noteText,
    rejectReason,
  };
}

export function getNotificationSearchText(item: MovementNotification) {
  const movement = item.movement || null;
  const extra = item.extra_data || {};

  const values: unknown[] = [
    item.title,
    item.message,
    item.customer_name,
    item.actor_name,
    item.movement_number,
    item.amount,
    item.currency,
    item.movement_type,
    item.notification_type,
    item.status,

    movement?.customer?.name,
    movement?.created_by_user_name,
    movement?.movement_number,
    movement?.amount,
    movement?.currency,
    movement?.movement_type,
    movement?.approval_status,
    movement?.reject_reason,

    extra.reason,
    extra.reject_reason,
    extra.created_by_name,
    extra.creator_user_name,
    extra.creator_full_name,
    extra.note,
    extra.notes,
    extra.movement_note,
    extra.movement_notes,
  ];

  return values
    .map((value) => normalizeText(value == null ? '' : String(value)))
    .filter(Boolean)
    .join(' ');
}

function getNotificationDedupScore(item: MovementNotification) {
  let score = 0;

  if (item.movement?.customer?.name) score += 10;
  if (item.customer_name) score += 5;
  if (item.action_required === false) score += 2;
  if (item.message) score += 1;
  if (item.title) score += 1;

  return score;
}

function dedupeMovementNotifications(items: MovementNotification[]): MovementNotification[] {
  const output = new Map<string, MovementNotification>();

  for (const rawItem of items) {
    const item = normalizeNotification(rawItem);
    const rawStatus = getNotificationRawStatus(item);
    const key = item.movement_id
      ? [item.user_id || '', item.movement_id, rawStatus || item.notification_type || 'info'].join('::')
      : item.id;

    const existing = output.get(key);
    if (!existing) {
      output.set(key, item);
      continue;
    }

    const currentScore = getNotificationDedupScore(item);
    const existingScore = getNotificationDedupScore(existing);

    if (currentScore > existingScore) {
      output.set(key, item);
    }
  }

  return Array.from(output.values());
}


export function notificationMatchesSearch(item: MovementNotification, searchQuery: string) {
  const query = normalizeText(searchQuery).replace(/\s+/g, ' ');
  if (!query) return true;

  const searchableText = getNotificationSearchText(item);
  return searchableText.includes(query);
}

export function searchNotifications(
  notifications: MovementNotification[],
  searchQuery: string,
) {
  const query = normalizeText(searchQuery);
  if (!query) return notifications;

  return notifications.filter((item) => notificationMatchesSearch(item, query));
}

export function filterNotifications(
  notifications: MovementNotification[],
  filter: NotificationFilter,
  currentUser?: CurrentUserLike | null,
) {
  if (filter === 'action') {
    return notifications.filter((item) => canTakeNotificationAction(item, currentUser));
  }

  if (filter === 'unread') {
    return notifications.filter((item) => isNotificationUnread(item));
  }

  if (filter === 'pending') {
    return notifications.filter((item) => isNotificationPending(item));
  }

  if (filter === 'approved') {
    return notifications.filter((item) => {
      const rawStatus = getNotificationRawStatus(item);
      return rawStatus === 'approved' || item.notification_type === 'movement_approved';
    });
  }

  if (filter === 'rejected') {
    return notifications.filter((item) => {
      const rawStatus = getNotificationRawStatus(item);
      return rawStatus === 'rejected' || item.notification_type === 'movement_rejected';
    });
  }

  return notifications;
}

export async function getGeneralNotifications(userId: string) {
  const { data, error } = await supabase
    .from('movement_notifications')
    .select(NOTIFICATION_SELECT)
    .eq('user_id', userId)
    .is('deleted_at', null)
    .order('created_at', { ascending: false });

  if (error) throw error;
  return dedupeMovementNotifications((data || []) as MovementNotification[]);
}

export async function getCustomerNotifications(userId: string, customerId: string) {
  const { data, error } = await supabase
    .from('movement_notifications')
    .select(NOTIFICATION_SELECT)
    .eq('user_id', userId)
    .eq('customer_id', customerId)
    .is('deleted_at', null)
    .order('created_at', { ascending: false });

  if (error) throw error;
  return dedupeMovementNotifications((data || []) as MovementNotification[]);
}

export async function getNotificationById(notificationId: string) {
  const { data, error } = await supabase
    .from('movement_notifications')
    .select(NOTIFICATION_SELECT)
    .eq('id', notificationId)
    .maybeSingle();

  if (error) throw error;
  return data ? normalizeNotification(data as MovementNotification) : null;
}

export async function markNotificationAsRead(notificationId: string, userId?: string | null, currentStatus?: string | null) {
  const normalizedStatus = String(currentStatus || '').toLowerCase();
  const updatePayload: { is_read: boolean; read_at: string; status?: string } = {
    is_read: true,
    read_at: new Date().toISOString(),
  };

  if (!normalizedStatus || normalizedStatus === 'unread') {
    updatePayload.status = 'read';
  }

  let query = supabase
    .from('movement_notifications')
    .update(updatePayload)
    .eq('id', notificationId);

  if (userId) {
    query = query.eq('user_id', userId);
  }

  const { error } = await query;
  if (error) throw error;
}

export async function softDeleteNotification(notificationId: string, userId: string) {
  const { error } = await supabase
    .from('movement_notifications')
    .update({
      deleted_at: new Date().toISOString(),
      deleted_by_user_id: userId,
    })
    .eq('id', notificationId)
    .eq('user_id', userId);

  if (error) throw error;
}

export async function getCustomerNotificationAttentionCount(userId: string, customerId: string) {
  const { count, error } = await supabase
    .from('movement_notifications')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .eq('customer_id', customerId)
    .is('deleted_at', null)
    .or('is_read.eq.false,action_required.eq.true,status.eq.unread,status.eq.pending');

  if (error) throw error;
  return count || 0;
}

export async function getGeneralNotificationAttentionCount(userId: string) {
  const { count, error } = await supabase
    .from('movement_notifications')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .is('deleted_at', null)
    .or('is_read.eq.false,action_required.eq.true,status.eq.unread,status.eq.pending');

  if (error) throw error;
  return count || 0;
}

export async function approveMovementNotification(
  item: MovementNotification,
  currentUser?: CurrentUserLike | null,
) {
  if (!item.movement_id) {
    throw new Error('لا يوجد رقم حركة مرتبط بهذا الإشعار');
  }

  const userName = currentUser?.userName || currentUser?.fullName;
  if (!userName) {
    throw new Error('تعذر معرفة اسم المستخدم الحالي');
  }

  const { error } = await supabase.rpc('approve_movement', {
    p_movement_id: item.movement_id,
    p_user_name: userName,
  });

  if (error) throw error;

  const latest = await getNotificationById(item.id);
  return latest || {
    ...item,
    status: 'approved',
    action_required: false,
    is_read: true,
    acted_at: new Date().toISOString(),
    read_at: new Date().toISOString(),
  };
}

export async function rejectMovementNotification(
  item: MovementNotification,
  currentUser: CurrentUserLike | null | undefined,
  rejectReason: string,
) {
  if (!item.movement_id) {
    throw new Error('لا يوجد رقم حركة مرتبط بهذا الإشعار');
  }

  const userName = currentUser?.userName || currentUser?.fullName;
  if (!userName) {
    throw new Error('تعذر معرفة اسم المستخدم الحالي');
  }

  const trimmedReason = rejectReason.trim();
  if (!trimmedReason) {
    throw new Error('يرجى كتابة سبب الرفض');
  }

  const { error } = await supabase.rpc('reject_movement_with_reason', {
    p_movement_id: item.movement_id,
    p_user_name: userName,
    p_reject_reason: trimmedReason,
  });

  if (error) throw error;

  const latest = await getNotificationById(item.id);
  return latest || {
    ...item,
    status: 'rejected',
    action_required: false,
    is_read: true,
    acted_at: new Date().toISOString(),
    read_at: new Date().toISOString(),
    extra_data: {
      ...(item.extra_data || {}),
      reject_reason: trimmedReason,
    },
  };
}
