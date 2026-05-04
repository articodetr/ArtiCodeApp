import { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  Alert,
  Linking,
} from 'react-native';
import { useRouter, useLocalSearchParams } from 'expo-router';
import {
  ArrowRight,
  Printer,
  Share2,
  Phone,
  MessageCircle,
  Calendar,
  DollarSign,
} from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import { Transaction, Customer } from '@/types/database';
import { useAuth } from '@/contexts/AuthContext';
import { fetchAccessibleCustomerById } from '@/services/userScopeService';
import { format } from 'date-fns';
import { ar } from 'date-fns/locale';
import { CustomerStatusBadge } from '@/components/customer/CustomerStatusBadge';

export default function TransactionDetailsScreen() {
  const router = useRouter();
  const { id } = useLocalSearchParams();
  const { settings, currentUser } = useAuth();
  const [transaction, setTransaction] = useState<Transaction | null>(null);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    if (id && currentUser?.userId) {
      loadTransaction();
    }
  }, [id, currentUser?.userId]);

  const loadTransaction = async () => {
    try {
      if (!currentUser?.userId) {
        setIsLoading(false);
        return;
      }

      const { data: txnData, error: txnError } = await supabase
        .from('transactions')
        .select('*')
        .eq('id', id)
        .maybeSingle();

      if (txnError || !txnData) {
        Alert.alert('خطأ', 'لم يتم العثور على الحوالة');
        router.back();
        return;
      }

      const customerData = await fetchAccessibleCustomerById(
        currentUser.userId,
        txnData.customer_id,
        true,
      );

      if (!customerData) {
        Alert.alert('غير مصرح', 'هذه الحوالة غير متاحة للحساب الحالي');
        router.back();
        return;
      }

      setTransaction(txnData);
      setCustomer(customerData);
    } catch (error) {
      console.error('Error loading transaction:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء تحميل البيانات');
    } finally {
      setIsLoading(false);
    }
  };

  const handlePrint = async () => {
    if (!transaction || !customer) return;
    Alert.alert('تنبيه', 'هذه الميزة متاحة للحركات المالية الجديدة فقط');
  };

  const handleShare = async () => {
    if (!transaction || !customer) return;
    Alert.alert('تنبيه', 'هذه الميزة متاحة للحركات المالية الجديدة فقط');
  };

  const handleCall = () => {
    if (customer?.phone) {
      Linking.openURL(`tel:${customer.phone}`);
    }
  };

  const handleWhatsApp = async () => {
    if (!customer?.phone || !transaction || !settings) return;

    const cleanPhone = customer.phone.replace(/[^0-9]/g, '');
    const message = `مرحباً ${customer.name}،\n\nسند الحوالة رقم: ${transaction.transaction_number}\n\nالمبلغ المرسل: ${Number(transaction.amount_sent).toFixed(2)} ${transaction.currency_sent}\nالمبلغ المستلم: ${Number(transaction.amount_received).toFixed(2)} ${transaction.currency_received}\n\nشكراً لثقتكم بنا\n${settings.shop_name}`;

    Linking.openURL(`whatsapp://send?phone=${cleanPhone}&text=${encodeURIComponent(message)}`);
  };

  if (isLoading) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
            <ArrowRight size={24} color="#111827" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>تفاصيل الحوالة</Text>
          <View style={{ width: 40 }} />
        </View>
        <View style={styles.loadingContainer}>
          <Text style={styles.loadingText}>جاري التحميل...</Text>
        </View>
      </View>
    );
  }

  if (!transaction || !customer) {
    return null;
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>تفاصيل الحوالة</Text>
        <View style={{ width: 40 }} />
      </View>

      <ScrollView style={styles.content}>
        <View style={styles.transactionCard}>
          <View style={styles.transactionNumberContainer}>
            <Text style={styles.transactionNumber}>#{transaction.transaction_number}</Text>
          </View>

          <View style={styles.customerSection}>
            <Text style={styles.sectionTitle}>معلومات العميل</Text>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>الاسم:</Text>
              <View style={styles.customerValueBlock}>
                <View style={styles.customerValueHeader}>
                  <CustomerStatusBadge customer={customer} />
                  <Text style={styles.infoValue}>{customer.name}</Text>
                </View>
                <Text style={styles.customerMetaText}>
                  رقم الحساب: {customer.account_number}
                </Text>
              </View>
            </View>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>الهاتف:</Text>
              <Text style={styles.infoValue}>{customer.phone}</Text>
            </View>
            <View style={styles.contactButtons}>
              <TouchableOpacity style={styles.contactButton} onPress={handleCall}>
                <Phone size={20} color="#10B981" />
                <Text style={[styles.contactButtonText, { color: '#10B981' }]}>اتصال</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.contactButton} onPress={handleWhatsApp}>
                <MessageCircle size={20} color="#25D366" />
                <Text style={[styles.contactButtonText, { color: '#25D366' }]}>واتساب</Text>
              </TouchableOpacity>
            </View>
          </View>

          <View style={styles.amountSection}>
            <Text style={styles.sectionTitle}>تفاصيل الحوالة</Text>
            <View style={styles.amountCard}>
              <Text style={styles.amountLabel}>المبلغ المرسل</Text>
              <Text style={[styles.amountValue, { color: '#EF4444' }]}>
                {Number(transaction.amount_sent).toFixed(2)} {transaction.currency_sent}
              </Text>
            </View>

            <View style={styles.exchangeRate}>
              <DollarSign size={20} color="#4F46E5" />
              <Text style={styles.exchangeRateText}>
                سعر الصرف: {Number(transaction.exchange_rate).toFixed(4)}
              </Text>
            </View>

            <View style={styles.amountCard}>
              <Text style={styles.amountLabel}>المبلغ المستلم</Text>
              <Text style={[styles.amountValue, { color: '#10B981' }]}>
                {Number(transaction.amount_received).toFixed(2)} {transaction.currency_received}
              </Text>
            </View>
          </View>

          <View style={styles.detailsSection}>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>الحالة:</Text>
              <Text
                style={[
                  styles.infoValue,
                  { color: transaction.status === 'completed' ? '#10B981' : '#F59E0B' },
                ]}
              >
                {transaction.status === 'completed' ? 'مكتملة' : 'قيد الانتظار'}
              </Text>
            </View>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>التاريخ:</Text>
              <Text style={styles.infoValue}>
                {format(new Date(transaction.created_at), 'dd MMMM yyyy - HH:mm', {
                  locale: ar,
                })}
              </Text>
            </View>
            {transaction.notes && (
              <View style={styles.notesContainer}>
                <Text style={styles.infoLabel}>ملاحظات:</Text>
                <Text style={styles.notesText}>{transaction.notes}</Text>
              </View>
            )}
          </View>
        </View>

        <View style={styles.actionsSection}>
          <TouchableOpacity style={styles.actionButton} onPress={handlePrint}>
            <Printer size={24} color="#4F46E5" />
            <Text style={styles.actionButtonText}>طباعة السند</Text>
          </TouchableOpacity>

          <TouchableOpacity style={styles.actionButton} onPress={handleShare}>
            <Share2 size={24} color="#10B981" />
            <Text style={styles.actionButtonText}>مشاركة السند</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
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
  content: {
    flex: 1,
  },
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {
    fontSize: 16,
    color: '#9CA3AF',
  },
  transactionCard: {
    backgroundColor: '#FFFFFF',
    margin: 16,
    borderRadius: 16,
    padding: 20,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  transactionNumberContainer: {
    backgroundColor: '#EEF2FF',
    padding: 16,
    borderRadius: 12,
    marginBottom: 20,
    alignItems: 'center',
  },
  transactionNumber: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#4F46E5',
  },
  customerSection: {
    marginBottom: 24,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 12,
    textAlign: 'right',
  },
  infoRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  infoLabel: {
    fontSize: 16,
    color: '#6B7280',
  },
  customerValueBlock: {
    alignItems: 'flex-end',
    flex: 1,
  },
  customerValueHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    gap: 8,
    flexWrap: 'wrap',
  },
  infoValue: {
    fontSize: 16,
    fontWeight: '600',
    color: '#111827',
    textAlign: 'right',
  },
  customerMetaText: {
    marginTop: 6,
    fontSize: 12,
    color: '#64748B',
    textAlign: 'right',
  },
  contactButtons: {
    flexDirection: 'row',
    gap: 12,
    marginTop: 12,
  },
  contactButton: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: '#F9FAFB',
    paddingVertical: 12,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  contactButtonText: {
    fontSize: 14,
    fontWeight: '600',
  },
  amountSection: {
    marginBottom: 24,
  },
  amountCard: {
    backgroundColor: '#F9FAFB',
    padding: 16,
    borderRadius: 12,
    marginBottom: 12,
    alignItems: 'center',
  },
  amountLabel: {
    fontSize: 14,
    color: '#6B7280',
    marginBottom: 8,
  },
  amountValue: {
    fontSize: 28,
    fontWeight: 'bold',
  },
  exchangeRate: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    paddingVertical: 12,
  },
  exchangeRateText: {
    fontSize: 16,
    color: '#4F46E5',
    fontWeight: '600',
  },
  detailsSection: {
    marginBottom: 24,
  },
  notesContainer: {
    marginTop: 12,
  },
  notesText: {
    fontSize: 14,
    color: '#6B7280',
    marginTop: 8,
    padding: 12,
    backgroundColor: '#F9FAFB',
    borderRadius: 8,
    textAlign: 'right',
  },
  actionsSection: {
    flexDirection: 'row',
    gap: 12,
    paddingHorizontal: 16,
    paddingBottom: 24,
  },
  actionButton: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    padding: 16,
    alignItems: 'center',
    gap: 8,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  actionButtonText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#111827',
  },
});
