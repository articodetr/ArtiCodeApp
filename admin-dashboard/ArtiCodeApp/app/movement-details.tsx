import { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  Alert,
  ActivityIndicator,
  Modal,
  TextInput,
} from 'react-native';
import { useRouter, useLocalSearchParams } from 'expo-router';
import { LinearGradient } from 'expo-linear-gradient';
import {
  ArrowRight,
  Trash2,
  Edit3,
  FileText,
  Calendar,
  DollarSign,
  User,
  Hash,
  MessageSquare,
  ArrowDownCircle,
  ArrowUpCircle,
  ArrowLeftRight,
  XCircle,
  Check,
} from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import { AccountMovement, CURRENCIES } from '@/types/database';
import { format } from 'date-fns';
import { ar } from 'date-fns/locale';
import { useAuth } from '@/contexts/AuthContext';
import { fetchAccessibleCustomerById } from '@/services/userScopeService';
import { CustomerStatusBadge } from '@/components/customer/CustomerStatusBadge';
import {
  getMovementApprovalLabel,
  isPendingMovement,
  isRejectedMovement,
  normalizeMovementApprovalStatus,
} from '@/utils/movementApproval';

export default function MovementDetailsScreen() {
  const router = useRouter();
  const { movementId } = useLocalSearchParams();
  const { currentUser } = useAuth();
  const [movement, setMovement] = useState<AccountMovement | null>(null);
  const [customerName, setCustomerName] = useState<string>('');
  const [customerAccountNumber, setCustomerAccountNumber] = useState<string>('');
  const [customerLinkedUserId, setCustomerLinkedUserId] = useState<string | null>(null);
  const [relatedCommissionMovements, setRelatedCommissionMovements] = useState<AccountMovement[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isDeleting, setIsDeleting] = useState(false);
  const [isApproving, setIsApproving] = useState(false);
  const [isRejecting, setIsRejecting] = useState(false);
  const [showRejectModal, setShowRejectModal] = useState(false);
  const [rejectReason, setRejectReason] = useState('');

  useEffect(() => {
    if (movementId && currentUser?.userId) {
      loadMovementDetails();
    }
  }, [movementId, currentUser?.userId]);

  const loadMovementDetails = async () => {
    try {
      setIsLoading(true);

      if (!currentUser?.userId) {
        return;
      }

      const [movementResult, commissionsResult] = await Promise.all([
        supabase
          .from('account_movements')
          .select('*')
          .eq('id', movementId)
          .maybeSingle(),
        supabase
          .from('account_movements')
          .select('*')
          .eq('is_commission_movement', true)
          .eq('related_commission_movement_id', movementId)
      ]);

      if (movementResult.error) throw movementResult.error;

      if (!movementResult.data) {
        Alert.alert('خطأ', 'لم يتم العثور على المعاملة');
        router.back();
        return;
      }

      setMovement(movementResult.data);
      const customerData = await fetchAccessibleCustomerById(
        currentUser.userId,
        movementResult.data.customer_id,
        true,
      );

      if (!customerData) {
        Alert.alert('غير مصرح', 'هذه الحركة غير متاحة للحساب الحالي');
        router.back();
        return;
      }

      setCustomerName(customerData.name);
      setCustomerAccountNumber(customerData.account_number);
      setCustomerLinkedUserId(customerData.linked_user_id || null);

      if (commissionsResult.data) {
        const customerCommissions = commissionsResult.data.filter(
          (c) =>
            c.customer_id === movementResult.data.customer_id &&
            c.movement_type === movementResult.data.movement_type &&
            c.currency === movementResult.data.currency
        );
        setRelatedCommissionMovements(customerCommissions);
      }
    } catch (error) {
      console.error('Error loading movement:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء تحميل البيانات');
      router.back();
    } finally {
      setIsLoading(false);
    }
  };

  const handleDelete = () => {
    if (!movement) return;

    const movementTypeText = movement.movement_type === 'incoming' ? 'له' : 'عليه';
    const currencySymbol = getCurrencySymbol(movement.currency);

    Alert.alert(
      'تأكيد الحذف',
      `هل أنت متأكد من حذف هذه المعاملة؟\n\n${movementTypeText} - ${movement.movement_number}\nالمبلغ: ${Math.round(Number(movement.amount))} ${currencySymbol}\n\nملاحظة: لا يمكن التراجع عن هذا الإجراء`,
      [
        { text: 'إلغاء', style: 'cancel' },
        {
          text: 'حذف',
          style: 'destructive',
          onPress: confirmDelete,
        },
      ]
    );
  };

  const confirmDelete = async () => {
    if (!movement || !currentUser?.userName) return;

    setIsDeleting(true);
    try {
      const { data, error } = await supabase.rpc('void_movement_and_mirror', {
        p_movement_id: movement.id,
        p_user_name: currentUser.userName,
        p_action: 'deleted',
        p_reason: 'تم حذف الحركة من قبل المستخدم',
      });

      if (error) throw error;

      const result = data as any;
      if (!result?.success) {
        throw new Error(result?.error || 'فشل حذف الحركة');
      }

      Alert.alert('نجح', 'تم حذف المعاملة بنجاح', [
        {
          text: 'موافق',
          onPress: () => router.back(),
        },
      ]);
    } catch (error: any) {
      console.error('Error deleting movement:', error);
      Alert.alert('خطأ', error.message || 'حدث خطأ أثناء حذف المعاملة');
    } finally {
      setIsDeleting(false);
    }
  };

  const handleApprove = async () => {
    if (!movement || !currentUser?.userName) return;

    setIsApproving(true);
    try {
      const { error } = await supabase.rpc('approve_movement', {
        p_movement_id: movement.id,
        p_user_name: currentUser.userName,
      });

      if (error) throw error;

      Alert.alert('تم القبول', 'تم اعتماد الحركة، وأصبحت مؤثرة في الإجماليات.', [
        {
          text: 'موافق',
          onPress: () => router.back(),
        },
      ]);
    } catch (error: any) {
      console.error('Error approving movement:', error);
      Alert.alert('خطأ', error.message || 'حدث خطأ أثناء اعتماد الحركة');
    } finally {
      setIsApproving(false);
    }
  };

  const confirmReject = async () => {
    if (!movement || !currentUser?.userName) return;
    if (!rejectReason.trim()) {
      Alert.alert('تنبيه', 'سبب الرفض مطلوب');
      return;
    }

    setIsRejecting(true);
    try {
      const { error } = await supabase.rpc('reject_movement_with_reason', {
        p_movement_id: movement.id,
        p_user_name: currentUser.userName,
        p_reject_reason: rejectReason.trim(),
      });

      if (error) throw error;

      setShowRejectModal(false);
      setRejectReason('');
      Alert.alert('تم الرفض', 'تم رفض الحركة، ولن تؤثر في الإجماليات.', [
        {
          text: 'موافق',
          onPress: () => router.back(),
        },
      ]);
    } catch (error: any) {
      console.error('Error rejecting movement:', error);
      Alert.alert('خطأ', error.message || 'حدث خطأ أثناء رفض الحركة');
    } finally {
      setIsRejecting(false);
    }
  };

  const handleEdit = () => {
    if (!movement) return;

    if (movement.mirror_movement_id && isPendingMovement(movement)) {
      Alert.alert(
        'غير مسموح',
        'لا يمكن تعديل الحركة المعلّقة المرتبطة قبل اعتمادها أو رفضها. احذفها وأعد إنشاؤها إذا لزم الأمر.',
      );
      return;
    }

    router.push({
      pathname: '/edit-movement',
      params: {
        movementId: movement.id,
        customerName: customerName,
        customerAccountNumber: customerAccountNumber,
      },
    });
  };

  const handlePrintReceipt = () => {
    if (!movement) return;

    router.push({
      pathname: '/receipt-preview',
      params: {
        movementId: movement.id,
        customerName: customerName,
        customerAccountNumber: customerAccountNumber,
      },
    });
  };

  const getCurrencySymbol = (code: string): string => {
    const currency = CURRENCIES.find((c) => c.code === code);
    return currency?.symbol || code;
  };

  if (isLoading) {
    return (
      <View style={styles.container}>
        <LinearGradient colors={['#4F46E5', '#6366F1', '#818CF8']} style={styles.gradientHeader}>
          <View style={styles.headerContent}>
            <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
              <ArrowRight size={24} color="#FFFFFF" />
            </TouchableOpacity>
            <Text style={styles.headerTitle}>تفاصيل المعاملة</Text>
            <View style={{ width: 40 }} />
          </View>
        </LinearGradient>
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color="#4F46E5" />
          <Text style={styles.loadingText}>جاري التحميل...</Text>
        </View>
      </View>
    );
  }

  if (!movement) return null;

  const isTransfer = Boolean(movement.transfer_direction);
  const movementTypeText = isTransfer
    ? 'تحويل داخلي'
    : movement.movement_type === 'incoming' ? 'له' : 'عليه';
  const movementTypeColor = isTransfer
    ? '#F59E0B'
    : movement.movement_type === 'incoming' ? '#10B981' : '#EF4444';
  const movementTypeIcon = isTransfer
    ? ArrowLeftRight
    : movement.movement_type === 'incoming' ? ArrowUpCircle : ArrowDownCircle;
  const approvalStatus = normalizeMovementApprovalStatus(movement);
  const isPendingReview = isPendingMovement(movement);
  const isRejected = isRejectedMovement(movement);
  const reviewSourceUserId = (movement as any).source_user_id || (movement as any).created_by_user_id;
  const canReviewPendingMovement =
    isPendingReview &&
    Boolean(currentUser?.userId) &&
    Boolean(reviewSourceUserId) &&
    reviewSourceUserId !== currentUser?.userId;
  const statusText = isPendingReview
    ? getMovementApprovalLabel('pending')
    : isRejected
      ? getMovementApprovalLabel('rejected')
      : getMovementApprovalLabel('approved');
  const statusColor = isPendingReview
    ? '#B45309'
    : isRejected
      ? '#B91C1C'
      : '#15803D';
  const statusBackground = isPendingReview
    ? '#FEF3C7'
    : isRejected
      ? '#FEE2E2'
      : '#DCFCE7';
  const rejectReasonText = (movement as any).void_reason || (movement as any).reject_reason;
  const approvalHint = isPendingReview
    ? 'هذه الحركة بانتظار الموافقة ولن تؤثر في الإجماليات حتى يتم قبولها.'
    : isRejected
      ? 'هذه الحركة مرفوضة ولن تؤثر في الإجماليات.'
      : 'تم اعتماد هذه الحركة وهي مؤثرة الآن في الإجماليات.';

  return (
    <View style={styles.container}>
      <LinearGradient colors={['#4F46E5', '#6366F1', '#818CF8']} style={styles.gradientHeader}>
        <View style={styles.headerContent}>
          <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
            <ArrowRight size={24} color="#FFFFFF" />
          </TouchableOpacity>
          <View style={styles.headerTitleContainer}>
            <Text style={styles.headerTitle}>رقم {movement.movement_number}</Text>
            <Text style={styles.headerSubtitle}>{customerName}</Text>
          </View>
          <View style={{ width: 40 }} />
        </View>
      </LinearGradient>

      <ScrollView style={styles.content}>
        <View style={[styles.typeCard, { backgroundColor: `${movementTypeColor}15` }]}>
          <View style={[styles.typeIconContainer, { backgroundColor: movementTypeColor }]}>
            {isTransfer ? (
              <ArrowLeftRight size={32} color="#FFFFFF" />
            ) : movement.movement_type === 'incoming' ? (
              <ArrowUpCircle size={32} color="#FFFFFF" />
            ) : (
              <ArrowDownCircle size={32} color="#FFFFFF" />
            )}
          </View>
          <Text style={[styles.typeText, { color: movementTypeColor }]}>{movementTypeText}</Text>
          <Text style={styles.typeDescription}>
            {isTransfer
              ? movement.transfer_direction === 'customer_to_customer'
                ? 'تحويل بين عميلين'
                : movement.transfer_direction === 'shop_to_customer'
                ? 'تحويل من المحل للعميل'
                : 'تحويل من العميل للمحل'
              : movement.movement_type === 'incoming'
              ? 'صرف للعميل'
              : 'قبض من العميل'}
          </Text>
          <View style={[styles.statusBadge, { backgroundColor: statusBackground }]}>
            <Text style={[styles.statusBadgeText, { color: statusColor }]}>{statusText}</Text>
          </View>
          <Text style={[styles.approvalHintText, { color: statusColor }]}>
            {approvalHint}
          </Text>
        </View>

        <View style={styles.amountCard}>
          <Text style={styles.amountLabel}>المبلغ الإجمالي</Text>
          <View style={styles.amountRow}>
            <Text style={[styles.amountValue, { color: movementTypeColor }]}>
              {Math.round(
                Number(movement.amount) +
                  relatedCommissionMovements.reduce(
                    (sum, c) => sum + Number(c.amount),
                    0,
                  ),
              )}
            </Text>
            <Text style={[styles.currencyText, { color: movementTypeColor }]}>
              {getCurrencySymbol(movement.currency)}
            </Text>
          </View>
          {relatedCommissionMovements.length > 0 && (
            <View style={styles.amountBreakdown}>
              <Text style={styles.breakdownLabel}>
                المبلغ الأساسي: {Math.round(Number(movement.amount))}{' '}
                {getCurrencySymbol(movement.currency)}
              </Text>
              <Text style={styles.breakdownLabel}>
                العمولة:{' '}
                {Math.round(
                  relatedCommissionMovements.reduce(
                    (sum, c) => sum + Number(c.amount),
                    0,
                  ),
                )}{' '}
                {getCurrencySymbol(movement.currency)}
              </Text>
            </View>
          )}
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>معلومات المعاملة</Text>

          <View style={styles.infoCard}>
            <View style={styles.infoRow}>
              <View style={styles.infoIconContainer}>
                <Hash size={20} color="#6B7280" />
              </View>
              <View style={styles.infoContent}>
                <Text style={styles.infoLabel}>رقم المعاملة</Text>
                <Text style={styles.infoValue}>{movement.movement_number}</Text>
              </View>
            </View>

            {movement.receipt_number && (
              <View style={styles.infoRow}>
                <View style={styles.infoIconContainer}>
                  <FileText size={20} color="#6B7280" />
                </View>
                <View style={styles.infoContent}>
                  <Text style={styles.infoLabel}>رقم السند</Text>
                  <Text style={styles.infoValue}>{movement.receipt_number}</Text>
                </View>
              </View>
            )}

            <View style={styles.infoRow}>
              <View style={styles.infoIconContainer}>
                <Calendar size={20} color="#6B7280" />
              </View>
              <View style={styles.infoContent}>
                <Text style={styles.infoLabel}>التاريخ والوقت</Text>
                <Text style={styles.infoValue}>
                  {format(new Date(movement.created_at), 'dd MMMM yyyy - hh:mm a', { locale: ar })}
                </Text>
              </View>
            </View>

            <View style={styles.infoRow}>
              <View style={styles.infoIconContainer}>
                <User size={20} color="#6B7280" />
              </View>
              <View style={styles.infoContent}>
                <Text style={styles.infoLabel}>العميل</Text>
                <View style={styles.customerValueHeader}>
                  <CustomerStatusBadge linkedUserId={customerLinkedUserId} />
                  <Text style={styles.infoValue}>{customerName}</Text>
                </View>
                <Text style={styles.infoSubValue}>رقم الحساب: {customerAccountNumber}</Text>
              </View>
            </View>

            <View style={styles.infoRow}>
              <View style={styles.infoIconContainer}>
                <DollarSign size={20} color="#6B7280" />
              </View>
              <View style={styles.infoContent}>
                <Text style={styles.infoLabel}>العملة</Text>
                <Text style={styles.infoValue}>
                  {movement.currency} - {getCurrencySymbol(movement.currency)}
                </Text>
              </View>
            </View>

            {movement.commission && Number(movement.commission) > 0 && (
              <View style={styles.infoRow}>
                <View style={styles.infoIconContainer}>
                  <DollarSign size={20} color="#10B981" />
                </View>
                <View style={styles.infoContent}>
                  <Text style={styles.infoLabel}>العمولة</Text>
                  <Text style={[styles.infoValue, { color: '#10B981' }]}>
                    {Math.round(Number(movement.commission))} {getCurrencySymbol(movement.commission_currency || 'YER')}
                  </Text>
                </View>
              </View>
            )}
          </View>
        </View>

        {(movement.sender_name || movement.beneficiary_name) && (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>تفاصيل الحوالة</Text>

            <View style={styles.infoCard}>
              {movement.sender_name && (
                <View style={styles.infoRow}>
                  <View style={styles.infoIconContainer}>
                    <User size={20} color="#6B7280" />
                  </View>
                  <View style={styles.infoContent}>
                    <Text style={styles.infoLabel}>المرسل</Text>
                    <Text style={styles.infoValue}>{movement.sender_name}</Text>
                  </View>
                </View>
              )}

              {movement.beneficiary_name && (
                <View style={styles.infoRow}>
                  <View style={styles.infoIconContainer}>
                    <User size={20} color="#6B7280" />
                  </View>
                  <View style={styles.infoContent}>
                    <Text style={styles.infoLabel}>المستفيد</Text>
                    <Text style={styles.infoValue}>{movement.beneficiary_name}</Text>
                  </View>
                </View>
              )}
            </View>
          </View>
        )}

        {movement.notes && (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>ملاحظات</Text>
            <View style={styles.notesCard}>
              <MessageSquare size={20} color="#6B7280" />
              <Text style={styles.notesText}>{movement.notes}</Text>
            </View>
          </View>
        )}
        {isRejected && rejectReasonText && (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>سبب الرفض</Text>
            <View style={styles.notesCard}>
              <MessageSquare size={20} color="#B91C1C" />
              <Text style={[styles.notesText, { color: '#B91C1C' }]}>{rejectReasonText}</Text>
            </View>
          </View>
        )}

        <View style={styles.actionsSection}>
          <TouchableOpacity style={styles.printButton} onPress={handlePrintReceipt}>
            <FileText size={20} color="#FFFFFF" />
            <Text style={styles.printButtonText}>طباعة السند</Text>
          </TouchableOpacity>

          {canReviewPendingMovement && (
            <TouchableOpacity
              style={[styles.approveButton, isApproving && styles.approveButtonDisabled]}
              onPress={handleApprove}
              disabled={isApproving}
            >
              {isApproving ? (
                <ActivityIndicator size="small" color="#FFFFFF" />
              ) : (
                <>
                  <Check size={20} color="#FFFFFF" />
                  <Text style={styles.approveButtonText}>اعتماد الحركة</Text>
                </>
              )}
            </TouchableOpacity>
          )}

          {canReviewPendingMovement && (
            <TouchableOpacity
              style={[styles.rejectButton, isRejecting && styles.rejectButtonDisabled]}
              onPress={() => setShowRejectModal(true)}
              disabled={isRejecting}
            >
              {isRejecting ? (
                <ActivityIndicator size="small" color="#FFFFFF" />
              ) : (
                <>
                  <XCircle size={20} color="#FFFFFF" />
                  <Text style={styles.rejectButtonText}>رفض الحركة</Text>
                </>
              )}
            </TouchableOpacity>
          )}

          <TouchableOpacity style={styles.editButton} onPress={handleEdit}>
            <Edit3 size={20} color="#FFFFFF" />
            <Text style={styles.editButtonText}>تعديل المعاملة</Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[styles.deleteButton, isDeleting && styles.deleteButtonDisabled]}
            onPress={handleDelete}
            disabled={isDeleting}
          >
            {isDeleting ? (
              <ActivityIndicator size="small" color="#FFFFFF" />
            ) : (
              <Trash2 size={20} color="#FFFFFF" />
            )}
            <Text style={styles.deleteButtonText}>
              {isDeleting ? 'جاري الحذف...' : 'حذف المعاملة'}
            </Text>
          </TouchableOpacity>
        </View>

        <View style={{ height: 40 }} />
      </ScrollView>
      <Modal visible={showRejectModal} transparent animationType="fade" onRequestClose={() => setShowRejectModal(false)}>
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>سبب الرفض</Text>
            <Text style={styles.modalSubtitle}>اكتب سبب الرفض بشكل واضح. لا يمكن تنفيذ الرفض بدون سبب.</Text>
            <TextInput
              style={styles.rejectInput}
              multiline
              value={rejectReason}
              onChangeText={setRejectReason}
              placeholder="اكتب سبب الرفض هنا"
              placeholderTextColor="#9CA3AF"
              textAlign="right"
            />
            <View style={styles.modalActions}>
              <TouchableOpacity style={styles.modalCancelBtn} onPress={() => setShowRejectModal(false)}>
                <Text style={styles.modalCancelText}>إلغاء</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.modalConfirmBtn} onPress={confirmReject} disabled={isRejecting}>
                {isRejecting ? (
                  <ActivityIndicator size="small" color="#FFFFFF" />
                ) : (
                  <Text style={styles.modalConfirmText}>تأكيد الرفض</Text>
                )}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F3F4F6',
  },
  gradientHeader: {
    paddingTop: 16,
    paddingBottom: 24,
  },
  headerContent: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 20,
  },
  backButton: {
    width: 40,
    height: 40,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: 'rgba(255, 255, 255, 0.2)',
    borderRadius: 20,
  },
  headerTitleContainer: {
    alignItems: 'center',
  },
  headerTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#FFFFFF',
    textAlign: 'center',
  },
  headerSubtitle: {
    fontSize: 14,
    color: 'rgba(255, 255, 255, 0.9)',
    marginTop: 4,
  },
  content: {
    flex: 1,
  },
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    gap: 16,
  },
  loadingText: {
    fontSize: 16,
    color: '#6B7280',
  },
  typeCard: {
    margin: 20,
    marginBottom: 0,
    padding: 24,
    borderRadius: 16,
    alignItems: 'center',
  },
  typeIconContainer: {
    width: 64,
    height: 64,
    borderRadius: 32,
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 12,
  },
  typeText: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 4,
  },
  typeDescription: {
    fontSize: 14,
    color: '#6B7280',
  },
  statusBadge: {
    marginTop: 10,
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 999,
  },
  statusBadgeText: {
    fontSize: 12,
    fontWeight: '700',
  },
  approvalHintText: {
    marginTop: 10,
    fontSize: 13,
    fontWeight: '600',
    textAlign: 'center',
    lineHeight: 20,
  },
  amountCard: {
    backgroundColor: '#FFFFFF',
    margin: 20,
    marginTop: 16,
    padding: 24,
    borderRadius: 16,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 8,
    elevation: 3,
  },
  amountLabel: {
    fontSize: 14,
    color: '#6B7280',
    marginBottom: 8,
  },
  amountRow: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: 8,
  },
  amountValue: {
    fontSize: 42,
    fontWeight: 'bold',
  },
  currencyText: {
    fontSize: 24,
    fontWeight: '600',
  },
  amountBreakdown: {
    marginTop: 16,
    paddingTop: 16,
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
    width: '100%',
  },
  breakdownLabel: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'center',
    marginBottom: 4,
  },
  section: {
    marginHorizontal: 20,
    marginBottom: 20,
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 12,
    textAlign: 'right',
  },
  infoCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    padding: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.05,
    shadowRadius: 4,
    elevation: 2,
  },
  infoRow: {
    flexDirection: 'row',
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  infoIconContainer: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: '#F3F4F6',
    justifyContent: 'center',
    alignItems: 'center',
    marginLeft: 12,
  },
  infoContent: {
    flex: 1,
    justifyContent: 'center',
  },
  customerValueHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    gap: 8,
    flexWrap: 'wrap',
  },
  infoLabel: {
    fontSize: 13,
    color: '#6B7280',
    marginBottom: 4,
    textAlign: 'right',
  },
  infoValue: {
    fontSize: 15,
    fontWeight: '600',
    color: '#111827',
    textAlign: 'right',
  },
  infoSubValue: {
    fontSize: 13,
    color: '#9CA3AF',
    marginTop: 2,
    textAlign: 'right',
  },
  notesCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    padding: 16,
    flexDirection: 'row',
    gap: 12,
    alignItems: 'flex-start',
  },
  notesText: {
    flex: 1,
    fontSize: 15,
    color: '#374151',
    lineHeight: 22,
    textAlign: 'right',
  },
  actionsSection: {
    marginHorizontal: 20,
    gap: 12,
  },
  printButton: {
    backgroundColor: '#10B981',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  printButtonText: {
    fontSize: 17,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  approveButton: {
    backgroundColor: '#10B981',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  approveButtonDisabled: {
    opacity: 0.6,
  },
  approveButtonText: {
    fontSize: 17,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  editButton: {
    backgroundColor: '#3B82F6',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  editButtonText: {
    fontSize: 17,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  deleteButton: {
    backgroundColor: '#EF4444',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  deleteButtonDisabled: {
    opacity: 0.6,
  },
  deleteButtonText: {
    fontSize: 17,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  rejectButton: {
    backgroundColor: '#F59E0B',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  rejectButtonDisabled: {
    opacity: 0.6,
  },
  rejectButtonText: {
    fontSize: 17,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.4)',
    justifyContent: 'center',
    padding: 20,
  },
  modalContent: {
    backgroundColor: '#FFFFFF',
    borderRadius: 16,
    padding: 18,
  },
  modalTitle: {
    fontSize: 18,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'right',
    marginBottom: 8,
  },
  modalSubtitle: {
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
    marginBottom: 12,
    lineHeight: 20,
  },
  rejectInput: {
    minHeight: 110,
    borderWidth: 1,
    borderColor: '#D1D5DB',
    borderRadius: 12,
    padding: 12,
    textAlignVertical: 'top',
    fontSize: 14,
    color: '#111827',
  },
  modalActions: {
    flexDirection: 'row',
    gap: 10,
    marginTop: 12,
  },
  modalCancelBtn: {
    flex: 1,
    borderRadius: 12,
    backgroundColor: '#F3F4F6',
    paddingVertical: 12,
    alignItems: 'center',
  },
  modalCancelText: {
    color: '#374151',
    fontWeight: '700',
  },
  modalConfirmBtn: {
    flex: 1,
    borderRadius: 12,
    backgroundColor: '#EF4444',
    paddingVertical: 12,
    alignItems: 'center',
  },
  modalConfirmText: {
    color: '#FFFFFF',
    fontWeight: '800',
  },
});
