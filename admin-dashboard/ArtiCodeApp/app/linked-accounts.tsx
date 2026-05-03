import { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
  RefreshControl,
  ActivityIndicator,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, User, TrendingUp, TrendingDown } from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { UserLinkedAccount, CURRENCIES } from '@/types/database';

export default function LinkedAccountsScreen() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const [linkedAccounts, setLinkedAccounts] = useState<UserLinkedAccount[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    loadLinkedAccounts();
  }, []);

  const loadLinkedAccounts = async () => {
    try {
      const { data, error } = await supabase
        .from('user_linked_accounts')
        .select('*')
        .or(`owner_user_id.eq.${currentUser?.userId},linked_user_id.eq.${currentUser?.userId}`)
        .order('link_created_at', { ascending: false });

      if (!error && data) {
        setLinkedAccounts(data);
      }
    } catch (error) {
      console.error('Error loading linked accounts:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await loadLinkedAccounts();
    setRefreshing(false);
  };

  const getAvatarColor = (index: number) => {
    const colors = ['#4F46E5', '#10B981', '#F59E0B', '#EF4444', '#8B5CF6', '#EC4899', '#14B8A6', '#F97316'];
    return colors[index % colors.length];
  };

  const getInitials = (name: string) => {
    const words = name.split(' ');
    if (words.length >= 2) {
      return words[0][0] + words[1][0];
    }
    return name.substring(0, 2);
  };

  const renderLinkedAccount = ({ item, index }: { item: UserLinkedAccount; index: number }) => {
    const isOwner = item.owner_user_id === currentUser?.userId;
    const displayName = isOwner ? item.linked_full_name : item.owner_full_name;
    const displayAccount = isOwner ? item.linked_account_number : item.owner_account_number;
    const balance = Number(item.total_balance);
    const displayPersonHasCredit = isOwner ? balance > 0 : balance < 0;
    const balanceLabel = displayPersonHasCredit ? 'له' : 'عليه';
    const balanceColor = displayPersonHasCredit ? '#10B981' : '#EF4444';
    const BalanceIcon = displayPersonHasCredit ? TrendingUp : TrendingDown;

    return (
      <TouchableOpacity
        style={styles.accountCard}
        onPress={() => router.push(`/customer-details?id=${item.customer_id}` as any)}
      >
        <View style={[styles.avatar, { backgroundColor: getAvatarColor(index) }]}>
          <Text style={styles.avatarText}>{getInitials(displayName)}</Text>
        </View>

        <View style={styles.accountInfo}>
          <View style={styles.accountHeader}>
            <Text style={styles.accountName}>{displayName}</Text>
            <View style={styles.roleBadge}>
              <Text style={styles.roleBadgeText}>{isOwner ? 'عميلك' : 'أنت عميل عنده'}</Text>
            </View>
          </View>
          <Text style={styles.accountNumber}>رقم الحساب: {displayAccount}</Text>
        </View>

        <View style={styles.balanceContainer}>
          {balance === 0 ? (
            <Text style={[styles.balanceText, { color: '#9CA3AF' }]}>متساوي</Text>
          ) : (
            <View style={styles.balanceInfo}>
              <BalanceIcon size={18} color={balanceColor} />
              <Text style={[styles.balanceText, { color: balanceColor }]}>
                {balanceLabel}
              </Text>
              <Text style={[styles.balanceAmount, { color: balanceColor }]}>
                {Math.round(Math.abs(balance))}
              </Text>
            </View>
          )}
        </View>
      </TouchableOpacity>
    );
  };

  if (isLoading) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
            <ArrowRight size={24} color="#111827" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>الحسابات المتبادلة</Text>
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
        <Text style={styles.headerTitle}>الحسابات المتبادلة</Text>
        <View style={{ width: 40 }} />
      </View>

      <View style={styles.infoCard}>
        <User size={20} color="#4F46E5" />
        <Text style={styles.infoText}>
          هنا تجد جميع المستخدمين الذين لديك حسابات متبادلة معهم
        </Text>
      </View>

      <FlatList
        data={linkedAccounts}
        renderItem={renderLinkedAccount}
        keyExtractor={(item) => item.customer_id}
        contentContainerStyle={styles.listContent}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        ListEmptyComponent={
          <View style={styles.emptyContainer}>
            <User size={48} color="#9CA3AF" />
            <Text style={styles.emptyText}>لا توجد حسابات متبادلة</Text>
            <Text style={styles.emptySubText}>
              يمكنك إضافة مستخدمين آخرين كعملاء من صفحة إضافة عميل
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
  infoCard: {
    backgroundColor: '#EEF2FF',
    margin: 16,
    padding: 16,
    borderRadius: 12,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  infoText: {
    flex: 1,
    fontSize: 14,
    color: '#4F46E5',
    textAlign: 'right',
  },
  listContent: {
    padding: 16,
    paddingBottom: 32,
  },
  accountCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 12,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    borderLeftWidth: 4,
    borderLeftColor: '#4F46E5',
  },
  avatar: {
    width: 56,
    height: 56,
    borderRadius: 12,
    justifyContent: 'center',
    alignItems: 'center',
  },
  avatarText: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  accountInfo: {
    flex: 1,
    gap: 4,
  },
  accountHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  accountName: {
    fontSize: 17,
    fontWeight: '600',
    color: '#111827',
    textAlign: 'right',
  },
  roleBadge: {
    backgroundColor: '#DBEAFE',
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 8,
  },
  roleBadgeText: {
    fontSize: 11,
    fontWeight: '600',
    color: '#1E40AF',
  },
  accountNumber: {
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
  },
  balanceContainer: {
    alignItems: 'flex-start',
  },
  balanceInfo: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
  },
  balanceText: {
    fontSize: 13,
    fontWeight: '500',
  },
  balanceAmount: {
    fontSize: 16,
    fontWeight: 'bold',
  },
  emptyContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingVertical: 64,
    gap: 12,
  },
  emptyText: {
    fontSize: 18,
    fontWeight: '600',
    color: '#6B7280',
  },
  emptySubText: {
    fontSize: 14,
    color: '#9CA3AF',
    textAlign: 'center',
    paddingHorizontal: 32,
  },
});
