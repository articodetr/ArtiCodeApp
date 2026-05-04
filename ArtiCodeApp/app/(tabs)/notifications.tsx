import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  FlatList,
  RefreshControl,
StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { useFocusEffect } from '@react-navigation/native';
import { Bell, Search, X } from 'lucide-react-native';

import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { useDataRefresh } from '@/contexts/DataRefreshContext';
import NotificationCard from '../../components/NotificationCard';
import {
  approveMovementNotification,
  getGeneralNotifications,
  getNotificationCustomerId,
  MovementNotification,
  rejectMovementNotification,
  softDeleteNotification,
} from '../../services/notificationService';

type LocalNotificationFilter =
  | 'all'
  | 'action'
  | 'pending'
  | 'approved'
  | 'rejected'
  | 'unread';

type CurrentUserLike = {
  userId?: string | null;
  userName?: string | null;
  fullName?: string | null;
} | null;

const FILTERS: Array<{ key: LocalNotificationFilter; label: string }> = [
  { key: 'all', label: 'الكل' },
  { key: 'pending', label: 'معلقة' },
  { key: 'rejected', label: 'مرفوضة' },
];

function normalizeText(value?: unknown) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[أإآا]/g, 'ا')
    .replace(/ى/g, 'ي')
    .replace(/ة/g, 'ه')
    .replace(/[^\p{L}\p{N}\s.$₺ر]/gu, ' ')
    .replace(/\s+/g, ' ');
}

function sameId(a?: string | null, b?: string | null) {
  return Boolean(a && b && String(a).toLowerCase() === String(b).toLowerCase());
}

function getNotificationRawStatus(item: MovementNotification) {
  const anyItem = item as any;

  return normalizeText(
    anyItem.status ||
      anyItem.extra_data?.approval_status ||
      anyItem.movement?.approval_status ||
      '',
  );
}

function isNotificationUnread(item: MovementNotification) {
  const anyItem = item as any;
  const rawStatus = getNotificationRawStatus(item);

  return !anyItem.is_read || rawStatus === 'unread';
}

function isNotificationPending(item: MovementNotification) {
  const anyItem = item as any;
  const rawStatus = getNotificationRawStatus(item);

  if (rawStatus === 'approved' || rawStatus === 'rejected' || rawStatus === 'done') {
    return false;
  }

  return (
    rawStatus === 'pending' ||
    anyItem.notification_type === 'approval_needed' ||
    Boolean(anyItem.action_required) ||
    Boolean(anyItem.movement?.pending_approval)
  );
}

function isNotificationApproved(item: MovementNotification) {
  const anyItem = item as any;
  const rawStatus = getNotificationRawStatus(item);

  return rawStatus === 'approved' || anyItem.notification_type === 'movement_approved';
}

function isNotificationRejected(item: MovementNotification) {
  const anyItem = item as any;
  const rawStatus = getNotificationRawStatus(item);

  return rawStatus === 'rejected' || anyItem.notification_type === 'movement_rejected';
}

function isNotificationCreatedByCurrentUser(
  item: MovementNotification,
  currentUser?: CurrentUserLike,
) {
  if (!currentUser?.userId && !currentUser?.userName && !currentUser?.fullName) {
    return false;
  }

  const anyItem = item as any;
  const movement = anyItem.movement || {};
  const extra = anyItem.extra_data || {};

  const possibleCreatorIds = [
    movement.source_user_id,
    movement.created_by_user_id,
    extra.source_user_id,
    extra.created_by_user_id,
    anyItem.sender_user_id,
  ].filter(Boolean);

  const possibleCreatorNames = [
    movement.created_by_user_name,
    anyItem.actor_name,
    extra.created_by_name,
    extra.creator_user_name,
    extra.creator_full_name,
  ]
    .map((value) => normalizeText(value))
    .filter(Boolean);

  const currentUserName = normalizeText(currentUser.userName);
  const currentFullName = normalizeText(currentUser.fullName);

  return (
    possibleCreatorIds.some((id) => sameId(String(id), currentUser.userId)) ||
    (Boolean(currentUserName) && possibleCreatorNames.includes(currentUserName)) ||
    (Boolean(currentFullName) && possibleCreatorNames.includes(currentFullName))
  );
}

function canTakeNotificationAction(
  item: MovementNotification,
  currentUser?: CurrentUserLike,
) {
  const anyItem = item as any;
  const rawStatus = getNotificationRawStatus(item);

  const isRecipient =
    sameId(anyItem.user_id, currentUser?.userId) ||
    sameId(anyItem.recipient_user_id, currentUser?.userId);

  return (
    anyItem.notification_type === 'approval_needed' &&
    Boolean(anyItem.movement_id) &&
    anyItem.action_required !== false &&
    isRecipient &&
    !isNotificationCreatedByCurrentUser(item, currentUser) &&
    rawStatus !== 'approved' &&
    rawStatus !== 'rejected' &&
    rawStatus !== 'done'
  );
}

function filterNotificationsLocally(
  notifications: MovementNotification[],
  filter: LocalNotificationFilter,
  currentUser?: CurrentUserLike,
) {
  if (filter === 'action') {
    return notifications.filter((item) => canTakeNotificationAction(item, currentUser));
  }

  if (filter === 'pending') {
    return notifications.filter((item) => isNotificationPending(item));
  }

  if (filter === 'approved') {
    return notifications.filter((item) => isNotificationApproved(item));
  }

  if (filter === 'rejected') {
    return notifications.filter((item) => isNotificationRejected(item));
  }

  if (filter === 'unread') {
    return notifications.filter((item) => isNotificationUnread(item));
  }

  return notifications;
}

function getNotificationSearchText(item: MovementNotification) {
  const anyItem = item as any;
  const movement = anyItem.movement || {};
  const customer = movement.customer || {};
  const extra = anyItem.extra_data || {};

  const values: unknown[] = [
    anyItem.title,
    anyItem.message,
    anyItem.customer_name,
    anyItem.actor_name,
    anyItem.movement_number,
    anyItem.amount,
    anyItem.currency,
    anyItem.movement_type,
    anyItem.notification_type,
    anyItem.status,

    customer.name,
    movement.created_by_user_name,
    movement.movement_number,
    movement.amount,
    movement.currency,
    movement.movement_type,
    movement.approval_status,
    movement.reject_reason,
    movement.notes,

    extra.reason,
    extra.reject_reason,
    extra.created_by_name,
    extra.creator_user_name,
    extra.creator_full_name,
    extra.note,
    extra.notes,
    extra.description,
    extra.movement_note,
    extra.movement_notes,
  ];

  return values
    .map((value) => normalizeText(value))
    .filter(Boolean)
    .join(' ');
}

function searchNotificationsLocally(
  notifications: MovementNotification[],
  searchQuery: string,
) {
  const query = normalizeText(searchQuery);

  if (!query) {
    return notifications;
  }

  return notifications.filter((item) => getNotificationSearchText(item).includes(query));
}


function isNotificationNameForCurrentUser(
  value: unknown,
  currentUser?: CurrentUserLike,
) {
  const candidate = normalizeText(value);
  if (!candidate) return false;

  const currentNames = [currentUser?.userName, currentUser?.fullName]
    .map((item) => normalizeText(item))
    .filter(Boolean);

  return currentNames.includes(candidate);
}

function extractCustomerNameFromNotificationText(value?: unknown) {
  const text = String(value || '').trim();
  if (!text) return '';

  const patterns = [
    /أنتs+قيدتs+(?:على|لـ|ل)s+(.+?)(?:s+مبلغ|$)/u,
    /قيدتs+(?:على|لـ|ل)s+(.+?)(?:s+مبلغ|$)/u,
    /تمتs+موافقةs+(.+?)s+علىs+الحركة/u,
    /رفضs+(.+?)s+هذهs+الحركة/u,
  ];

  for (const pattern of patterns) {
    const match = text.match(pattern);
    const extracted = String(match?.[1] || '').trim();
    if (extracted) {
      return extracted;
    }
  }

  return '';
}

function pickNotificationDisplayCustomerName(
  item: MovementNotification,
  currentUser?: CurrentUserLike,
) {
  const anyItem = item as any;
  const movement = anyItem.movement || {};
  const extra = anyItem.extra_data || {};

  const candidates = [
    extractCustomerNameFromNotificationText(anyItem.title),
    extractCustomerNameFromNotificationText(anyItem.message),
    anyItem.customer_name,
    movement.customer?.name,
    extra.customer_name,
    extra.counterparty_name,
    extra.linked_customer_name,
  ];

  for (const candidate of candidates) {
    const cleaned = String(candidate || '').trim();
    if (!cleaned) continue;
    if (isNotificationNameForCurrentUser(cleaned, currentUser)) continue;
    return cleaned;
  }

  return '';
}

function patchNotificationForDisplay(
  item: MovementNotification,
  currentUser?: CurrentUserLike,
): MovementNotification {
  const forcedCustomerName = pickNotificationDisplayCustomerName(item, currentUser);
  const anyItem = item as any;
  const movement = anyItem.movement || null;

  if (!forcedCustomerName) {
    return item;
  }

  return {
    ...item,
    customer_name: forcedCustomerName,
    movement: movement
      ? {
          ...movement,
          customer: {
            ...(movement.customer || {}),
            name: forcedCustomerName,
          },
        }
      : movement,
  };
}

function getGeneralNotificationVisualDedupKey(item: MovementNotification) {
  const rawStatus = getNotificationRawStatus(item);
  return item.movement_id
    ? [item.movement_id, rawStatus || item.notification_type || 'info'].join('::')
    : item.id;
}

function getGeneralNotificationVisualScore(
  item: MovementNotification,
  currentUser?: CurrentUserLike,
) {
  let score = 0;

  const displayCustomerName = pickNotificationDisplayCustomerName(item, currentUser);
  if (displayCustomerName) score += 20;
  if (item.message) score += 2;
  if (item.title) score += 2;
  if ((item as any).action_required === false) score += 1;
  if (!isNotificationNameForCurrentUser(item.customer_name, currentUser)) score += 8;
  if (!isNotificationNameForCurrentUser(item.movement?.customer?.name, currentUser)) score += 8;

  return score;
}

function dedupeAndFixGeneralNotifications(
  notifications: MovementNotification[],
  currentUser?: CurrentUserLike,
) {
  const output = new Map<string, MovementNotification>();

  for (const rawItem of notifications) {
    const patchedItem = patchNotificationForDisplay(rawItem, currentUser);
    const key = getGeneralNotificationVisualDedupKey(patchedItem);
    const existing = output.get(key);

    if (!existing) {
      output.set(key, patchedItem);
      continue;
    }

    const currentScore = getGeneralNotificationVisualScore(patchedItem, currentUser);
    const existingScore = getGeneralNotificationVisualScore(existing, currentUser);

    if (currentScore > existingScore) {
      output.set(key, patchedItem);
    }
  }

  return Array.from(output.values());
}

export default function NotificationsTabScreen() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const { triggerRefresh } = useDataRefresh();

  const [notifications, setNotifications] = useState<MovementNotification[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [activeFilter, setActiveFilter] = useState<LocalNotificationFilter>('all');
  const [searchQuery, setSearchQuery] = useState('');
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [processingActionId, setProcessingActionId] = useState<string | null>(null);

  const loadNotifications = useCallback(async () => {
    if (!currentUser?.userId) {
      setNotifications([]);
      setIsLoading(false);
      setIsRefreshing(false);
      return;
    }

    try {
      const nextNotifications = await getGeneralNotifications(currentUser.userId);
      setNotifications(dedupeAndFixGeneralNotifications(nextNotifications, currentUser));
    } catch (error) {
      console.error('[Notifications] Error loading general notifications:', error);
      Alert.alert('خطأ', 'تعذر تحميل الإشعارات العامة');
    } finally {
      setIsLoading(false);
      setIsRefreshing(false);
    }
  }, [currentUser?.fullName, currentUser?.userId, currentUser?.userName]);

  useFocusEffect(
    useCallback(() => {
      loadNotifications();
    }, [loadNotifications]),
  );

  const loadRef = useRef(loadNotifications);

  useEffect(() => {
    loadRef.current = loadNotifications;
  }, [loadNotifications]);

  useEffect(() => {
    if (!currentUser?.userId) return;

    const channelName = `general-notifications-${currentUser.userId}-${Date.now()}`;
    const channel = supabase.channel(channelName);

    channel
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'movement_notifications',
          filter: `user_id=eq.${currentUser.userId}`,
        },
        () => {
          loadRef.current?.();
        },
      )
      .subscribe();

    return () => {
      try {
        supabase.removeChannel(channel);
      } catch {
        // Ignore duplicate cleanup errors.
      }
    };
  }, [currentUser?.userId]);

  const filteredNotifications = useMemo(
    () => filterNotificationsLocally(notifications, activeFilter, currentUser),
    [activeFilter, currentUser, notifications],
  );

  const visibleNotifications = useMemo(
    () => searchNotificationsLocally(filteredNotifications, searchQuery),
    [filteredNotifications, searchQuery],
  );

  const filterCounts = useMemo<Record<LocalNotificationFilter, number>>(
    () => ({
      all: notifications.length,
      action: filterNotificationsLocally(notifications, 'action', currentUser).length,
      pending: filterNotificationsLocally(notifications, 'pending', currentUser).length,
      approved: filterNotificationsLocally(notifications, 'approved', currentUser).length,
      rejected: filterNotificationsLocally(notifications, 'rejected', currentUser).length,
      unread: filterNotificationsLocally(notifications, 'unread', currentUser).length,
    }),
    [currentUser, notifications],
  );

  const onRefresh = () => {
    setIsRefreshing(true);
    loadNotifications();
  };

  const openNotification = (_item: MovementNotification) => {
    // تم حذف صفحة تفاصيل الإشعار الخاصة.
    // القبول والرفض والملاحظة تظهر مباشرة داخل بطاقة الإشعار.
  };

  const confirmDelete = (item: MovementNotification) => {
    if (!currentUser?.userId) return;

    Alert.alert(
      'حذف الإشعار',
      'سيتم إخفاء الإشعار من هذه القائمة فقط، ولن يتم حذف الحركة المالية.\nهل تريد المتابعة؟',
      [
        { text: 'إلغاء', style: 'cancel' },
        {
          text: 'حذف',
          style: 'destructive',
          onPress: async () => {
            try {
              setDeletingId(item.id);
              await softDeleteNotification(item.id, currentUser.userId);
              setNotifications((current) =>
                current.filter((notification) => notification.id !== item.id),
              );
            } catch (error) {
              console.error('[Notifications] Error deleting notification:', error);
              Alert.alert('خطأ', 'تعذر حذف الإشعار');
            } finally {
              setDeletingId(null);
            }
          },
        },
      ],
    );
  };

  const handleAcceptNotification = async (item: MovementNotification) => {
    if (!currentUser) {
      throw new Error('تعذر معرفة المستخدم الحالي');
    }

    try {
      setProcessingActionId(item.id);
      await approveMovementNotification(item, currentUser);
      triggerRefresh('movements');
      triggerRefresh('customers');
      await loadNotifications();
    } finally {
      setProcessingActionId(null);
    }
  };

  const handleRejectNotification = async (item: MovementNotification, reason: string) => {
    if (!currentUser) {
      throw new Error('تعذر معرفة المستخدم الحالي');
    }

    try {
      setProcessingActionId(item.id);
      await rejectMovementNotification(item, currentUser, reason);
      triggerRefresh('movements');
      triggerRefresh('customers');
      await loadNotifications();
    } finally {
      setProcessingActionId(null);
    }
  };

  if (isLoading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color="#2563EB" />
        <Text style={styles.loadingText}>جاري تحميل الإشعارات...</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <View style={styles.headerTextWrap}>
          <Text style={styles.headerTitle}>الإشعارات العامة</Text>
          <Text style={styles.headerSubtitle}>
            تابع الحركات التي تحتاج مراجعة أو التي تم قبولها أو رفضها.
          </Text>
        </View>

        <View style={styles.headerIcon}>
          <Bell size={22} color="#2563EB" />
        </View>
      </View>

      <View style={styles.searchBox}>
        <Search size={17} color="#64748B" />

        <TextInput
          value={searchQuery}
          onChangeText={setSearchQuery}
          placeholder="بحث بالاسم، المبلغ، رقم الحوالة أو الملاحظة"
          placeholderTextColor="#94A3B8"
          style={styles.searchInput}
          textAlign="right"
          returnKeyType="search"
        />

        {searchQuery.trim().length > 0 && (
          <TouchableOpacity
            style={styles.clearSearchButton}
            onPress={() => setSearchQuery('')}
            activeOpacity={0.75}
          >
            <X size={15} color="#64748B" />
          </TouchableOpacity>
        )}
      </View>

      <View style={styles.filtersRow}>
        {FILTERS.map((filter) => {
          const isActive = activeFilter === filter.key;
          const count = filterCounts[filter.key];
          const shouldShowCount = filter.key === 'pending' && count > 0;

          return (
            <TouchableOpacity
              key={filter.key}
              style={[styles.filterChip, isActive && styles.filterChipActive]}
              onPress={() => setActiveFilter(filter.key)}
              activeOpacity={0.75}
            >
              <Text style={[styles.filterText, isActive && styles.filterTextActive]}>
                {filter.label}
              </Text>

              {shouldShowCount && (
                <View style={[styles.filterCount, isActive && styles.filterCountActive]}>
                  <Text
                    style={[
                      styles.filterCountText,
                      isActive && styles.filterCountTextActive,
                    ]}
                  >
                    {count}
                  </Text>
                </View>
              )}
            </TouchableOpacity>
          );
        })}
      </View>

      <FlatList
        data={visibleNotifications}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => (
          <NotificationCard
            notification={item}
            currentUser={currentUser}
            onPress={() => openNotification(item)}
            onDelete={confirmDelete}
            onAccept={handleAcceptNotification}
            onReject={handleRejectNotification}
            isDeleting={deletingId === item.id}
            isProcessing={processingActionId === item.id}
            showCustomer
            unreadColor="#2563EB"
          />
        )}
        contentContainerStyle={styles.listContent}
        keyboardShouldPersistTaps="handled"
        refreshControl={
          <RefreshControl
            refreshing={isRefreshing}
            onRefresh={onRefresh}
            tintColor="#2563EB"
          />
        }
        ListEmptyComponent={
          <View style={styles.emptyState}>
            <Bell size={42} color="#CBD5E1" />
            <Text style={styles.emptyTitle}>
              {searchQuery.trim() ? 'لا توجد نتائج للبحث' : 'لا توجد إشعارات'}
            </Text>
            <Text style={styles.emptySubtitle}>
              {searchQuery.trim()
                ? 'جرّب البحث باسم آخر أو مبلغ أو رقم حوالة مختلف.'
                : 'عند وصول إشعارات جديدة ستظهر هنا.'}
            </Text>
          </View>
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F8FAFC',
  },
  loadingContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#F8FAFC',
  },
  loadingText: {
    marginTop: 12,
    color: '#64748B',
    fontSize: 15,
  },
  header: {
    backgroundColor: '#FFFFFF',
    paddingHorizontal: 18,
    paddingTop: 14,
    paddingBottom: 12,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    gap: 10,
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  headerIcon: {
    width: 42,
    height: 42,
    borderRadius: 14,
    backgroundColor: '#DBEAFE',
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerTextWrap: {
    flex: 1,
  },
  headerTitle: {
    fontSize: 20,
    color: '#0F172A',
    fontWeight: '900',
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  headerSubtitle: {
    marginTop: 3,
    fontSize: 12,
    color: '#64748B',
    textAlign: 'right',
    writingDirection: 'rtl',
    lineHeight: 18,
  },
  searchBox: {
    marginHorizontal: 14,
    marginTop: 10,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    backgroundColor: '#FFFFFF',
    minHeight: 44,
    paddingHorizontal: 12,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    gap: 8,
  },
  searchInput: {
    flex: 1,
    color: '#0F172A',
    fontSize: 13,
    fontWeight: '700',
    paddingVertical: 8,
    writingDirection: 'rtl',
  },
  clearSearchButton: {
    width: 28,
    height: 28,
    borderRadius: 14,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#F1F5F9',
  },
  filtersRow: {
    minHeight: 48,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'flex-start',
    gap: 8,
    paddingHorizontal: 14,
    paddingVertical: 6,
  },
  filterChip: {
    minHeight: 32,
    borderRadius: 999,
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    paddingHorizontal: 12,
    paddingVertical: 6,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row-reverse',
    gap: 6,
  },
  filterChipActive: {
    backgroundColor: '#2563EB',
    borderColor: '#2563EB',
  },
  filterText: {
    color: '#475569',
    fontSize: 12,
    fontWeight: '900',
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  filterTextActive: {
    color: '#FFFFFF',
  },
  filterCount: {
    minWidth: 22,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#F1F5F9',
    paddingHorizontal: 6,
  },
  filterCountActive: {
    backgroundColor: 'rgba(255,255,255,0.22)',
  },
  filterCountText: {
    color: '#475569',
    fontWeight: '900',
    fontSize: 11,
  },
  filterCountTextActive: {
    color: '#FFFFFF',
  },
  listContent: {
    paddingHorizontal: 14,
    paddingTop: 4,
    paddingBottom: 32,
    gap: 10,
  },
  emptyState: {
    minHeight: 320,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  emptyTitle: {
    marginTop: 12,
    color: '#0F172A',
    fontSize: 18,
    fontWeight: '900',
    textAlign: 'center',
    writingDirection: 'rtl',
  },
  emptySubtitle: {
    marginTop: 6,
    color: '#64748B',
    fontSize: 14,
    textAlign: 'center',
    writingDirection: 'rtl',
    lineHeight: 22,
  },
});
