import { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TextInput,
  TouchableOpacity,
  ScrollView,
  Alert,
  Modal,
  ActivityIndicator,
} from 'react-native';
import { useRouter, useLocalSearchParams } from 'expo-router';
import { ArrowRight, Save, ArrowDownCircle, ArrowUpCircle, CheckCircle, X, FileText } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { supabase } from '@/lib/supabase';
import { Currency, CURRENCIES, AccountMovement } from '@/types/database';
import { KeyboardAwareView } from '@/components/KeyboardAwareView';
import { useDataRefresh } from '@/contexts/DataRefreshContext';
import { useAuth } from '@/contexts/AuthContext';
import { fetchAccessibleCustomerById } from '@/services/userScopeService';
import { CustomerStatusBadge } from '@/components/customer/CustomerStatusBadge';
import { isPendingMovement } from '@/utils/movementApproval';

export default function EditMovementScreen() {
  const router = useRouter();
  const { triggerRefresh } = useDataRefresh();
  const { currentUser } = useAuth();
  const insets = useSafeAreaInsets();
  const { movementId, customerName: initialCustomerName, customerAccountNumber } = useLocalSearchParams();
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [showCurrencyPicker, setShowCurrencyPicker] = useState(false);
  const [showSuccessModal, setShowSuccessModal] = useState(false);
  const [originalMovement, setOriginalMovement] = useState<AccountMovement | null>(null);

  const [formData, setFormData] = useState({
    customer_id: '',
    customer_name: '',
    customer_account_number: '',
    customer_linked_user_id: '',
    movement_type: '' as 'incoming' | 'outgoing' | '',
    amount: '',
    commission: '',
    commission_currency: 'USD' as Currency,
    currency: 'USD' as Currency,
    notes: '',
    sender_name: '',
    beneficiary_name: '',
    transfer_number: '',
  });

  useEffect(() => {
    if (movementId && currentUser?.userId) {
      loadMovement();
    }
  }, [movementId, currentUser?.userId]);

  useEffect(() => {
    setFormData((prev) => ({
      ...prev,
      commission_currency: prev.currency,
    }));
  }, [formData.currency]);

  const loadMovement = async () => {
    try {
      setIsLoading(true);

      if (!currentUser?.userId) {
        return;
      }

      const { data, error } = await supabase
        .from('account_movements')
        .select('*')
        .eq('id', movementId)
        .maybeSingle();

      if (error) throw error;

      if (!data) {
        Alert.alert('خطأ', 'لم يتم العثور على المعاملة');
        router.back();
        return;
      }

      setOriginalMovement(data);

      const customerData = await fetchAccessibleCustomerById(
        currentUser.userId,
        data.customer_id,
        true,
      );

      if (!customerData) {
        Alert.alert('غير مصرح', 'هذه الحركة غير متاحة للحساب الحالي');
        router.back();
        return;
      }

      setFormData({
        customer_id: data.customer_id,
        customer_name: customerData.name || (initialCustomerName as string) || '',
        customer_account_number: customerData.account_number || (customerAccountNumber as string) || '',
        customer_linked_user_id: customerData.linked_user_id || '',
        movement_type: data.movement_type,
        amount: data.amount.toString(),
        commission: data.commission ? data.commission.toString() : '',
        commission_currency: (data.commission_currency as Currency) || 'YER',
        currency: data.currency as Currency,
        notes: data.notes || '',
        sender_name: data.sender_name || '',
        beneficiary_name: data.beneficiary_name || '',
        transfer_number: data.transfer_number || '',
      });
    } catch (error) {
      console.error('Error loading movement:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء تحميل البيانات');
      router.back();
    } finally {
      setIsLoading(false);
    }
  };

  const handleSubmit = async () => {
    if (!formData.customer_id || !formData.movement_type || !formData.amount) {
      Alert.alert('خطأ', 'الرجاء إدخال جميع البيانات المطلوبة');
      return;
    }

    if (!formData.notes.trim()) {
      Alert.alert('خطأ', 'الملاحظة مطلوبة لكل حركة');
      return;
    }

    if (originalMovement?.mirror_movement_id && isPendingMovement(originalMovement)) {
      Alert.alert(
        'غير مسموح',
        'لا يمكن تعديل الحركة المعلّقة المرتبطة قبل اعتمادها أو رفضها. احذفها وأعد إنشاؤها إذا لزم الأمر.',
      );
      return;
    }

    setIsSaving(true);
    try {
      const { error } = await supabase
        .from('account_movements')
        .update({
          movement_type: formData.movement_type,
          amount: Number(formData.amount),
          currency: formData.currency,
          commission: null,
          commission_currency: null,
          notes: formData.notes.trim(),
          sender_name: formData.sender_name.trim() || null,
          beneficiary_name: formData.beneficiary_name.trim() || null,
          transfer_number: formData.transfer_number.trim() || null,
        })
        .eq('id', movementId);

      if (error) throw error;

      triggerRefresh('movements');
      setShowSuccessModal(true);
    } catch (error) {
      console.error('Error updating movement:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء تحديث الحركة');
    } finally {
      setIsSaving(false);
    }
  };

  const handleOpenReceipt = () => {
    setShowSuccessModal(false);
    router.push({
      pathname: '/receipt-preview',
      params: {
        movementId: movementId,
        customerName: formData.customer_name,
        customerAccountNumber: formData.customer_account_number,
      },
    });
  };

  const handleCloseSuccessModal = () => {
    setShowSuccessModal(false);
    router.back();
  };

  const selectCurrency = (currency: Currency) => {
    setFormData({ ...formData, currency });
    setShowCurrencyPicker(false);
  };

  const getCurrencySymbol = (code: string) => {
    const currency = CURRENCIES.find((c) => c.code === code);
    return currency?.symbol || code;
  };

  if (isLoading) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
            <ArrowRight size={24} color="#111827" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>تعديل الحركة المالية</Text>
          <View style={{ width: 40 }} />
        </View>
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color="#4F46E5" />
          <Text style={styles.loadingText}>جاري التحميل...</Text>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>تعديل الحركة المالية</Text>
        <View style={{ width: 40 }} />
      </View>

      <KeyboardAwareView
        contentContainerStyle={styles.contentContainer}
        extraScrollHeight={180}
      >
          <View style={styles.customerCard}>
            <Text style={styles.customerLabel}>العميل</Text>
            <View style={styles.customerValueHeader}>
              <CustomerStatusBadge
                linkedUserId={formData.customer_linked_user_id}
              />
              <Text style={styles.customerValue}>{formData.customer_name}</Text>
            </View>
            {formData.customer_account_number && (
              <Text style={styles.customerAccountText}>
                رقم الحساب: {formData.customer_account_number}
              </Text>
            )}
            <Text style={styles.customerNote}>لا يمكن تغيير العميل عند التعديل</Text>
          </View>

          <View style={styles.movementTypeSection}>
            <Text style={styles.sectionTitle}>
              نوع الحركة <Text style={styles.required}>*</Text>
            </Text>
            <View style={styles.movementTypeButtons}>
              <TouchableOpacity
                style={[
                  styles.movementTypeButton,
                  formData.movement_type === 'outgoing' && styles.movementTypeButtonActive,
                  { backgroundColor: formData.movement_type === 'outgoing' ? '#EF4444' : '#F3F4F6' },
                ]}
                onPress={() => setFormData({ ...formData, movement_type: 'outgoing' })}
              >
                <ArrowDownCircle
                  size={32}
                  color={formData.movement_type === 'outgoing' ? '#FFFFFF' : '#6B7280'}
                />
                <Text
                  style={[
                    styles.movementTypeButtonText,
                    { color: formData.movement_type === 'outgoing' ? '#FFFFFF' : '#6B7280' },
                  ]}
                >
                  عليه
                </Text>
                <Text
                  style={[
                    styles.movementTypeButtonSubtext,
                    { color: formData.movement_type === 'outgoing' ? '#FECACA' : '#9CA3AF' },
                  ]}
                >
                  العميل دفع لك
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[
                  styles.movementTypeButton,
                  formData.movement_type === 'incoming' && styles.movementTypeButtonActive,
                  { backgroundColor: formData.movement_type === 'incoming' ? '#10B981' : '#F3F4F6' },
                ]}
                onPress={() => setFormData({ ...formData, movement_type: 'incoming' })}
              >
                <ArrowUpCircle
                  size={32}
                  color={formData.movement_type === 'incoming' ? '#FFFFFF' : '#6B7280'}
                />
                <Text
                  style={[
                    styles.movementTypeButtonText,
                    { color: formData.movement_type === 'incoming' ? '#FFFFFF' : '#6B7280' },
                  ]}
                >
                  له
                </Text>
                <Text
                  style={[
                    styles.movementTypeButtonSubtext,
                    { color: formData.movement_type === 'incoming' ? '#D1FAE5' : '#9CA3AF' },
                  ]}
                >
                  أنت أرسلت له
                </Text>
              </TouchableOpacity>
            </View>
          </View>

          <View style={styles.amountSection}>
            <Text style={styles.sectionTitle}>
              المبلغ <Text style={styles.required}>*</Text>
            </Text>
            <View style={styles.amountRow}>
              <TouchableOpacity
                style={styles.currencyButton}
                onPress={() => setShowCurrencyPicker(true)}
              >
                <Text style={styles.currencyButtonText}>{formData.currency}</Text>
                <Text style={styles.currencySymbol}>{getCurrencySymbol(formData.currency)}</Text>
              </TouchableOpacity>
              <TextInput
                style={styles.amountInput}
                value={formData.amount}
                onChangeText={(text) => setFormData({ ...formData, amount: text })}
                placeholder="0.00"
                placeholderTextColor="#9CA3AF"
                keyboardType="decimal-pad"
                textAlign="center"
              />
            </View>
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>عمولة الحوالة (اختياري)</Text>
            <View style={styles.commissionRow}>
              <View style={styles.commissionCurrencyDisplay}>
                <Text style={styles.commissionCurrencyText}>{formData.commission_currency}</Text>
                <Text style={styles.commissionCurrencySymbol}>
                  {getCurrencySymbol(formData.commission_currency)}
                </Text>
              </View>
              <TextInput
                style={styles.commissionInput}
                value={formData.commission}
                onChangeText={(text) => setFormData({ ...formData, commission: text })}
                placeholder="0.00"
                placeholderTextColor="#9CA3AF"
                keyboardType="decimal-pad"
                textAlign="right"
              />
            </View>
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>اسم المرسل</Text>
            <TextInput
              style={styles.input}
              value={formData.sender_name}
              onChangeText={(text) => setFormData({ ...formData, sender_name: text })}
              placeholder="اسم المرسل"
              placeholderTextColor="#9CA3AF"
              textAlign="right"
            />
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>اسم المستفيد</Text>
            <TextInput
              style={styles.input}
              value={formData.beneficiary_name}
              onChangeText={(text) => setFormData({ ...formData, beneficiary_name: text })}
              placeholder="اسم المستفيد (اختياري)"
              placeholderTextColor="#9CA3AF"
              textAlign="right"
            />
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>رقم الحوالة</Text>
            <TextInput
              style={styles.input}
              value={formData.transfer_number}
              onChangeText={(text) => setFormData({ ...formData, transfer_number: text })}
              placeholder="رقم الحوالة (اختياري)"
              placeholderTextColor="#9CA3AF"
              textAlign="right"
            />
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>ملاحظات <Text style={styles.required}>*</Text></Text>
            <TextInput
              style={[styles.input, styles.textArea]}
              value={formData.notes}
              onChangeText={(text) => setFormData({ ...formData, notes: text })}
              placeholder="أدخل ملاحظة توضح سبب الحركة"
              placeholderTextColor="#9CA3AF"
              multiline
              numberOfLines={3}
              textAlign="right"
              textAlignVertical="top"
            />
          </View>

          <TouchableOpacity
            style={[styles.submitButton, isSaving && styles.submitButtonDisabled]}
            onPress={handleSubmit}
            disabled={isSaving}
          >
            <Save size={20} color="#FFFFFF" />
            <Text style={styles.submitButtonText}>
              {isSaving ? 'جاري الحفظ...' : 'حفظ التعديلات'}
            </Text>
          </TouchableOpacity>
      </KeyboardAwareView>

      <Modal
        visible={showCurrencyPicker}
        animationType="slide"
        transparent={true}
        onRequestClose={() => setShowCurrencyPicker(false)}
      >
        <View style={styles.modalContainer}>
          <View
            style={[
              styles.modalContent,
              { paddingBottom: Math.max(insets.bottom, 20) },
            ]}
          >
            <Text style={styles.modalTitle}>اختر عملة</Text>
            <ScrollView
              style={styles.modalList}
              contentContainerStyle={{
                paddingBottom: Math.max(insets.bottom + 12, 20),
              }}
            >
              {CURRENCIES.map((currency) => (
                <TouchableOpacity
                  key={currency.code}
                  style={styles.modalItem}
                  onPress={() => selectCurrency(currency.code)}
                >
                  <Text style={styles.modalItemText}>
                    {currency.code} - {currency.name}
                  </Text>
                  <Text style={styles.modalItemSubtext}>{currency.symbol}</Text>
                </TouchableOpacity>
              ))}
            </ScrollView>
            <TouchableOpacity
              style={styles.modalCloseButton}
              onPress={() => setShowCurrencyPicker(false)}
            >
              <Text style={styles.modalCloseButtonText}>إغلاق</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>

      <Modal
        visible={showSuccessModal}
        animationType="fade"
        transparent={true}
        onRequestClose={handleCloseSuccessModal}
      >
        <View style={styles.successModalContainer}>
          <View style={styles.successModalCard}>
            <View style={styles.successIconContainer}>
              <CheckCircle size={64} color="#10B981" />
            </View>
            <Text style={styles.successTitle}>تم التحديث بنجاح</Text>
            <Text style={styles.successSubtitle}>تم تحديث الحركة المالية بنجاح</Text>

            <View style={styles.successButtonsContainer}>
              <TouchableOpacity style={styles.openReceiptButton} onPress={handleOpenReceipt}>
                <FileText size={20} color="#FFFFFF" />
                <Text style={styles.openReceiptButtonText}>فتح السند</Text>
              </TouchableOpacity>

              <TouchableOpacity style={styles.closeModalButton} onPress={handleCloseSuccessModal}>
                <X size={20} color="#6B7280" />
                <Text style={styles.closeModalButtonText}>إغلاق</Text>
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
    backgroundColor: '#F9FAFB',
  },
  header: {
    backgroundColor: '#FFFFFF',
    paddingTop: 16,
    paddingHorizontal: 20,
    paddingBottom: 16,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  backButton: {
    width: 40,
    height: 40,
    justifyContent: 'center',
    alignItems: 'center',
  },
  headerTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
  },
  contentContainer: {
    padding: 20,
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
  customerCard: {
    backgroundColor: '#F0FDF4',
    borderRadius: 12,
    padding: 16,
    marginBottom: 20,
    borderWidth: 2,
    borderColor: '#10B981',
  },
  customerLabel: {
    fontSize: 14,
    fontWeight: '600',
    color: '#6B7280',
    marginBottom: 8,
    textAlign: 'right',
  },
  customerValue: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#111827',
    textAlign: 'right',
    flexShrink: 1,
  },
  customerValueHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    gap: 8,
    flexWrap: 'wrap',
  },
  customerAccountText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#10B981',
    marginTop: 6,
    textAlign: 'right',
  },
  customerNote: {
    fontSize: 12,
    color: '#6B7280',
    marginTop: 8,
    textAlign: 'right',
    fontStyle: 'italic',
  },
  required: {
    color: '#EF4444',
  },
  movementTypeSection: {
    marginBottom: 20,
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: '600',
    color: '#374151',
    marginBottom: 12,
    textAlign: 'right',
  },
  movementTypeButtons: {
    flexDirection: 'row',
    gap: 12,
  },
  movementTypeButton: {
    flex: 1,
    borderRadius: 16,
    padding: 20,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 120,
  },
  movementTypeButtonActive: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.15,
    shadowRadius: 12,
    elevation: 6,
  },
  movementTypeButtonText: {
    fontSize: 18,
    fontWeight: 'bold',
    marginTop: 12,
    marginBottom: 4,
  },
  movementTypeButtonSubtext: {
    fontSize: 14,
  },
  amountSection: {
    marginBottom: 20,
  },
  amountRow: {
    flexDirection: 'row',
    gap: 12,
  },
  currencyButton: {
    backgroundColor: '#4F46E5',
    borderRadius: 12,
    padding: 16,
    width: 100,
    alignItems: 'center',
  },
  currencyButtonText: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#FFFFFF',
    marginBottom: 4,
  },
  currencySymbol: {
    fontSize: 14,
    color: '#E0E7FF',
  },
  amountInput: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 12,
    paddingHorizontal: 16,
    fontSize: 24,
    fontWeight: 'bold',
    color: '#111827',
  },
  inputGroup: {
    marginBottom: 20,
  },
  label: {
    fontSize: 16,
    fontWeight: '600',
    color: '#374151',
    marginBottom: 8,
    textAlign: 'right',
  },
  input: {
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 14,
    fontSize: 16,
    color: '#111827',
  },
  commissionRow: {
    flexDirection: 'row',
    gap: 12,
  },
  commissionCurrencyDisplay: {
    backgroundColor: '#4F46E5',
    borderRadius: 12,
    padding: 16,
    width: 100,
    alignItems: 'center',
    justifyContent: 'center',
  },
  commissionCurrencyText: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#FFFFFF',
    marginBottom: 4,
  },
  commissionCurrencySymbol: {
    fontSize: 12,
    color: '#E0E7FF',
  },
  commissionInput: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 14,
    fontSize: 16,
    color: '#111827',
  },
  textArea: {
    height: 80,
    paddingTop: 14,
  },
  submitButton: {
    backgroundColor: '#4F46E5',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
    marginTop: 12,
  },
  submitButtonDisabled: {
    opacity: 0.6,
  },
  submitButtonText: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  modalContainer: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    justifyContent: 'flex-end',
  },
  modalContent: {
    backgroundColor: '#FFFFFF',
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    padding: 20,
    maxHeight: '80%',
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 16,
    textAlign: 'center',
  },
  modalList: {
    maxHeight: 400,
  },
  modalItem: {
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  modalItemText: {
    fontSize: 16,
    fontWeight: '600',
    color: '#111827',
    marginBottom: 4,
    textAlign: 'right',
  },
  modalItemSubtext: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'right',
  },
  modalCloseButton: {
    backgroundColor: '#F3F4F6',
    borderRadius: 12,
    paddingVertical: 16,
    marginTop: 16,
  },
  modalCloseButtonText: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#374151',
    textAlign: 'center',
  },
  successModalContainer: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.6)',
    justifyContent: 'center',
    alignItems: 'center',
    padding: 20,
  },
  successModalCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 24,
    padding: 32,
    width: '100%',
    maxWidth: 400,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 10 },
    shadowOpacity: 0.3,
    shadowRadius: 20,
    elevation: 10,
  },
  successIconContainer: {
    marginBottom: 20,
  },
  successTitle: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 8,
    textAlign: 'center',
  },
  successSubtitle: {
    fontSize: 16,
    color: '#6B7280',
    marginBottom: 32,
    textAlign: 'center',
  },
  successButtonsContainer: {
    width: '100%',
    gap: 12,
  },
  openReceiptButton: {
    backgroundColor: '#3B82F6',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  openReceiptButtonText: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  closeModalButton: {
    backgroundColor: '#F3F4F6',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  closeModalButtonText: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#374151',
  },
});
