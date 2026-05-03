import { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
  RefreshControl,
  Alert,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, Plus, AlertCircle, CheckCircle } from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import { Debt } from '@/types/database';
import { useAuth } from '@/contexts/AuthContext';
import { fetchAccessibleCustomerIds } from '@/services/userScopeService';
import { format } from 'date-fns';
import { ar } from 'date-fns/locale';
import { CustomerStatusBadge } from '@/components/customer/CustomerStatusBadge';

interface DebtWithCustomer extends Debt {
  customer_name: string;
  customer_linked_user_id?: string | null;
  customer_is_profit_loss_account?: boolean | null;
  customer_account_number?: string | null;
}

export default function DebtsScreen() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const [debts, setDebts] = useState<DebtWithCustomer[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [filter, setFilter] = useState<'all' | 'pending' | 'paid'>('all');

  useEffect(() => {
    if (currentUser?.userId) {
      loadDebts();
    } else {
      setDebts([]);
      setIsLoading(false);
    }
  }, [currentUser?.userId]);

  const loadDebts = async () => {
    try {
      if (!currentUser?.userId) {
        setDebts([]);
        return;
      }

      const accessibleCustomerIds = await fetchAccessibleCustomerIds(currentUser.userId);

      if (accessibleCustomerIds.length === 0) {
        setDebts([]);
        return;
      }

      const { data, error } = await supabase
        .from('debts')
        .select(
          `
          *,
          customers!inner(name, linked_user_id, is_profit_loss_account, account_number)
        `
        )
        .in('customer_id', accessibleCustomerIds)
        .order('created_at', { ascending: false });

      if (!error && data) {
        const debtsWithCustomers = data.map((d: any) => ({
          ...d,
          customer_name: d.customers?.name || 'غير معروف',
          customer_linked_user_id: d.customers?.linked_user_id || null,
          customer_is_profit_loss_account: d.customers?.is_profit_loss_account || false,
          customer_account_number: d.customers?.account_number || '',
        }));
        setDebts(debtsWithCustomers);
      }
    } catch (error) {
      console.error('Error loading debts:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await loadDebts();
    setRefreshing(false);
  };

  const handlePayDebt = (debt: DebtWithCustomer) => {
    const remainingAmount = Number(debt.amount) - Number(debt.paid_amount);

    Alert.alert(
      'تسديد الدين',
      `المبلغ المتبقي: ${remainingAmount.toFixed(2)} ${debt.currency}\nاختر نوع التسديد:`,
      [
        { text: 'إلغاء', style: 'cancel' },
        {
          text: 'تسديد جزئي',
          onPress: () => {
            Alert.alert('قريباً', 'هذه الميزة قيد التطوير');
          },
        },
        {
          text: 'تسديد كامل',
          onPress: async () => {
            try {
              const { error } = await supabase
                .from('debts')
                .update({
                  status: 'paid',
                  paid_amount: debt.amount,
                  paid_at: new Date().toISOString(),
                })
                .eq('id', debt.id);

              if (error) throw error;

              Alert.alert('نجح', 'تم تسديد الدين بنجاح');
              loadDebts();
            } catch (error) {
              Alert.alert('خطأ', 'حدث خطأ أثناء تسديد الدين');
            }
          },
        },
      ]
    );
  };

  const filteredDebts = debts.filter((debt) => {
    if (filter === 'all') return true;
    return debt.status === filter;
  });

  const totalPending = debts
    .filter((d) => d.status === 'pending' || d.status === 'partial')
    .reduce((sum, d) => sum + (Number(d.amount) - Number(d.paid_amount)), 0);

  const renderDebt = ({ item }: { item: DebtWithCustomer }) => {
    const remainingAmount = Number(item.amount) - Number(item.paid_amount);

    return (
      <View style={styles.debtCard}>
        <View style={styles.debtHeader}>
          <View style={styles.debtInfo}>
            <View style={styles.customerHeader}>
              <CustomerStatusBadge
                linkedUserId={item.customer_linked_user_id}
                isProfitLossAccount={item.customer_is_profit_loss_account}
              />
              <Text style={styles.customerName}>{item.customer_name}</Text>
            </View>
            {item.customer_account_number ? (
              <Text style={styles.customerMeta}>
                رقم الحساب: {item.customer_account_number}
              </Text>
            ) : null}
            {item.reason && <Text style={styles.debtReason}>{item.reason}</Text>}
          </View>
          <View
            style={[
              styles.statusBadge,
              {
                backgroundColor:
                  item.status === 'paid'
                    ? '#10B98115'
                    : item.status === 'partial'
                    ? '#F59E0B15'
                    : '#EF444415',
              },
            ]}
          >
            <Text
              style={[
                styles.statusText,
                {
                  color:
                    item.status === 'paid'
                      ? '#10B981'
                      : item.status === 'partial'
                      ? '#F59E0B'
                      : '#EF4444',
                },
              ]}
            >
              {item.status === 'paid'
                ? 'مسدد'
                : item.status === 'partial'
                ? 'جزئي'
                : 'مستحق'}
            </Text>
          </View>
        </View>

        <View style={styles.debtBody}>
          <View style={styles.amountRow}>
            <Text style={styles.amountLabel}>المبلغ الإجمالي</Text>
            <Text style={styles.amountValue}>
              {Number(item.amount).toFixed(2)} {item.currency}
            </Text>
          </View>

          {item.paid_amount > 0 && (
            <View style={styles.amountRow}>
              <Text style={styles.amountLabel}>المبلغ المدفوع</Text>
              <Text style={[styles.amountValue, { color: '#10B981' }]}>
                {Number(item.paid_amount).toFixed(2)} {item.currency}
              </Text>
            </View>
          )}

          {item.status !== 'paid' && (
            <View style={styles.amountRow}>
              <Text style={styles.amountLabel}>المبلغ المتبقي</Text>
              <Text style={[styles.amountValue, { color: '#EF4444' }]}>
                {remainingAmount.toFixed(2)} {item.currency}
              </Text>
            </View>
          )}
        </View>

        <View style={styles.debtFooter}>
          <Text style={styles.dateText}>
            {format(new Date(item.created_at), 'dd MMMM yyyy', { locale: ar })}
          </Text>
          {item.status !== 'paid' && (
            <TouchableOpacity
              style={styles.payButton}
              onPress={() => handlePayDebt(item)}
            >
              <CheckCircle size={16} color="#10B981" />
              <Text style={styles.payButtonText}>تسديد</Text>
            </TouchableOpacity>
          )}
        </View>
      </View>
    );
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>الديون</Text>
        <TouchableOpacity
          style={styles.addButton}
          onPress={() => Alert.alert('قريباً', 'هذه الميزة قيد التطوير')}
        >
          <Plus size={20} color="#FFFFFF" />
        </TouchableOpacity>
      </View>

      <View style={styles.summaryCard}>
        <AlertCircle size={32} color="#EF4444" />
        <Text style={styles.summaryLabel}>إجمالي الديون المستحقة</Text>
        <Text style={styles.summaryValue}>{totalPending.toFixed(2)} $</Text>
      </View>

      <View style={styles.filterContainer}>
        <TouchableOpacity
          style={[styles.filterButton, filter === 'all' && styles.filterButtonActive]}
          onPress={() => setFilter('all')}
        >
          <Text
            style={[styles.filterText, filter === 'all' && styles.filterTextActive]}
          >
            الكل
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.filterButton, filter === 'pending' && styles.filterButtonActive]}
          onPress={() => setFilter('pending')}
        >
          <Text
            style={[styles.filterText, filter === 'pending' && styles.filterTextActive]}
          >
            مستحقة
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.filterButton, filter === 'paid' && styles.filterButtonActive]}
          onPress={() => setFilter('paid')}
        >
          <Text
            style={[styles.filterText, filter === 'paid' && styles.filterTextActive]}
          >
            مسددة
          </Text>
        </TouchableOpacity>
      </View>

      <FlatList
        data={filteredDebts}
        renderItem={renderDebt}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.listContent}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        ListEmptyComponent={
          <View style={styles.emptyContainer}>
            <Text style={styles.emptyText}>
              {isLoading ? 'جاري التحميل...' : 'لا توجد ديون'}
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
  addButton: {
    width: 40,
    height: 40,
    backgroundColor: '#4F46E5',
    borderRadius: 20,
    justifyContent: 'center',
    alignItems: 'center',
  },
  summaryCard: {
    backgroundColor: '#FEE2E2',
    margin: 16,
    padding: 20,
    borderRadius: 16,
    alignItems: 'center',
  },
  summaryLabel: {
    fontSize: 14,
    color: '#991B1B',
    marginTop: 8,
    marginBottom: 4,
  },
  summaryValue: {
    fontSize: 32,
    fontWeight: 'bold',
    color: '#DC2626',
  },
  filterContainer: {
    flexDirection: 'row',
    paddingHorizontal: 16,
    gap: 8,
    marginBottom: 8,
  },
  filterButton: {
    flex: 1,
    paddingVertical: 10,
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  filterButtonActive: {
    backgroundColor: '#4F46E5',
    borderColor: '#4F46E5',
  },
  filterText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#6B7280',
    textAlign: 'center',
  },
  filterTextActive: {
    color: '#FFFFFF',
  },
  listContent: {
    padding: 16,
  },
  debtCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 12,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  debtHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 12,
  },
  debtInfo: {
    flex: 1,
  },
  customerHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    gap: 8,
    flexWrap: 'wrap',
  },
  customerName: {
    fontSize: 18,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'right',
  },
  customerMeta: {
    fontSize: 12,
    color: '#64748B',
    textAlign: 'right',
    marginTop: 6,
    marginBottom: 4,
  },
  debtReason: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'right',
  },
  statusBadge: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 12,
  },
  statusText: {
    fontSize: 12,
    fontWeight: '600',
  },
  debtBody: {
    marginBottom: 12,
  },
  amountRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 6,
  },
  amountLabel: {
    fontSize: 14,
    color: '#6B7280',
  },
  amountValue: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#111827',
  },
  debtFooter: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingTop: 12,
    borderTopWidth: 1,
    borderTopColor: '#F3F4F6',
  },
  dateText: {
    fontSize: 12,
    color: '#9CA3AF',
  },
  payButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    backgroundColor: '#10B98115',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 12,
  },
  payButtonText: {
    fontSize: 12,
    fontWeight: '600',
    color: '#10B981',
  },
  emptyContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingVertical: 64,
  },
  emptyText: {
    fontSize: 16,
    color: '#9CA3AF',
  },
});
