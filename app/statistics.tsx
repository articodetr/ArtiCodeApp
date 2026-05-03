import React, { useCallback, useEffect, useMemo, useState } from 'react';
import type { ComponentType } from 'react';
import {
  ActivityIndicator,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import {
  AlertCircle,
  ArrowRight,
  BarChart3,
  Bell,
  CheckCircle2,
  ChevronLeft,
  Clock,
  RefreshCcw,
  TrendingDown,
  TrendingUp,
  Users,
  Wallet,
} from 'lucide-react-native';

import { useAuth } from '@/contexts/AuthContext';
import { useDataRefresh } from '@/contexts/DataRefreshContext';
import { supabase } from '@/lib/supabase';
import { CURRENCIES } from '@/types/database';
import { StatisticsData, StatisticsService } from '@/services/statisticsService';

type CurrencyAmount = { currency: string; amount: number };
type PeriodKey = 'today' | 'yesterday' | 'week' | 'month';
type IconComponent = ComponentType<{ size: number; color: string }>;

type NetDebtByCurrency = {
  currency: string;
  totalForMe: number;
  totalOnMe: number;
  netAmount: number;
  finalAmount: number;
  direction: 'for_me' | 'on_me' | 'balanced';
};

type CustomerBalanceLine = {
  customerId: string;
  customerName: string;
  currency: string;
  amount: number;
  direction: 'for_me' | 'on_me';
};

type Insight = {
  title: string;
  description: string;
  color: string;
  icon: IconComponent;
  onPress?: () => void;
};

const PERIOD_OPTIONS: { key: PeriodKey; label: string }[] = [
  { key: 'today', label: 'اليوم' },
  { key: 'yesterday', label: 'أمس' },
  { key: 'week', label: '7 أيام' },
  { key: 'month', label: '30 يوم' },
];

function formatAmount(amount: number): string {
  return Number(amount || 0).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function formatCount(value: number): string {
  return Number(value || 0).toLocaleString('en-US');
}

function getCurrencyInfo(code: string) {
  return (
    CURRENCIES.find((currency) => currency.code === code) || {
      code,
      name: code,
      symbol: code,
    }
  );
}

function normalizeCurrencyAmounts(items?: CurrencyAmount[]): CurrencyAmount[] {
  if (!Array.isArray(items)) return [];
  return items
    .map((item) => ({
      currency: String(item.currency || ''),
      amount: Number(item.amount || 0),
    }))
    .filter((item) => item.currency && Math.abs(item.amount) > 0)
    .sort((a, b) => Math.abs(b.amount) - Math.abs(a.amount));
}

function normalizeCommissionAmounts(items?: { currency: string; total: number }[]): CurrencyAmount[] {
  if (!Array.isArray(items)) return [];
  return items
    .map((item) => ({
      currency: String(item.currency || ''),
      amount: Number(item.total || 0),
    }))
    .filter((item) => item.currency && Math.abs(item.amount) > 0)
    .sort((a, b) => Math.abs(b.amount) - Math.abs(a.amount));
}

function getPrimaryAmount(items: CurrencyAmount[]) {
  const visibleItems = normalizeCurrencyAmounts(items);

  if (visibleItems.length === 0) {
    return {
      amount: 0,
      currency: '',
      symbol: '',
      note: 'لا توجد مبالغ',
    };
  }

  const first = visibleItems[0];
  const currencyInfo = getCurrencyInfo(first.currency);

  return {
    amount: first.amount,
    currency: first.currency,
    symbol: currencyInfo.symbol,
    note: visibleItems.length > 1 ? `+${visibleItems.length - 1} عملة أخرى` : currencyInfo.name,
  };
}

function buildNetDebtByCurrency(stats: StatisticsData | null): NetDebtByCurrency[] {
  if (!stats) return [];

  const backendNet = (stats.debtStats as any)?.netByCurrency;

  if (Array.isArray(backendNet) && backendNet.length > 0) {
    return backendNet
      .map((item: any) => {
        const totalForMe = Number(item.totalForMe ?? item.total_for_me ?? 0) || 0;
        const totalOnMe = Number(item.totalOnMe ?? item.total_on_me ?? 0) || 0;
        const netAmount = Number(item.netAmount ?? item.net_amount ?? totalForMe - totalOnMe) || 0;
        const finalAmount = Math.abs(Number(item.finalAmount ?? item.final_amount ?? netAmount) || 0);
        const rawDirection = item.direction;
        const direction: NetDebtByCurrency['direction'] =
          rawDirection === 'for_me' || rawDirection === 'on_me' || rawDirection === 'balanced'
            ? rawDirection
            : netAmount > 0
              ? 'for_me'
              : netAmount < 0
                ? 'on_me'
                : 'balanced';

        return {
          currency: String(item.currency || ''),
          totalForMe,
          totalOnMe,
          netAmount,
          finalAmount,
          direction,
        };
      })
      .filter((item: NetDebtByCurrency) => item.currency)
      .sort((a: NetDebtByCurrency, b: NetDebtByCurrency) => b.finalAmount - a.finalAmount);
  }

  const currencyMap = new Map<string, { totalForMe: number; totalOnMe: number }>();

  normalizeCurrencyAmounts(stats.debtStats.owedToUsByCurrency).forEach((item) => {
    const current = currencyMap.get(item.currency) || { totalForMe: 0, totalOnMe: 0 };
    current.totalForMe += Number(item.amount || 0);
    currencyMap.set(item.currency, current);
  });

  normalizeCurrencyAmounts(stats.debtStats.weOweByCurrency).forEach((item) => {
    const current = currencyMap.get(item.currency) || { totalForMe: 0, totalOnMe: 0 };
    current.totalOnMe += Number(item.amount || 0);
    currencyMap.set(item.currency, current);
  });

  return Array.from(currencyMap.entries())
    .map(([currency, totals]) => {
      const netAmount = totals.totalForMe - totals.totalOnMe;

      return {
        currency,
        totalForMe: totals.totalForMe,
        totalOnMe: totals.totalOnMe,
        netAmount,
        finalAmount: Math.abs(netAmount),
        direction: netAmount > 0 ? 'for_me' : netAmount < 0 ? 'on_me' : 'balanced',
      } as NetDebtByCurrency;
    })
    .sort((a, b) => b.finalAmount - a.finalAmount);
}

function buildTopCustomerLines(stats: StatisticsData | null): {
  forMe: CustomerBalanceLine[];
  onMe: CustomerBalanceLine[];
} {
  const forMe: CustomerBalanceLine[] = [];
  const onMe: CustomerBalanceLine[] = [];

  if (!stats) return { forMe, onMe };

  stats.topCustomers.forEach((customer) => {
    customer.balanceByCurrency.forEach((balance) => {
      const amount = Number(balance.amount || 0);

      if (amount > 0) {
        forMe.push({
          customerId: customer.id,
          customerName: customer.name,
          currency: balance.currency,
          amount,
          direction: 'for_me',
        });
      } else if (amount < 0) {
        onMe.push({
          customerId: customer.id,
          customerName: customer.name,
          currency: balance.currency,
          amount: Math.abs(amount),
          direction: 'on_me',
        });
      }
    });
  });

  return {
    forMe: forMe.sort((a, b) => b.amount - a.amount).slice(0, 4),
    onMe: onMe.sort((a, b) => b.amount - a.amount).slice(0, 4),
  };
}

function getPeriodAmounts(stats: StatisticsData | null, periodKey: PeriodKey): CurrencyAmount[] {
  const period = stats?.periodStats?.[periodKey];
  return normalizeCurrencyAmounts(period?.movementAmountsByCurrency || []);
}

function SectionHeader({
  title,
  subtitle,
  icon: Icon,
  color,
}: {
  title: string;
  subtitle?: string;
  icon: IconComponent;
  color: string;
}) {
  return (
    <View style={styles.sectionHeader}>
      <View style={[styles.sectionIcon, { backgroundColor: `${color}14` }]}>
        <Icon size={18} color={color} />
      </View>
      <View style={styles.sectionTextBlock}>
        <Text style={styles.sectionTitle}>{title}</Text>
        {subtitle ? <Text style={styles.sectionSubtitle}>{subtitle}</Text> : null}
      </View>
    </View>
  );
}

function PrimarySummaryCard({
  title,
  amount,
  symbol,
  note,
  color,
  icon: Icon,
}: {
  title: string;
  amount: string | number;
  symbol?: string;
  note?: string;
  color: string;
  icon: IconComponent;
}) {
  return (
    <View style={[styles.primarySummaryCard, { borderColor: `${color}28` }]}>
      <View style={[styles.primarySummaryIcon, { backgroundColor: `${color}14` }]}>
        <Icon size={22} color={color} />
      </View>

      <Text style={styles.primarySummaryTitle}>{title}</Text>

      <View style={styles.primarySummaryAmountRow}>
        {symbol ? <Text style={[styles.primarySummarySymbol, { color }]}>{symbol}</Text> : null}
        <Text style={[styles.primarySummaryAmount, { color }]}>{amount}</Text>
      </View>

      {note ? <Text style={styles.primarySummaryNote}>{note}</Text> : null}
    </View>
  );
}

function AttentionTile({
  title,
  value,
  color,
  icon: Icon,
  onPress,
}: {
  title: string;
  value: number | string;
  color: string;
  icon: IconComponent;
  onPress?: () => void;
}) {
  return (
    <TouchableOpacity
      activeOpacity={onPress ? 0.82 : 1}
      onPress={onPress}
      style={[styles.attentionTile, { borderColor: `${color}25` }]}
    >
      <View style={[styles.attentionIcon, { backgroundColor: `${color}13` }]}>
        <Icon size={20} color={color} />
      </View>
      <Text style={styles.attentionTitle}>{title}</Text>
      <Text style={[styles.attentionValue, { color }]}>{value}</Text>
    </TouchableOpacity>
  );
}

function NetCurrencyCard({ item }: { item: NetDebtByCurrency }) {
  const currencyInfo = getCurrencyInfo(item.currency);
  const isForMe = item.direction === 'for_me';
  const isOnMe = item.direction === 'on_me';
  const color = isForMe ? '#059669' : isOnMe ? '#DC2626' : '#64748B';
  const label = isForMe ? 'لك' : isOnMe ? 'عليك' : 'متوازن';

  return (
    <View style={styles.currencyDecisionCard}>
      <View style={styles.currencyDecisionTop}>
        <View style={[styles.currencyBadge, { backgroundColor: `${color}12` }]}>
          <Text style={[styles.currencyCode, { color }]}>{item.currency}</Text>
          <Text style={styles.currencyName}>{currencyInfo.name}</Text>
        </View>

        <View style={styles.currencyDecisionNet}>
          <Text style={styles.currencyDecisionLabel}>الصافي</Text>
          <Text style={[styles.currencyDecisionAmount, { color }]}>
            {label} {formatAmount(item.finalAmount)} {currencyInfo.symbol}
          </Text>
        </View>
      </View>

      <View style={styles.currencyMiniGrid}>
        <View style={styles.currencyMiniBox}>
          <Text style={styles.currencyMiniLabel}>لك</Text>
          <Text style={styles.currencyMiniValue}>{formatAmount(item.totalForMe)}</Text>
        </View>
        <View style={styles.currencyMiniDivider} />
        <View style={styles.currencyMiniBox}>
          <Text style={styles.currencyMiniLabel}>عليك</Text>
          <Text style={styles.currencyMiniValue}>{formatAmount(item.totalOnMe)}</Text>
        </View>
      </View>
    </View>
  );
}

function CashFlowCard({ flow }: { flow: StatisticsData['cashFlowByCurrency'][number] }) {
  const currencyInfo = getCurrencyInfo(flow.currency);
  const netFlow = Number(flow.netFlow || 0);
  const netColor = netFlow >= 0 ? '#059669' : '#DC2626';

  return (
    <View style={styles.cashFlowCard}>
      <View style={styles.cashFlowHeader}>
        <View style={styles.cashFlowCurrency}>
          <Text style={styles.cashFlowCode}>{flow.currency}</Text>
          <Text style={styles.cashFlowName}>{currencyInfo.name}</Text>
        </View>

        <View style={styles.cashFlowNetBlock}>
          <Text style={styles.cashFlowNetLabel}>الصافي</Text>
          <Text style={[styles.cashFlowNetValue, { color: netColor }]}>
            {formatAmount(Math.abs(netFlow))} {currencyInfo.symbol}
          </Text>
        </View>
      </View>

      <View style={styles.cashFlowDetailsGrid}>
        <View style={styles.cashFlowDetailBox}>
          <Text style={styles.cashFlowDetailLabel}>الداخل</Text>
          <Text style={styles.cashFlowDetailValue}>{formatAmount(flow.totalReceived)}</Text>
        </View>
        <View style={styles.cashFlowDetailBox}>
          <Text style={styles.cashFlowDetailLabel}>الخارج</Text>
          <Text style={styles.cashFlowDetailValue}>{formatAmount(flow.totalPaid)}</Text>
        </View>
        <View style={styles.cashFlowDetailBox}>
          <Text style={styles.cashFlowDetailLabel}>معلّق</Text>
          <Text style={styles.cashFlowDetailValue}>{formatAmount(flow.pendingAmount)}</Text>
        </View>
        <View style={styles.cashFlowDetailBox}>
          <Text style={styles.cashFlowDetailLabel}>عدد المعتمد</Text>
          <Text style={styles.cashFlowDetailValue}>{formatCount(flow.approvedCount)}</Text>
        </View>
      </View>
    </View>
  );
}

function TopCustomersCard({
  title,
  color,
  customers,
  onOpenCustomer,
}: {
  title: string;
  color: string;
  customers: CustomerBalanceLine[];
  onOpenCustomer: (customerId: string) => void;
}) {
  return (
    <View style={[styles.topCustomersCard, { borderColor: `${color}22` }]}>
      <Text style={[styles.topCustomersTitle, { color }]}>{title}</Text>

      {customers.length === 0 ? (
        <Text style={styles.emptySmallText}>لا توجد مبالغ حاليًا</Text>
      ) : (
        customers.map((customer) => {
          const currencyInfo = getCurrencyInfo(customer.currency);

          return (
            <TouchableOpacity
              key={`${customer.customerId}-${customer.currency}-${customer.direction}`}
              activeOpacity={0.82}
              onPress={() => onOpenCustomer(customer.customerId)}
              style={styles.customerLine}
            >
              <View style={styles.customerAvatarSmall}>
                <Users size={14} color={color} />
              </View>
              <Text numberOfLines={1} style={styles.customerLineName}>
                {customer.customerName}
              </Text>
              <Text style={[styles.customerLineAmount, { color }]}>
                {formatAmount(customer.amount)} {currencyInfo.symbol}
              </Text>
            </TouchableOpacity>
          );
        })
      )}
    </View>
  );
}

function CurrencyAmountList({
  title,
  items,
  emptyText,
}: {
  title: string;
  items: CurrencyAmount[];
  emptyText: string;
}) {
  return (
    <View style={styles.amountListCard}>
      <Text style={styles.amountListTitle}>{title}</Text>
      {items.length === 0 ? (
        <Text style={styles.amountListEmpty}>{emptyText}</Text>
      ) : (
        items.slice(0, 5).map((item) => {
          const currencyInfo = getCurrencyInfo(item.currency);

          return (
            <View key={`${title}-${item.currency}`} style={styles.amountListRow}>
              <Text style={styles.amountListCurrency}>{item.currency}</Text>
              <Text style={styles.amountListAmount}>
                {formatAmount(item.amount)} {currencyInfo.symbol}
              </Text>
            </View>
          );
        })
      )}
    </View>
  );
}

function InsightCard({ insight }: { insight: Insight }) {
  const { icon: Icon } = insight;

  return (
    <TouchableOpacity
      activeOpacity={insight.onPress ? 0.84 : 1}
      onPress={insight.onPress}
      style={[styles.insightCard, { borderColor: `${insight.color}25` }]}
    >
      <View style={[styles.insightIcon, { backgroundColor: `${insight.color}12` }]}>
        <Icon size={18} color={insight.color} />
      </View>
      <View style={styles.insightTextBlock}>
        <Text style={styles.insightTitle}>{insight.title}</Text>
        <Text style={styles.insightDescription}>{insight.description}</Text>
      </View>
      {insight.onPress ? <ChevronLeft size={18} color="#94A3B8" /> : null}
    </TouchableOpacity>
  );
}

export default function StatisticsScreen() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const { lastRefreshTime } = useDataRefresh();

  const [stats, setStats] = useState<StatisticsData | null>(null);
  const [selectedPeriod, setSelectedPeriod] = useState<PeriodKey>('today');
  const [unreadCount, setUnreadCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadUnreadCount = useCallback(async () => {
    if (!currentUser?.userId) {
      setUnreadCount(0);
      return;
    }

    const { count, error: unreadError } = await supabase
      .from('movement_notifications')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', currentUser.userId)
      .eq('is_read', false);

    if (!unreadError && typeof count === 'number') {
      setUnreadCount(count);
    }
  }, [currentUser?.userId]);

  const loadStats = useCallback(async () => {
    if (!currentUser?.userId) {
      setStats(null);
      setUnreadCount(0);
      setLoading(false);
      return;
    }

    try {
      setError(null);
      const data = await StatisticsService.fetchAllStatistics(currentUser.userId);
      setStats(data);
      await loadUnreadCount();
    } catch (loadError) {
      console.error('[StatisticsScreen] loadStats failed:', loadError);
      setError(loadError instanceof Error ? loadError.message : 'حدث خطأ أثناء تحميل الإحصائيات');
    } finally {
      setLoading(false);
    }
  }, [currentUser?.userId, loadUnreadCount]);

  useEffect(() => {
    setLoading(true);
    loadStats();
  }, [loadStats]);

  useEffect(() => {
    if (!loading && currentUser?.userId) {
      loadStats();
    }
  }, [lastRefreshTime, currentUser?.userId]);

  const onRefresh = async () => {
    setRefreshing(true);
    await loadStats();
    setRefreshing(false);
  };

  const netDebts = useMemo(() => buildNetDebtByCurrency(stats), [stats]);
  const topCustomers = useMemo(() => buildTopCustomerLines(stats), [stats]);
  const periodAmounts = useMemo(() => getPeriodAmounts(stats, selectedPeriod), [stats, selectedPeriod]);
  const commissionAmounts = useMemo(
    () => normalizeCommissionAmounts(stats?.commissionStats?.commissionByCurrency || []),
    [stats]
  );

  const primaryForMe = getPrimaryAmount(stats?.debtStats.owedToUsByCurrency || []);
  const primaryOnMe = getPrimaryAmount(stats?.debtStats.weOweByCurrency || []);
  const primaryNet = netDebts.find((item) => item.direction !== 'balanced') || netDebts[0];
  const primaryNetCurrency = primaryNet ? getCurrencyInfo(primaryNet.currency) : null;
  const primaryNetColor =
    primaryNet?.direction === 'on_me' ? '#DC2626' : primaryNet?.direction === 'for_me' ? '#2563EB' : '#64748B';
  const primaryNetLabel =
    !primaryNet || primaryNet.direction === 'balanced'
      ? 'متوازن'
      : primaryNet.direction === 'on_me'
        ? 'عليك'
        : 'لك';

  const selectedPeriodStats = stats?.periodStats?.[selectedPeriod];
  const cashFlowItems = (stats?.cashFlowByCurrency || [])
    .filter((item) => item.currency)
    .sort((a, b) => Math.abs(Number(b.netFlow || 0)) - Math.abs(Number(a.netFlow || 0)));

  const insights = useMemo<Insight[]>(() => {
    const items: Insight[] = [];
    const actionable = stats?.actionableStats;

    if ((actionable?.awaitingMyApprovalCount || 0) > 0) {
      items.push({
        title: 'حركات تحتاج قرارك',
        description: `يوجد ${actionable?.awaitingMyApprovalCount || 0} حركة بانتظار القبول أو الرفض.`,
        color: '#D97706',
        icon: Bell,
        onPress: () => router.push('/(tabs)/notifications'),
      });
    }

    if ((actionable?.stalePendingCount || 0) > 0) {
      items.push({
        title: 'معلّقات قديمة',
        description: `يوجد ${actionable?.stalePendingCount || 0} حركة معلقة منذ أكثر من 24 ساعة وتحتاج متابعة.`,
        color: '#DC2626',
        icon: Clock,
        onPress: () => router.push('/(tabs)/notifications'),
      });
    }

    if (primaryNet && primaryNet.direction !== 'balanced') {
      const currencyInfo = getCurrencyInfo(primaryNet.currency);
      items.push({
        title: 'أكبر صافي يحتاج انتباه',
        description: `${primaryNet.direction === 'for_me' ? 'لك' : 'عليك'} ${formatAmount(primaryNet.finalAmount)} ${currencyInfo.symbol} في ${currencyInfo.name}.`,
        color: primaryNet.direction === 'for_me' ? '#059669' : '#DC2626',
        icon: primaryNet.direction === 'for_me' ? TrendingUp : TrendingDown,
      });
    }

    if (commissionAmounts.length > 0) {
      const first = commissionAmounts[0];
      const currencyInfo = getCurrencyInfo(first.currency);
      items.push({
        title: 'العمولات المسجلة',
        description: `أعلى عملة عمولات: ${formatAmount(first.amount)} ${currencyInfo.symbol} في ${currencyInfo.name}.`,
        color: '#7C3AED',
        icon: Wallet,
      });
    }

    if (items.length === 0) {
      items.push({
        title: 'الوضع مستقر',
        description: 'لا توجد تنبيهات مهمة الآن، وجميع المؤشرات تبدو هادئة.',
        color: '#059669',
        icon: CheckCircle2,
      });
    }

    return items.slice(0, 4);
  }, [stats, primaryNet, commissionAmounts, router]);

  if (loading) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity style={styles.headerButton} onPress={() => router.back()}>
            <ArrowRight size={24} color="#0F172A" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>الإحصاءات</Text>
          <View style={styles.headerButton} />
        </View>

        <View style={styles.centerState}>
          <ActivityIndicator size="large" color="#2563EB" />
          <Text style={styles.centerText}>جاري تحميل لوحة المتابعة...</Text>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.headerButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#0F172A" />
        </TouchableOpacity>

        <View style={styles.headerCenter}>
          <Text style={styles.headerTitle}>لوحة المتابعة</Text>
          <Text style={styles.headerSubtitle}>ملخص سريع لصاحب الحوالات</Text>
        </View>

        <TouchableOpacity style={styles.headerButton} onPress={onRefresh}>
          <RefreshCcw size={21} color="#2563EB" />
        </TouchableOpacity>
      </View>

      <ScrollView
        style={styles.content}
        contentContainerStyle={styles.contentContainer}
        showsVerticalScrollIndicator={false}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor="#2563EB" />}
      >
        {error ? (
          <View style={styles.errorBox}>
            <AlertCircle size={20} color="#DC2626" />
            <View style={styles.errorTextBlock}>
              <Text style={styles.errorTitle}>تعذر تحميل الإحصاءات</Text>
              <Text style={styles.errorMessage}>{error}</Text>
            </View>
          </View>
        ) : null}

        <View style={styles.dashboardHero}>
          <View style={styles.dashboardHeroTop}>
            <View>
              <Text style={styles.dashboardHeroKicker}>الموقف المالي الحالي</Text>
              <Text style={styles.dashboardHeroTitle}>{primaryNetLabel}</Text>
            </View>
            <View style={styles.dashboardHeroIcon}>
              <Wallet size={26} color="#FFFFFF" />
            </View>
          </View>

          <Text style={[styles.dashboardHeroAmount, { color: primaryNetColor }]}>
            {primaryNet ? formatAmount(primaryNet.finalAmount) : '0.00'} {primaryNetCurrency?.symbol || ''}
          </Text>

          <Text style={styles.dashboardHeroNote}>
            {primaryNet
              ? `أعلى صافي ظاهر حاليًا بعملة ${primaryNetCurrency?.name || primaryNet.currency}`
              : 'لا يوجد صافي ديون ظاهر حاليًا'}
          </Text>
        </View>

        <View style={styles.summaryGrid}>
          <PrimarySummaryCard
            title="لك"
            amount={formatAmount(primaryForMe.amount)}
            symbol={primaryForMe.symbol}
            note={primaryForMe.note}
            color="#059669"
            icon={TrendingUp}
          />
          <PrimarySummaryCard
            title="عليك"
            amount={formatAmount(primaryOnMe.amount)}
            symbol={primaryOnMe.symbol}
            note={primaryOnMe.note}
            color="#DC2626"
            icon={TrendingDown}
          />
        </View>

        <SectionHeader
          title="يحتاج متابعة الآن"
          subtitle="اختصارات سريعة للحركات التي قد تعطل الحسابات"
          icon={Bell}
          color="#D97706"
        />

        <View style={styles.attentionGrid}>
          <AttentionTile
            title="بانتظار موافقتك"
            value={stats?.actionableStats.awaitingMyApprovalCount || 0}
            color="#D97706"
            icon={Bell}
            onPress={() => router.push('/(tabs)/notifications')}
          />
          <AttentionTile
            title="بانتظار الطرف الآخر"
            value={stats?.actionableStats.awaitingOthersApprovalCount || 0}
            color="#2563EB"
            icon={Clock}
            onPress={() => router.push('/(tabs)/notifications')}
          />
          <AttentionTile
            title="معلّق قديم"
            value={stats?.actionableStats.stalePendingCount || 0}
            color="#DC2626"
            icon={AlertCircle}
            onPress={() => router.push('/(tabs)/notifications')}
          />
        </View>

        <SectionHeader
          title="تنبيهات ذكية"
          subtitle="قراءة مختصرة تساعدك تعرف ما الذي يحتاج قرارًا"
          icon={AlertCircle}
          color="#7C3AED"
        />

        <View style={styles.insightsList}>
          {insights.map((insight, index) => (
            <InsightCard key={`${insight.title}-${index}`} insight={insight} />
          ))}
        </View>

        <SectionHeader
          title="الصافي حسب العملة"
          subtitle="لك أو عليك لكل عملة بدون خلط العملات"
          icon={BarChart3}
          color="#2563EB"
        />

        {netDebts.length ? (
          <View style={styles.currencyDecisionList}>
            {netDebts.slice(0, 6).map((item) => (
              <NetCurrencyCard key={item.currency} item={item} />
            ))}
          </View>
        ) : (
          <View style={styles.emptyBlock}>
            <CheckCircle2 size={24} color="#059669" />
            <Text style={styles.emptyTitle}>لا توجد ديون صافية</Text>
            <Text style={styles.emptyText}>كل الحسابات متوازنة في الوقت الحالي.</Text>
          </View>
        )}

        <SectionHeader
          title="التدفق المالي حسب العملة"
          subtitle="الداخل، الخارج، الصافي، والمعلّق لكل عملة"
          icon={RefreshCcw}
          color="#0F766E"
        />

        {cashFlowItems.length ? (
          <View style={styles.cashFlowList}>
            {cashFlowItems.slice(0, 6).map((flow) => (
              <CashFlowCard key={flow.currency} flow={flow} />
            ))}
          </View>
        ) : (
          <View style={styles.emptyBlock}>
            <BarChart3 size={24} color="#64748B" />
            <Text style={styles.emptyTitle}>لا يوجد تدفق مالي ظاهر</Text>
            <Text style={styles.emptyText}>عند اعتماد الحركات ستظهر تفاصيل الداخل والخارج حسب العملة.</Text>
          </View>
        )}

        <SectionHeader
          title="نشاط الفترة"
          subtitle="اختر الفترة لمعرفة حجم الحركة والعمولات"
          icon={Clock}
          color="#334155"
        />

        <View style={styles.periodTabs}>
          {PERIOD_OPTIONS.map((option) => {
            const active = option.key === selectedPeriod;

            return (
              <TouchableOpacity
                key={option.key}
                activeOpacity={0.85}
                onPress={() => setSelectedPeriod(option.key)}
                style={[styles.periodTab, active && styles.periodTabActive]}
              >
                <Text style={[styles.periodTabText, active && styles.periodTabTextActive]}>{option.label}</Text>
              </TouchableOpacity>
            );
          })}
        </View>

        <View style={styles.periodSummaryCard}>
          <View style={styles.periodMetric}>
            <Text style={styles.periodMetricLabel}>الحركات</Text>
            <Text style={styles.periodMetricValue}>{formatCount(selectedPeriodStats?.movements || 0)}</Text>
          </View>
          <View style={styles.periodMetricDivider} />
          <View style={styles.periodMetric}>
            <Text style={styles.periodMetricLabel}>حركات العمولة</Text>
            <Text style={styles.periodMetricValue}>{formatCount(selectedPeriodStats?.commissionMovements || 0)}</Text>
          </View>
          <View style={styles.periodMetricDivider} />
          <View style={styles.periodMetric}>
            <Text style={styles.periodMetricLabel}>نسبة القبول</Text>
            <Text style={styles.periodMetricValue}>{formatCount(stats?.actionableStats.approvalRateLast7Days || 0)}%</Text>
          </View>
        </View>

        <View style={styles.amountListsGrid}>
          <CurrencyAmountList title="مبالغ الفترة" items={periodAmounts} emptyText="لا توجد مبالغ في هذه الفترة" />
          <CurrencyAmountList title="العمولات" items={commissionAmounts} emptyText="لا توجد عمولات مسجلة" />
        </View>

        <SectionHeader
          title="أهم العملاء للمتابعة"
          subtitle="الأكثر تأثيرًا على التحصيل أو السداد"
          icon={Users}
          color="#2563EB"
        />

        <View style={styles.topCustomersGrid}>
          <TopCustomersCard
            title="عملاء لك عليهم"
            color="#059669"
            customers={topCustomers.forMe}
            onOpenCustomer={(customerId) => router.push(`/customer-details?id=${customerId}` as any)}
          />
          <TopCustomersCard
            title="عملاء لهم عليك"
            color="#DC2626"
            customers={topCustomers.onMe}
            onOpenCustomer={(customerId) => router.push(`/customer-details?id=${customerId}` as any)}
          />
        </View>

        <SectionHeader
          title="ملخص سريع"
          subtitle="أرقام عامة تساعدك تقرأ حجم النشاط"
          icon={CheckCircle2}
          color="#059669"
        />

        <View style={styles.quickStatsCard}>
          <View style={styles.quickStatItem}>
            <Text style={styles.quickStatLabel}>العملاء</Text>
            <Text style={styles.quickStatValue}>{formatCount(stats?.totalCustomers || 0)}</Text>
          </View>
          <View style={styles.quickStatDivider} />
          <View style={styles.quickStatItem}>
            <Text style={styles.quickStatLabel}>الحركات المعتمدة</Text>
            <Text style={styles.quickStatValue}>{formatCount(stats?.totalMovements || 0)}</Text>
          </View>
          <View style={styles.quickStatDivider} />
          <View style={styles.quickStatItem}>
            <Text style={styles.quickStatLabel}>إشعارات غير مقروءة</Text>
            <Text style={styles.quickStatValue}>{formatCount(unreadCount)}</Text>
          </View>
        </View>

        <TouchableOpacity
          activeOpacity={0.86}
          style={styles.reportButton}
          onPress={() => router.push('/(tabs)/notifications')}
        >
          <View>
            <Text style={styles.reportButtonTitle}>فتح مركز المتابعة</Text>
            <Text style={styles.reportButtonSubtitle}>راجع القبول والرفض والحركات المعلقة</Text>
          </View>
          <ChevronLeft size={22} color="#FFFFFF" />
        </TouchableOpacity>

        <View style={styles.footerSpace} />
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F8FAFC',
  },
  header: {
    backgroundColor: '#FFFFFF',
    paddingTop: 16,
    paddingHorizontal: 18,
    paddingBottom: 14,
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  headerButton: {
    width: 42,
    height: 42,
    borderRadius: 21,
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerCenter: {
    alignItems: 'center',
  },
  headerTitle: {
    color: '#0F172A',
    fontSize: 21,
    fontWeight: '900',
  },
  headerSubtitle: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '700',
    marginTop: 2,
  },
  content: {
    flex: 1,
  },
  contentContainer: {
    paddingHorizontal: 16,
    paddingTop: 18,
    paddingBottom: 34,
  },
  centerState: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
  },
  centerText: {
    color: '#475569',
    fontSize: 15,
    fontWeight: '700',
  },
  errorBox: {
    backgroundColor: '#FEF2F2',
    borderColor: '#FECACA',
    borderWidth: 1,
    borderRadius: 18,
    padding: 14,
    flexDirection: 'row',
    gap: 10,
    marginBottom: 14,
  },
  errorTextBlock: {
    flex: 1,
  },
  errorTitle: {
    color: '#991B1B',
    fontSize: 14,
    fontWeight: '900',
    textAlign: 'right',
  },
  errorMessage: {
    color: '#7F1D1D',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 3,
    textAlign: 'right',
  },
  dashboardHero: {
    backgroundColor: '#0F172A',
    borderRadius: 28,
    padding: 18,
    marginBottom: 14,
    shadowColor: '#0F172A',
    shadowOpacity: 0.12,
    shadowRadius: 16,
    shadowOffset: { width: 0, height: 8 },
    elevation: 4,
  },
  dashboardHeroTop: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  dashboardHeroKicker: {
    color: '#CBD5E1',
    fontSize: 12,
    fontWeight: '800',
    textAlign: 'right',
  },
  dashboardHeroTitle: {
    color: '#FFFFFF',
    fontSize: 24,
    fontWeight: '900',
    marginTop: 4,
    textAlign: 'right',
  },
  dashboardHeroIcon: {
    width: 54,
    height: 54,
    borderRadius: 21,
    backgroundColor: '#2563EB',
    alignItems: 'center',
    justifyContent: 'center',
  },
  dashboardHeroAmount: {
    fontSize: 34,
    fontWeight: '900',
    marginTop: 18,
    textAlign: 'right',
  },
  dashboardHeroNote: {
    color: '#CBD5E1',
    fontSize: 12,
    fontWeight: '700',
    marginTop: 5,
    textAlign: 'right',
    lineHeight: 18,
  },
  summaryGrid: {
    flexDirection: 'row',
    gap: 12,
  },
  primarySummaryCard: {
    flex: 1,
    minHeight: 142,
    backgroundColor: '#FFFFFF',
    borderRadius: 22,
    borderWidth: 1,
    padding: 15,
    shadowColor: '#0F172A',
    shadowOpacity: 0.05,
    shadowRadius: 10,
    shadowOffset: { width: 0, height: 4 },
    elevation: 2,
  },
  primarySummaryIcon: {
    width: 42,
    height: 42,
    borderRadius: 16,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 12,
    alignSelf: 'flex-end',
  },
  primarySummaryTitle: {
    color: '#0F172A',
    fontSize: 16,
    fontWeight: '900',
    textAlign: 'right',
  },
  primarySummaryAmountRow: {
    marginTop: 7,
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: 5,
  },
  primarySummaryAmount: {
    fontSize: 22,
    fontWeight: '900',
    textAlign: 'right',
  },
  primarySummarySymbol: {
    fontSize: 13,
    fontWeight: '900',
  },
  primarySummaryNote: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '700',
    marginTop: 5,
    textAlign: 'right',
  },
  sectionHeader: {
    marginTop: 24,
    marginBottom: 12,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 9,
  },
  sectionIcon: {
    width: 36,
    height: 36,
    borderRadius: 14,
    alignItems: 'center',
    justifyContent: 'center',
  },
  sectionTextBlock: {
    flex: 1,
    alignItems: 'flex-end',
  },
  sectionTitle: {
    color: '#0F172A',
    fontSize: 18,
    fontWeight: '900',
    textAlign: 'right',
  },
  sectionSubtitle: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '700',
    marginTop: 2,
    textAlign: 'right',
  },
  attentionGrid: {
    flexDirection: 'row',
    gap: 9,
  },
  attentionTile: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderRadius: 20,
    borderWidth: 1,
    paddingVertical: 14,
    paddingHorizontal: 8,
    alignItems: 'center',
    minHeight: 118,
  },
  attentionIcon: {
    width: 38,
    height: 38,
    borderRadius: 16,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 9,
  },
  attentionTitle: {
    color: '#0F172A',
    fontSize: 11,
    fontWeight: '900',
    minHeight: 31,
    textAlign: 'center',
  },
  attentionValue: {
    fontSize: 22,
    fontWeight: '900',
  },
  insightsList: {
    gap: 10,
  },
  insightCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 20,
    borderWidth: 1,
    padding: 13,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 11,
  },
  insightIcon: {
    width: 38,
    height: 38,
    borderRadius: 15,
    alignItems: 'center',
    justifyContent: 'center',
  },
  insightTextBlock: {
    flex: 1,
  },
  insightTitle: {
    color: '#0F172A',
    fontSize: 14,
    fontWeight: '900',
    textAlign: 'right',
  },
  insightDescription: {
    color: '#64748B',
    fontSize: 12,
    fontWeight: '700',
    lineHeight: 18,
    textAlign: 'right',
    marginTop: 3,
  },
  currencyDecisionList: {
    gap: 10,
  },
  currencyDecisionCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 22,
    borderWidth: 1,
    borderColor: '#E2E8F0',
    padding: 14,
  },
  currencyDecisionTop: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  currencyBadge: {
    minWidth: 86,
    borderRadius: 18,
    paddingVertical: 10,
    paddingHorizontal: 10,
    alignItems: 'center',
  },
  currencyCode: {
    fontSize: 18,
    fontWeight: '900',
  },
  currencyName: {
    color: '#64748B',
    fontSize: 10,
    fontWeight: '700',
    marginTop: 2,
    textAlign: 'center',
  },
  currencyDecisionNet: {
    flex: 1,
    alignItems: 'flex-end',
  },
  currencyDecisionLabel: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '900',
    textAlign: 'right',
  },
  currencyDecisionAmount: {
    fontSize: 19,
    fontWeight: '900',
    marginTop: 4,
    textAlign: 'right',
  },
  currencyMiniGrid: {
    flexDirection: 'row',
    marginTop: 14,
    backgroundColor: '#F8FAFC',
    borderRadius: 16,
    paddingVertical: 10,
    alignItems: 'center',
  },
  currencyMiniBox: {
    flex: 1,
    alignItems: 'center',
  },
  currencyMiniLabel: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '900',
  },
  currencyMiniValue: {
    color: '#0F172A',
    fontSize: 13,
    fontWeight: '900',
    marginTop: 4,
  },
  currencyMiniDivider: {
    width: 1,
    height: 32,
    backgroundColor: '#E2E8F0',
  },
  cashFlowList: {
    gap: 10,
  },
  cashFlowCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 22,
    borderWidth: 1,
    borderColor: '#E2E8F0',
    padding: 14,
  },
  cashFlowHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  cashFlowCurrency: {
    alignItems: 'center',
    backgroundColor: '#F1F5F9',
    borderRadius: 16,
    paddingVertical: 9,
    paddingHorizontal: 12,
    minWidth: 82,
  },
  cashFlowCode: {
    color: '#0F172A',
    fontSize: 17,
    fontWeight: '900',
  },
  cashFlowName: {
    color: '#64748B',
    fontSize: 10,
    fontWeight: '700',
    marginTop: 2,
  },
  cashFlowNetBlock: {
    flex: 1,
    alignItems: 'flex-end',
  },
  cashFlowNetLabel: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '900',
  },
  cashFlowNetValue: {
    fontSize: 20,
    fontWeight: '900',
    marginTop: 4,
  },
  cashFlowDetailsGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    marginTop: 13,
  },
  cashFlowDetailBox: {
    width: '48.7%',
    backgroundColor: '#F8FAFC',
    borderRadius: 15,
    paddingVertical: 10,
    paddingHorizontal: 10,
    alignItems: 'center',
  },
  cashFlowDetailLabel: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '900',
  },
  cashFlowDetailValue: {
    color: '#0F172A',
    fontSize: 13,
    fontWeight: '900',
    marginTop: 4,
  },
  periodTabs: {
    backgroundColor: '#E2E8F0',
    borderRadius: 18,
    padding: 4,
    flexDirection: 'row',
    gap: 4,
  },
  periodTab: {
    flex: 1,
    paddingVertical: 10,
    borderRadius: 14,
    alignItems: 'center',
  },
  periodTabActive: {
    backgroundColor: '#FFFFFF',
  },
  periodTabText: {
    color: '#64748B',
    fontSize: 12,
    fontWeight: '900',
  },
  periodTabTextActive: {
    color: '#2563EB',
  },
  periodSummaryCard: {
    marginTop: 12,
    backgroundColor: '#FFFFFF',
    borderRadius: 22,
    borderWidth: 1,
    borderColor: '#E2E8F0',
    paddingVertical: 16,
    paddingHorizontal: 8,
    flexDirection: 'row',
    alignItems: 'center',
  },
  periodMetric: {
    flex: 1,
    alignItems: 'center',
  },
  periodMetricLabel: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '900',
    textAlign: 'center',
  },
  periodMetricValue: {
    color: '#0F172A',
    marginTop: 6,
    fontSize: 18,
    fontWeight: '900',
  },
  periodMetricDivider: {
    width: 1,
    height: 42,
    backgroundColor: '#E2E8F0',
  },
  amountListsGrid: {
    flexDirection: 'row',
    gap: 12,
    marginTop: 12,
  },
  amountListCard: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderRadius: 20,
    borderWidth: 1,
    borderColor: '#E2E8F0',
    padding: 13,
    minHeight: 138,
  },
  amountListTitle: {
    color: '#0F172A',
    fontSize: 14,
    fontWeight: '900',
    textAlign: 'right',
    marginBottom: 9,
  },
  amountListRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 6,
    borderBottomWidth: 1,
    borderBottomColor: '#F1F5F9',
    gap: 8,
  },
  amountListCurrency: {
    color: '#64748B',
    fontSize: 12,
    fontWeight: '900',
  },
  amountListAmount: {
    flex: 1,
    color: '#0F172A',
    fontSize: 12,
    fontWeight: '900',
    textAlign: 'right',
  },
  amountListEmpty: {
    color: '#64748B',
    fontSize: 12,
    fontWeight: '700',
    textAlign: 'center',
    marginTop: 28,
    lineHeight: 18,
  },
  topCustomersGrid: {
    flexDirection: 'row',
    gap: 12,
  },
  topCustomersCard: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderRadius: 22,
    borderWidth: 1,
    padding: 13,
    minHeight: 174,
  },
  topCustomersTitle: {
    fontSize: 14,
    fontWeight: '900',
    textAlign: 'right',
    marginBottom: 10,
  },
  customerLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: '#F1F5F9',
  },
  customerAvatarSmall: {
    width: 27,
    height: 27,
    borderRadius: 14,
    backgroundColor: '#F8FAFC',
    alignItems: 'center',
    justifyContent: 'center',
  },
  customerLineName: {
    flex: 1,
    color: '#0F172A',
    fontSize: 12,
    fontWeight: '800',
    textAlign: 'right',
  },
  customerLineAmount: {
    fontSize: 11,
    fontWeight: '900',
    textAlign: 'right',
  },
  emptySmallText: {
    color: '#64748B',
    fontSize: 12,
    fontWeight: '700',
    textAlign: 'center',
    marginTop: 32,
    lineHeight: 18,
  },
  quickStatsCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 22,
    borderWidth: 1,
    borderColor: '#E2E8F0',
    paddingVertical: 16,
    paddingHorizontal: 8,
    flexDirection: 'row',
    alignItems: 'center',
  },
  quickStatItem: {
    flex: 1,
    alignItems: 'center',
  },
  quickStatLabel: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '900',
    textAlign: 'center',
  },
  quickStatValue: {
    color: '#0F172A',
    marginTop: 7,
    fontSize: 20,
    fontWeight: '900',
  },
  quickStatDivider: {
    width: 1,
    height: 44,
    backgroundColor: '#E2E8F0',
  },
  reportButton: {
    marginTop: 18,
    backgroundColor: '#2563EB',
    borderRadius: 22,
    padding: 16,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  reportButtonTitle: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '900',
    textAlign: 'right',
  },
  reportButtonSubtitle: {
    color: '#DBEAFE',
    fontSize: 12,
    fontWeight: '700',
    marginTop: 3,
    textAlign: 'right',
  },
  emptyBlock: {
    backgroundColor: '#FFFFFF',
    borderRadius: 22,
    borderWidth: 1,
    borderColor: '#E2E8F0',
    padding: 20,
    alignItems: 'center',
  },
  emptyTitle: {
    marginTop: 8,
    color: '#0F172A',
    fontSize: 15,
    fontWeight: '900',
  },
  emptyText: {
    marginTop: 4,
    color: '#64748B',
    fontSize: 12,
    textAlign: 'center',
    lineHeight: 18,
  },
  footerSpace: {
    height: 40,
  },
});
