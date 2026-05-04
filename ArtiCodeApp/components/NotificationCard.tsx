import { useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Modal,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { Check, Clock, Trash2, X } from 'lucide-react-native';

import {
  CurrentUserLike,
  getNotificationMeta,
  MovementNotification,
} from '../services/notificationService';

interface NotificationCardProps {
  notification: MovementNotification;
  currentUser?: CurrentUserLike | null;
  onPress: () => void;
  onDelete: (item: MovementNotification) => void | Promise<void>;
  onAccept?: (item: MovementNotification) => void | Promise<void>;
  onReject?: (item: MovementNotification, reason: string) => void | Promise<void>;
  isDeleting?: boolean;
  isProcessing?: boolean;
  showCustomer?: boolean;
  unreadColor?: string;
}

function formatArabicDateTime(value?: string | null) {
  if (!value) return '';

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';

  const day = String(date.getDate()).padStart(2, '0');
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const year = date.getFullYear();
  const hours = date.getHours();
  const minutes = String(date.getMinutes()).padStart(2, '0');
  const period = hours >= 12 ? 'م' : 'ص';
  const displayHours = String(hours % 12 || 12).padStart(2, '0');

  return `${day}/${month}/${year} - ${displayHours}:${minutes} ${period}`;
}

function hasUsefulText(value?: string | null) {
  const text = String(value || '').trim();

  return Boolean(text && text !== 'لا توجد ملاحظة' && text !== 'null' && text !== 'undefined');
}

export default function NotificationCard({
  notification,
  currentUser,
  onPress,
  onDelete,
  onAccept,
  onReject,
  isDeleting = false,
  isProcessing = false,
  unreadColor = '#2563EB',
}: NotificationCardProps) {
  const [showRejectModal, setShowRejectModal] = useState(false);
  const [rejectReason, setRejectReason] = useState('');

  const meta = getNotificationMeta(notification, currentUser);
  const canUseQuickAction = meta.canTakeAction && Boolean(onAccept && onReject);
  const createdAtText = formatArabicDateTime(notification.created_at);
  const noteText = String(meta.noteText || '').trim();
  const rejectReasonText = String(meta.rejectReason || '').trim();

  const handleAcceptPress = () => {
    if (!onAccept || isProcessing) return;

    Alert.alert(
      'قبول الحركة',
      'هل تريد قبول هذه الحركة واعتمادها؟ بعد القبول ستدخل الحركة في الإجماليات.',
      [
        { text: 'إلغاء', style: 'cancel' },
        {
          text: 'قبول',
          onPress: async () => {
            try {
              await onAccept(notification);
              Alert.alert('تم القبول', 'تم اعتماد الحركة بنجاح.');
            } catch (error: any) {
              Alert.alert('خطأ', error?.message || 'تعذر قبول الحركة');
            }
          },
        },
      ],
    );
  };

  const handleRejectConfirm = async () => {
    if (!onReject || isProcessing) return;

    const trimmedReason = rejectReason.trim();

    if (!trimmedReason) {
      Alert.alert('تنبيه', 'يرجى كتابة سبب الرفض');
      return;
    }

    try {
      await onReject(notification, trimmedReason);
      setShowRejectModal(false);
      setRejectReason('');
      Alert.alert('تم الرفض', 'تم رفض الحركة وحفظ سبب الرفض.');
    } catch (error: any) {
      Alert.alert('خطأ', error?.message || 'تعذر رفض الحركة');
    }
  };

  return (
    <>
      <TouchableOpacity
        style={[
          styles.notificationCard,
          {
            backgroundColor: meta.rowBg,
            borderColor: meta.rowBorderColor,
          },
          meta.isUnread && { borderColor: unreadColor },
          meta.isUnread && styles.unreadCard,
        ]}
        onPress={onPress}
        activeOpacity={0.82}
      >
        <View style={styles.cardTopRow}>
          <View style={styles.titleWrap}>
            <View style={styles.titleRow}>
              {meta.isUnread && (
                <View style={[styles.unreadDot, { backgroundColor: unreadColor }]} />
              )}

              <Text style={styles.cardTitle} numberOfLines={2}>
                {meta.title}
              </Text>
            </View>

            <Text style={styles.cardSubtitle} numberOfLines={1}>
              {meta.subtitle}
            </Text>
          </View>

          <TouchableOpacity
            style={styles.deleteButton}
            onPress={() => onDelete(notification)}
            disabled={isDeleting || isProcessing}
            hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          >
            {isDeleting ? (
              <ActivityIndicator size="small" color="#64748B" />
            ) : (
              <Trash2 size={16} color="#94A3B8" />
            )}
          </TouchableOpacity>
        </View>

        {hasUsefulText(noteText) && (
          <Text style={styles.noteLine} numberOfLines={2}>
            <Text style={styles.noteLabel}>ملاحظة: </Text>
            {noteText}
          </Text>
        )}

        {hasUsefulText(rejectReasonText) && (
          <Text style={styles.reasonLine} numberOfLines={2}>
            <Text style={styles.reasonLabel}>سبب الرفض: </Text>
            {rejectReasonText}
          </Text>
        )}

        <View style={styles.cardFooter}>
          <View style={[styles.statusBadge, { backgroundColor: meta.statusBg }]}>
            <Text style={[styles.statusText, { color: meta.statusColor }]}>
              {meta.statusText}
            </Text>
          </View>

          {!!createdAtText && (
            <View style={styles.dateWrap}>
              <Clock size={13} color="#94A3B8" />
              <Text style={styles.dateText}>{createdAtText}</Text>
            </View>
          )}
        </View>

        {canUseQuickAction && (
          <View style={styles.quickActionsRow}>
            <TouchableOpacity
              style={[
                styles.acceptButton,
                isProcessing && styles.disabledButton,
              ]}
              onPress={handleAcceptPress}
              disabled={isProcessing}
              activeOpacity={0.85}
            >
              {isProcessing ? (
                <ActivityIndicator size="small" color="#FFFFFF" />
              ) : (
                <Check size={17} color="#FFFFFF" />
              )}
              <Text style={styles.acceptButtonText}>قبول واعتماد</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={[
                styles.rejectButton,
                isProcessing && styles.disabledButton,
              ]}
              onPress={() => setShowRejectModal(true)}
              disabled={isProcessing}
              activeOpacity={0.85}
            >
              <X size={17} color="#FFFFFF" />
              <Text style={styles.rejectButtonText}>رفض</Text>
            </TouchableOpacity>
          </View>
        )}
      </TouchableOpacity>

      <Modal
        visible={showRejectModal}
        transparent
        animationType="fade"
        onRequestClose={() => setShowRejectModal(false)}
      >
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>سبب رفض الحركة</Text>
            <Text style={styles.modalSubtitle}>
              اكتب السبب بشكل واضح حتى يظهر للطرف الآخر.
            </Text>

            <TextInput
              style={styles.rejectInput}
              placeholder="مثال: المبلغ غير صحيح أو لا يخصني"
              placeholderTextColor="#94A3B8"
              value={rejectReason}
              onChangeText={setRejectReason}
              multiline
              textAlign="right"
            />

            <View style={styles.modalActions}>
              <TouchableOpacity
                style={styles.modalCancelButton}
                onPress={() => {
                  setShowRejectModal(false);
                  setRejectReason('');
                }}
                disabled={isProcessing}
              >
                <Text style={styles.modalCancelText}>إلغاء</Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[
                  styles.modalConfirmButton,
                  isProcessing && styles.disabledButton,
                ]}
                onPress={handleRejectConfirm}
                disabled={isProcessing}
              >
                {isProcessing ? (
                  <ActivityIndicator size="small" color="#FFFFFF" />
                ) : (
                  <Text style={styles.modalConfirmText}>تأكيد الرفض</Text>
                )}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  notificationCard: {
    borderRadius: 14,
    borderWidth: 1,
    padding: 10,
    shadowColor: '#000000',
    shadowOpacity: 0.025,
    shadowRadius: 5,
    shadowOffset: { width: 0, height: 2 },
    elevation: 1,
  },
  unreadCard: {
    borderWidth: 1.4,
  },
  cardTopRow: {
    flexDirection: 'row-reverse',
    alignItems: 'flex-start',
    gap: 8,
  },
  titleWrap: {
    flex: 1,
    alignItems: 'stretch',
  },
  titleRow: {
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'flex-start',
    gap: 6,
  },
  unreadDot: {
    width: 7,
    height: 7,
    borderRadius: 3.5,
  },
  cardTitle: {
    flex: 1,
    color: '#0F172A',
    fontSize: 15,
    fontWeight: '900',
    textAlign: 'right',
    writingDirection: 'rtl',
    lineHeight: 21,
  },
  cardSubtitle: {
    color: '#64748B',
    fontSize: 12,
    lineHeight: 18,
    textAlign: 'right',
    writingDirection: 'rtl',
    marginTop: 3,
    fontWeight: '700',
  },
  deleteButton: {
    width: 30,
    height: 30,
    borderRadius: 10,
    backgroundColor: '#F8FAFC',
    alignItems: 'center',
    justifyContent: 'center',
  },
  noteLine: {
    marginTop: 7,
    color: '#334155',
    fontSize: 12.5,
    fontWeight: '600',
    lineHeight: 19,
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  noteLabel: {
    color: '#0F172A',
    fontWeight: '900',
  },
  reasonLine: {
    marginTop: 6,
    color: '#991B1B',
    fontSize: 12.5,
    fontWeight: '700',
    lineHeight: 19,
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  reasonLabel: {
    color: '#7F1D1D',
    fontWeight: '900',
  },
  cardFooter: {
    marginTop: 8,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 8,
  },
  statusBadge: {
    borderRadius: 999,
    paddingHorizontal: 9,
    paddingVertical: 4,
  },
  statusText: {
    fontSize: 11,
    fontWeight: '900',
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  dateWrap: {
    flex: 1,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'flex-start',
    gap: 4,
  },
  dateText: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '700',
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  quickActionsRow: {
    marginTop: 10,
    flexDirection: 'row-reverse',
    gap: 8,
  },
  acceptButton: {
    flex: 1,
    minHeight: 40,
    backgroundColor: '#059669',
    borderRadius: 12,
    paddingVertical: 9,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row-reverse',
    gap: 6,
  },
  rejectButton: {
    flex: 1,
    minHeight: 40,
    backgroundColor: '#DC2626',
    borderRadius: 12,
    paddingVertical: 9,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row-reverse',
    gap: 6,
  },
  acceptButtonText: {
    color: '#FFFFFF',
    fontSize: 13.5,
    fontWeight: '900',
    textAlign: 'center',
    writingDirection: 'rtl',
  },
  rejectButtonText: {
    color: '#FFFFFF',
    fontSize: 13.5,
    fontWeight: '900',
    textAlign: 'center',
    writingDirection: 'rtl',
  },
  disabledButton: {
    opacity: 0.65,
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(15, 23, 42, 0.45)',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 22,
  },
  modalContent: {
    width: '100%',
    borderRadius: 20,
    backgroundColor: '#FFFFFF',
    padding: 18,
  },
  modalTitle: {
    color: '#0F172A',
    fontSize: 19,
    fontWeight: '900',
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  modalSubtitle: {
    marginTop: 6,
    color: '#64748B',
    fontSize: 13,
    fontWeight: '700',
    lineHeight: 20,
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  rejectInput: {
    marginTop: 14,
    minHeight: 95,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#CBD5E1',
    padding: 12,
    color: '#0F172A',
    fontSize: 14,
    textAlign: 'right',
    writingDirection: 'rtl',
    textAlignVertical: 'top',
  },
  modalActions: {
    marginTop: 14,
    flexDirection: 'row-reverse',
    gap: 10,
  },
  modalCancelButton: {
    flex: 1,
    borderRadius: 12,
    backgroundColor: '#F1F5F9',
    paddingVertical: 12,
    alignItems: 'center',
  },
  modalCancelText: {
    color: '#334155',
    fontSize: 14,
    fontWeight: '900',
    textAlign: 'center',
    writingDirection: 'rtl',
  },
  modalConfirmButton: {
    flex: 1,
    borderRadius: 12,
    backgroundColor: '#DC2626',
    paddingVertical: 12,
    alignItems: 'center',
  },
  modalConfirmText: {
    color: '#FFFFFF',
    fontSize: 14,
    fontWeight: '900',
    textAlign: 'center',
    writingDirection: 'rtl',
  },
});
