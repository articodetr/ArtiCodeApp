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
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, Save, ArrowRightLeft, DollarSign } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { supabase } from '@/lib/supabase';
import { getExchangeRate } from '@/services/exchangeRateService';
import { Customer, Currency, CURRENCIES } from '@/types/database';
import { KeyboardAwareView } from '@/components/KeyboardAwareView';
import { useAuth } from '@/contexts/AuthContext';
import { CustomerStatusBadge } from '@/components/customer/CustomerStatusBadge';
import { sortCustomersByDisplayPriority } from '@/utils/customerDisplay';
import { buildOwnedCustomerFilter } from '@/services/userScopeService';

export default function NewTransactionScreen() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const insets = useSafeAreaInsets();
  const [isLoading, setIsLoading] = useState(false);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [showCustomerPicker, setShowCustomerPicker] = useState(false);
  const [showCurrencyPicker, setShowCurrencyPicker] = useState(false);
  const [currencyPickerType, setCurrencyPickerType] = useState<'sent' | 'received'>('sent');

  const [formData, setFormData] = useState({
    customer_id: '',
    customer_name: '',
    customer_linked_user_id: '',
    customer_account_number: '',
    amount_sent: '',
    currency_sent: 'USD' as Currency,
    amount_received: '',
    currency_received: 'TRY' as Currency,
    exchange_rate: '',
    notes: '',
  });

  useEffect(() => {
    loadCustomers();
  }, []);

  useEffect(() => {
    if (
      formData.amount_sent &&
      formData.currency_sent &&
      formData.currency_received &&
      !formData.exchange_rate
    ) {
      loadExchangeRate();
    }
  }, [formData.currency_sent, formData.currency_received]);

  useEffect(() => {
    if (formData.amount_sent && formData.exchange_rate) {
      const received = Number(formData.amount_sent) * Number(formData.exchange_rate);
      setFormData((prev) => ({ ...prev, amount_received: received.toFixed(2) }));
    }
  }, [formData.amount_sent, formData.exchange_rate]);

  const loadCustomers = async () => {
    try {
      // التحقق من وجود المستخدم الحالي
      if (!currentUser?.userId) {
        console.warn('[NewTransaction] No current user found');
        setCustomers([]);
        return;
      }

      const { data, error } = await supabase
        .from('customers')
        .select('*')
        .neq('phone', 'PROFIT_LOSS_ACCOUNT')
        .or(buildOwnedCustomerFilter(currentUser.userId))
        .order('name', { ascending: true });

      if (!error && data) {
        setCustomers(sortCustomersByDisplayPriority(data));
      }
    } catch (error) {
      console.error('Error loading customers:', error);
    }
  };

  const loadExchangeRate = async () => {
    try {
      const rate = await getExchangeRate(formData.currency_sent, formData.currency_received);
      setFormData((prev) => ({ ...prev, exchange_rate: rate.toString() }));
    } catch (error) {
      console.error('Error loading exchange rate:', error);
    }
  };

  const handleSubmit = async () => {
    if (
      !formData.customer_id ||
      !formData.amount_sent ||
      !formData.amount_received ||
      !formData.exchange_rate
    ) {
      Alert.alert('خطأ', 'الرجاء إدخال جميع البيانات المطلوبة');
      return;
    }

    setIsLoading(true);
    try {
      const { data: txnData } = await supabase.rpc('generate_transaction_number');

      const { error } = await supabase.from('transactions').insert([
        {
          transaction_number: txnData || `TXN-${Date.now()}`,
          customer_id: formData.customer_id,
          amount_sent: Number(formData.amount_sent),
          currency_sent: formData.currency_sent,
          amount_received: Number(formData.amount_received),
          currency_received: formData.currency_received,
          exchange_rate: Number(formData.exchange_rate),
          status: 'completed',
          notes: formData.notes.trim() || null,
        },
      ]);

      if (error) throw error;

      Alert.alert('نجح', 'تم إضافة الحوالة بنجاح', [
        {
          text: 'عرض السند',
          onPress: () => {
            router.back();
          },
        },
        {
          text: 'حسناً',
          onPress: () => router.back(),
        },
      ]);
    } catch (error) {
      console.error('Error adding transaction:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء إضافة الحوالة');
    } finally {
      setIsLoading(false);
    }
  };

  const selectCustomer = (customer: Customer) => {
    setFormData({
      ...formData,
      customer_id: customer.id,
      customer_name: customer.name,
      customer_linked_user_id: customer.linked_user_id || '',
      customer_account_number: customer.account_number,
    });
    setShowCustomerPicker(false);
  };

  const selectCurrency = (currency: Currency) => {
    if (currencyPickerType === 'sent') {
      setFormData({ ...formData, currency_sent: currency, exchange_rate: '' });
    } else {
      setFormData({ ...formData, currency_received: currency, exchange_rate: '' });
    }
    setShowCurrencyPicker(false);
  };

  const getCurrencySymbol = (code: string) => {
    const currency = CURRENCIES.find((c) => c.code === code);
    return currency?.symbol || code;
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>حوالة جديدة</Text>
        <View style={{ width: 40 }} />
      </View>

      <KeyboardAwareView contentContainerStyle={styles.contentContainer}>
        <TouchableOpacity
          style={styles.customerSelector}
          onPress={() => setShowCustomerPicker(true)}
        >
          <Text style={styles.customerLabel}>
            العميل <Text style={styles.required}>*</Text>
          </Text>
          <View style={styles.customerValueBlock}>
            <View style={styles.customerValueHeader}>
              {formData.customer_id ? (
                <CustomerStatusBadge
                  linkedUserId={formData.customer_linked_user_id}
                />
              ) : null}
              <Text style={styles.customerValue}>
                {formData.customer_name || 'اختر عميل'}
              </Text>
            </View>
            {formData.customer_account_number ? (
              <Text style={styles.customerSubtext}>
                رقم الحساب: {formData.customer_account_number}
              </Text>
            ) : null}
          </View>
        </TouchableOpacity>

        <View style={styles.currencySection}>
          <Text style={styles.sectionTitle}>المبلغ المرسل</Text>
          <View style={styles.currencyRow}>
            <TouchableOpacity
              style={styles.currencyButton}
              onPress={() => {
                setCurrencyPickerType('sent');
                setShowCurrencyPicker(true);
              }}
            >
              <Text style={styles.currencyButtonText}>{formData.currency_sent}</Text>
              <Text style={styles.currencySymbol}>
                {getCurrencySymbol(formData.currency_sent)}
              </Text>
            </TouchableOpacity>
            <TextInput
              style={styles.amountInput}
              value={formData.amount_sent}
              onChangeText={(text) => setFormData({ ...formData, amount_sent: text })}
              placeholder="0.00"
              placeholderTextColor="#9CA3AF"
              keyboardType="decimal-pad"
              textAlign="center"
            />
          </View>
        </View>

        <View style={styles.exchangeRateSection}>
          <ArrowRightLeft size={24} color="#4F46E5" />
          <View style={styles.exchangeRateInputContainer}>
            <Text style={styles.exchangeRateLabel}>سعر الصرف</Text>
            <TextInput
              style={styles.exchangeRateInput}
              value={formData.exchange_rate}
              onChangeText={(text) => setFormData({ ...formData, exchange_rate: text })}
              placeholder="0.0000"
              placeholderTextColor="#9CA3AF"
              keyboardType="decimal-pad"
              textAlign="center"
            />
          </View>
        </View>

        <View style={styles.currencySection}>
          <Text style={styles.sectionTitle}>المبلغ المستلم</Text>
          <View style={styles.currencyRow}>
            <TouchableOpacity
              style={styles.currencyButton}
              onPress={() => {
                setCurrencyPickerType('received');
                setShowCurrencyPicker(true);
              }}
            >
              <Text style={styles.currencyButtonText}>{formData.currency_received}</Text>
              <Text style={styles.currencySymbol}>
                {getCurrencySymbol(formData.currency_received)}
              </Text>
            </TouchableOpacity>
            <TextInput
              style={styles.amountInput}
              value={formData.amount_received}
              onChangeText={(text) => setFormData({ ...formData, amount_received: text })}
              placeholder="0.00"
              placeholderTextColor="#9CA3AF"
              keyboardType="decimal-pad"
              textAlign="center"
            />
          </View>
        </View>

        <View style={styles.inputGroup}>
          <Text style={styles.label}>ملاحظات</Text>
          <TextInput
            style={[styles.input, styles.textArea]}
            value={formData.notes}
            onChangeText={(text) => setFormData({ ...formData, notes: text })}
            placeholder="أدخل ملاحظات إضافية"
            placeholderTextColor="#9CA3AF"
            multiline
            numberOfLines={3}
            textAlign="right"
            textAlignVertical="top"
          />
        </View>

        <TouchableOpacity
          style={[styles.submitButton, isLoading && styles.submitButtonDisabled]}
          onPress={handleSubmit}
          disabled={isLoading}
        >
          <Save size={20} color="#FFFFFF" />
          <Text style={styles.submitButtonText}>
            {isLoading ? 'جاري الحفظ...' : 'حفظ الحوالة'}
          </Text>
        </TouchableOpacity>
      </KeyboardAwareView>

      <Modal
        visible={showCustomerPicker}
        animationType="slide"
        transparent={true}
        onRequestClose={() => setShowCustomerPicker(false)}
      >
        <View style={styles.modalContainer}>
          <View
            style={[
              styles.modalContent,
              { paddingBottom: Math.max(insets.bottom, 20) },
            ]}
          >
            <Text style={styles.modalTitle}>اختر عميل</Text>
            <ScrollView
              style={styles.modalList}
              contentContainerStyle={{
                paddingBottom: Math.max(insets.bottom + 12, 20),
              }}
            >
              {customers.map((customer) => (
                <TouchableOpacity
                  key={customer.id}
                  style={styles.modalItem}
                  onPress={() => selectCustomer(customer)}
                >
                  <View style={styles.modalItemHeader}>
                    <CustomerStatusBadge customer={customer} />
                    <Text style={styles.modalItemText}>{customer.name}</Text>
                  </View>
                  <Text style={styles.modalItemSubtext}>{customer.phone}</Text>
                </TouchableOpacity>
              ))}
            </ScrollView>
            <TouchableOpacity
              style={styles.modalCloseButton}
              onPress={() => setShowCustomerPicker(false)}
            >
              <Text style={styles.modalCloseButtonText}>إغلاق</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>

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
  customerSelector: {
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 20,
    borderWidth: 2,
    borderColor: '#4F46E5',
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
  },
  customerValueBlock: {
    alignItems: 'flex-end',
  },
  customerValueHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    gap: 8,
    flexWrap: 'wrap',
  },
  customerSubtext: {
    marginTop: 6,
    fontSize: 12,
    color: '#64748B',
    textAlign: 'right',
  },
  required: {
    color: '#EF4444',
  },
  currencySection: {
    marginBottom: 20,
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: '600',
    color: '#374151',
    marginBottom: 12,
    textAlign: 'right',
  },
  currencyRow: {
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
  exchangeRateSection: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#EEF2FF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 20,
    gap: 12,
  },
  exchangeRateInputContainer: {
    flex: 1,
  },
  exchangeRateLabel: {
    fontSize: 14,
    color: '#6B7280',
    marginBottom: 8,
    textAlign: 'right',
  },
  exchangeRateInput: {
    backgroundColor: '#FFFFFF',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 18,
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
  modalItemHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    gap: 8,
    marginBottom: 6,
  },
  modalItemText: {
    fontSize: 16,
    fontWeight: '700',
    color: '#111827',
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
});
