import React, { useEffect, useMemo, useState } from 'react';
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
import { ArrowRight, CheckCircle } from 'lucide-react-native';
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

function formatAmount(value: number) {
  return Number(value || 0).toLocaleString('en-US', {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
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
        .select(`*, customers!inner(name, linked_user_id, is_profit_loss_account, account_number)`)
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
      `المبلغ المتبقي: ${remainingAmount.toFixed(2)} ${debt.currency}`,
      [
        { text: 'إلغاء', style: 'cancel' },
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
      ],
    );
  };

  const filteredDebts = useMemo(() => {
    return debts.filter((debt) => {
      if (filter === 'all') return true;
      if (filter === 'pending') return debt.status === 'pending' || debt.status === 'partial';
      return debt.status === 'paid';
    });
  }, [debts, filter]);

  const totalPending = debts
    .filter((d) => d.status === 'pending' || d.status === 'partial')
    .reduce((sum, d) => sum + (Number(d.amount) - Number(d.paid_amount)), 0);

  const getStatusMeta = (status: DebtWithCustomer['status']) => {
    if (status === 'paid') return { label: 'مسدد', color: '#16A34A', bg: '#ECFDF3' };
    if (status === 'partial') return { label: 'جزئي', color: '#F59E0B', bg: '#FFF7ED' };
    return { label: 'مستحق', color: '#DC2626', bg: '#FEF2F2' };
  };

  const renderDebt = ({ item }: { item: DebtWithCustomer }) => {
    const remainingAmount = Number(item.amount) - Number(item.paid_amount);
    const statusMeta = getStatusMeta(item.status);

    return (
      <View style={styles.debtCard}>
        <View style={styles.debtHeader}>
          <View style={[styles.statusPill, { backgroundColor: statusMeta.bg }]}>
            <Text style={[styles.statusPillText, { color: statusMeta.color }]}>{statusMeta.label}</Text>
          </View>

          <View style={styles.debtInfo}>
            <View style={styles.customerHeader}>
              <CustomerStatusBadge
                linkedUserId={item.customer_linked_user_id}
                isProfitLossAccount={item.customer_is_profit_loss_account}
              />
              <Text style={styles.customerName}>{item.customer_name}</Text>
            </View>
            {item.customer_account_number ? (
              <Text style={styles.customerMeta}>رقم الحساب: {item.customer_account_number}</Text>
            ) : null}
            {item.reason ? <Text style={styles.debtReason}>{item.reason}</Text> : null}
          </View>
        </View>

        <View style={styles.valuesWrap}>
          <View style={styles.valueRow}>
            <Text style={styles.valueLabel}>الإجمالي</Text>
            <Text style={styles.valueText}>
              {formatAmount(Number(item.amount))} {item.currency}
            </Text>
          </View>

          {item.paid_amount > 0 ? (
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>المدفوع</Text>
              <Text style={[styles.valueText, { color: '#16A34A' }]}>
                {formatAmount(Number(item.paid_amount))} {item.currency}
              </Text>
            </View>
          ) : null}

          {item.status !== 'paid' ? (
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>المتبقي</Text>
              <Text style={[styles.valueText, { color: '#DC2626' }]}>
                {formatAmount(remainingAmount)} {item.currency}
              </Text>
            </View>
          ) : null}
        </View>

        <View style={styles.footerRow}>
          <Text style={styles.dateText}>
            {format(new Date(item.created_at), 'dd MMMM yyyy', { locale: ar })}
          </Text>

          {item.status !== 'paid' ? (
            <TouchableOpacity style={styles.payButton} onPress={() => handlePayDebt(item)}>
              <CheckCircle size={14} color="#16A34A" />
              <Text style={styles.payButtonText}>تسديد</Text>
            </TouchableOpacity>
          ) : null}
        </View>
      </View>
    );
  };

  return (
    <View style={styles.container}>
      <View style={styles.contentContainer}>
        <View style={styles.topHeader}>
          <View style={styles.headerSpacer} />
          <Text style={styles.pageTitle}>الديون</Text>
          <TouchableOpacity style={styles.topIconButton} onPress={() => router.back()}>
            <ArrowRight size={18} color="#1E1B4B" />
          </TouchableOpacity>
        </View>

        <View style={styles.summaryCard}>
          <Text style={styles.summaryLabel}>إجمالي الديون المستحقة</Text>
          <Text style={styles.summaryValue}>{formatAmount(totalPending)} $</Text>
        </View>

        <View style={styles.filterRow}>
          {[
            { key: 'all', label: 'الكل' },
            { key: 'pending', label: 'مستحقة' },
            { key: 'paid', label: 'مسددة' },
          ].map((item) => (
            <TouchableOpacity
              key={item.key}
              style={[styles.filterChip, filter === item.key && styles.filterChipActive]}
              onPress={() => setFilter(item.key as any)}
            >
              <Text style={[styles.filterChipText, filter === item.key && styles.filterChipTextActive]}>
                {item.label}
              </Text>
            </TouchableOpacity>
          ))}
        </View>

        <FlatList
          data={filteredDebts}
          renderItem={renderDebt}
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.listContent}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
          showsVerticalScrollIndicator={false}
          ListEmptyComponent={
            <View style={styles.emptyBox}>
              <Text style={styles.emptyText}>{isLoading ? 'جاري التحميل...' : 'لا توجد ديون'}</Text>
            </View>
          }
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#F7F7FC' },
  contentContainer: { flex: 1, padding: 14, paddingBottom: 0 },
  topHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 14,
    marginTop: 6,
  },
  topIconButton: {
    width: 42,
    height: 42,
    borderRadius: 14,
    backgroundColor: '#FFFFFF',
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: '#0F172A',
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.04,
    shadowRadius: 10,
    elevation: 2,
  },
  headerSpacer: { width: 42, height: 42 },
  pageTitle: { fontSize: 24, fontWeight: '900', color: '#1E1B4B' },
  summaryCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    padding: 14,
    marginBottom: 12,
    borderWidth: 1,
    borderColor: '#ECECF7',
  },
  summaryLabel: { fontSize: 12, color: '#7C84A3', textAlign: 'right', marginBottom: 4 },
  summaryValue: { fontSize: 22, fontWeight: '900', color: '#DC2626', textAlign: 'right' },
  filterRow: { flexDirection: 'row', gap: 10, marginBottom: 12 },
  filterChip: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderRadius: 14,
    paddingVertical: 10,
    alignItems: 'center',
    borderWidth: 1,
    borderColor: '#E3E7F2',
  },
  filterChipActive: { backgroundColor: '#5B5AF7', borderColor: '#5B5AF7' },
  filterChipText: { fontSize: 13, fontWeight: '800', color: '#5B5AF7' },
  filterChipTextActive: { color: '#FFFFFF' },
  listContent: { paddingBottom: 24, gap: 10 },
  debtCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    padding: 14,
    borderWidth: 1,
    borderColor: '#ECECF7',
  },
  debtHeader: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 10 },
  debtInfo: { flex: 1, alignItems: 'flex-end' },
  customerHeader: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  customerName: { fontSize: 15, fontWeight: '900', color: '#1E1B4B', textAlign: 'right' },
  customerMeta: { fontSize: 12, color: '#7C84A3', textAlign: 'right', marginTop: 4 },
  debtReason: { fontSize: 12, color: '#374151', textAlign: 'right', marginTop: 4 },
  statusPill: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 999, marginLeft: 10 },
  statusPillText: { fontSize: 12, fontWeight: '800' },
  valuesWrap: { gap: 8, marginBottom: 10 },
  valueRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    backgroundColor: '#FAFBFF',
    borderWidth: 1,
    borderColor: '#EEF1F6',
    borderRadius: 12,
    padding: 10,
  },
  valueLabel: { fontSize: 12, color: '#6B7280', fontWeight: '700' },
  valueText: { fontSize: 14, color: '#1F2937', fontWeight: '900' },
  footerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  dateText: { fontSize: 12, color: '#7C84A3' },
  payButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: '#ECFDF3',
    borderRadius: 12,
    paddingHorizontal: 10,
    paddingVertical: 8,
  },
  payButtonText: { fontSize: 12, color: '#16A34A', fontWeight: '800' },
  emptyBox: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    padding: 24,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    borderColor: '#ECECF7',
  },
  emptyText: { fontSize: 14, color: '#7C84A3', fontWeight: '600' },
});
