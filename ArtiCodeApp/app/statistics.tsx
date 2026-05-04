import React, { useCallback, useEffect, useMemo, useState } from 'react';
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
  ChevronLeft,
  Clock3,
  Users,
  ArrowLeftRight,
} from 'lucide-react-native';

import { useAuth } from '@/contexts/AuthContext';
import { useDataRefresh } from '@/contexts/DataRefreshContext';
import { CURRENCIES } from '@/types/database';
import { StatisticsData, StatisticsService } from '@/services/statisticsService';

// ============================================================
// Types
// ============================================================

type CurrencyLedgerRow = {
  currency: string;
  totalForMe: number;
  totalOnMe: number;
  countForMe: number;
  countOnMe: number;
  netAmount: number;
  finalAmount: number;
  direction: 'for_me' | 'on_me' | 'balanced';
};

type TopCustomerRow = {
  id: string | number;
  name: string;
  initials: string;
  amount: number;
  currency: string;
  count: number;
  lastActivity: string;
  direction: 'for_me' | 'on_me';
};

type TransactionsCountData = {
  today: number;
  week: number;
  month: number;
  yesterday?: number;
  previousMonth?: number;
  weeklyTrend?: number[];
};

// ============================================================
// Theme
// ============================================================

const C = {
  text: '#111827',
  muted: '#6B7280',
  faint: '#9CA3AF',
  border: '#E5E7EB',
  bg: '#FFFFFF',
  bgSoft: '#F9FAFB',
  bgSofter: '#FAFBFC',
  green: '#047857',
  greenSoft: '#ECFDF5',
  red: '#B91C1C',
  redSoft: '#FEE2E2',
  yellow: '#B45309',
  yellowSoft: '#FEF3C7',
  blue: '#1D4ED8',
  blueLink: '#2563EB',
  blueSoft: '#DBEAFE',
  purple: '#3C3489',
  purpleSoft: '#EEEDFE',
  avatarBg: '#F3F4F6',
  avatarText: '#4B5563',
};

// ============================================================
// Helpers
// ============================================================

function toLatinDigits(input: number | string): string {
  const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
  const easternArabicIndic = '۰۱۲۳۴۵۶۷۸۹';

  return String(input ?? '')
    .replace(/[٠-٩]/g, (d) => String(arabicIndic.indexOf(d)))
    .replace(/[۰-۹]/g, (d) => String(easternArabicIndic.indexOf(d)));
}

function formatAmount(amount: number): string {
  return Number(amount || 0).toLocaleString('en-US', {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

function sumCurrencyList(items?: { currency: string; amount?: number; total?: number }[]) {
  if (!Array.isArray(items)) return 0;

  return items.reduce((sum, item) => {
    const value = Number(item.amount ?? item.total ?? 0);
    return sum + value;
  }, 0);
}

function getInitials(name: string): string {
  if (!name) return '؟';

  const parts = name.trim().split(/\s+/);
  if (parts.length === 1) return parts[0].slice(0, 2);

  return `${parts[0][0] || ''} ${parts[1][0] || ''}`.trim();
}

function joinMetaParts(parts: Array<string | null | undefined | false>): string {
  return parts.filter(Boolean).join(' • ');
}

function buildCurrencyLedgerRows(stats: StatisticsData | null): CurrencyLedgerRow[] {
  if (!stats) return [];

  const map = new Map<
    string,
    { totalForMe: number; totalOnMe: number; countForMe: number; countOnMe: number }
  >();

  (stats.debtStats?.owedToUsByCurrency || []).forEach((item: any) => {
    const c = map.get(item.currency) || {
      totalForMe: 0,
      totalOnMe: 0,
      countForMe: 0,
      countOnMe: 0,
    };

    c.totalForMe += Number(item.amount || 0);
    c.countForMe += Number(item.count || 0);
    map.set(item.currency, c);
  });

  (stats.debtStats?.weOweByCurrency || []).forEach((item: any) => {
    const c = map.get(item.currency) || {
      totalForMe: 0,
      totalOnMe: 0,
      countForMe: 0,
      countOnMe: 0,
    };

    c.totalOnMe += Number(item.amount || 0);
    c.countOnMe += Number(item.count || 0);
    map.set(item.currency, c);
  });

  return Array.from(map.entries())
    .map(([currency, t]) => {
      const netAmount = t.totalForMe - t.totalOnMe;

      return {
        currency,
        totalForMe: t.totalForMe,
        totalOnMe: t.totalOnMe,
        countForMe: t.countForMe,
        countOnMe: t.countOnMe,
        netAmount,
        finalAmount: Math.abs(netAmount),
        direction: netAmount > 0 ? 'for_me' : netAmount < 0 ? 'on_me' : 'balanced',
      } as CurrencyLedgerRow;
    })
    .sort((a, b) => b.finalAmount - a.finalAmount);
}

function buildTopCustomers(stats: StatisticsData | null): TopCustomerRow[] {
  const list: any[] = (stats as any)?.topCustomers || [];
  if (!Array.isArray(list)) return [];

  return list.slice(0, 3).map((item: any, index: number) => ({
    id: item.id ?? index,
    name: item.name ?? 'عميل',
    initials: getInitials(item.name ?? ''),
    amount: Number(item.amount || 0),
    currency: item.currency || 'USD',
    count: Number(item.count || 0),
    lastActivity: item.lastActivity || '',
    direction: Number(item.amount) >= 0 ? 'for_me' : 'on_me',
  }));
}

function buildTxCount(stats: StatisticsData | null): TransactionsCountData {
  const t: any = (stats as any)?.transactionsCount || {};

  return {
    today: Number(t.today || 0),
    week: Number(t.week || 0),
    month: Number(t.month || 0),
    yesterday: t.yesterday != null ? Number(t.yesterday) : undefined,
    previousMonth: t.previousMonth != null ? Number(t.previousMonth) : undefined,
    weeklyTrend: Array.isArray(t.weeklyTrend) ? t.weeklyTrend.map(Number) : undefined,
  };
}

// ============================================================
// Sub components
// ============================================================

function SectionHeader({
  title,
  rightSlot,
}: {
  title: string;
  rightSlot?: React.ReactNode;
}) {
  return (
    <View style={styles.sectionHeader}>
      <Text style={styles.sectionHeaderTitle}>{title}</Text>
      {rightSlot ?? <View />}
    </View>
  );
}

function TopBar({ onBack }: { onBack: () => void }) {
  return (
    <View style={styles.topBar}>
      <TouchableOpacity style={styles.iconBtn} onPress={onBack} activeOpacity={0.7}>
        <ChevronLeft size={18} color={C.text} />
      </TouchableOpacity>

      <View style={styles.topTitleWrap}>
        <Text style={styles.topTitle}>الإحصاءات</Text>
        <Text style={styles.topSubtitle}>الإحصائيات والمستحقات</Text>
      </View>

      <View style={styles.iconBtnPlaceholder} />
    </View>
  );
}

function KPISummary({
  totalForMe,
  totalOnMe,
  customersForMe,
  customersOnMe,
}: {
  totalForMe: number;
  totalOnMe: number;
  customersForMe: number;
  customersOnMe: number;
}) {
  return (
    <View style={styles.kpiRow}>
      <View style={[styles.kpiBox, styles.kpiBoxLeftBorder]}>
        <Text style={styles.kpiLabel}>إجمالي مستحقاتي (لنا)</Text>
        <Text style={[styles.kpiValue, { color: C.green }]}>$ {formatAmount(totalForMe)}</Text>
        {customersForMe > 0 ? (
          <Text style={styles.kpiHint}>من {toLatinDigits(customersForMe)} عميل</Text>
        ) : null}
      </View>

      <View style={styles.kpiBox}>
        <Text style={styles.kpiLabel}>إجمالي ديوني (علينا)</Text>
        <Text style={[styles.kpiValue, { color: C.red }]}>$ {formatAmount(totalOnMe)}</Text>
        {customersOnMe > 0 ? (
          <Text style={styles.kpiHint}>إلى {toLatinDigits(customersOnMe)} عميل</Text>
        ) : null}
      </View>
    </View>
  );
}

function TransactionsCount({ data }: { data: TransactionsCountData }) {
  const { today, week, month, yesterday, previousMonth, weeklyTrend } = data;

  const total = (today || 0) + (week || 0) + (month || 0);
  const yesterdayDelta = yesterday != null ? today - yesterday : null;
  const monthDeltaPct =
    previousMonth && previousMonth > 0
      ? Math.round(((month - previousMonth) / previousMonth) * 100)
      : null;

  const weekAvg = week > 0 ? (week / 7).toFixed(1) : '0';

  const trend = weeklyTrend && weeklyTrend.length > 0 ? weeklyTrend : [3, 5, 4, 7, 5, 8, today || 0];
  const trendMax = Math.max(...trend, 1);

  return (
    <View>
      <SectionHeader
        title="عدد الحوالات"
        rightSlot={
          <View style={styles.sectionHeaderIconWrap}>
            <View style={styles.sectionHeaderIconCircle}>
              <ArrowLeftRight size={14} color={C.purple} />
            </View>
          </View>
        }
      />

      <View style={styles.cardOutlined}>
        <View style={styles.txCountRow}>
          <View style={[styles.txCountCol, styles.txCountColBorder, styles.txCountColToday]}>
            <Text style={styles.txCountLabel}>اليوم</Text>
            <Text style={styles.txCountValue}>{toLatinDigits(today)}</Text>

            {yesterdayDelta != null ? (
              <Text style={[styles.txCountHint, { color: yesterdayDelta >= 0 ? C.green : C.red }]}>
                {yesterdayDelta >= 0 ? '+' : '−'}
                {toLatinDigits(Math.abs(yesterdayDelta))} عن أمس
              </Text>
            ) : (
              <Text style={styles.txCountHint}>—</Text>
            )}
          </View>

          <View style={[styles.txCountCol, styles.txCountColBorder]}>
            <Text style={styles.txCountLabel}>هذا الأسبوع</Text>
            <Text style={styles.txCountValue}>{toLatinDigits(week)}</Text>
            <Text style={styles.txCountHint}>معدل {toLatinDigits(weekAvg)} / يوم</Text>
          </View>

          <View style={styles.txCountCol}>
            <Text style={styles.txCountLabel}>هذا الشهر</Text>
            <Text style={styles.txCountValue}>{toLatinDigits(month)}</Text>

            {monthDeltaPct != null ? (
              <Text style={[styles.txCountHint, { color: monthDeltaPct >= 0 ? C.green : C.red }]}>
                {monthDeltaPct >= 0 ? '+' : '−'}
                {toLatinDigits(Math.abs(monthDeltaPct))}٪ عن السابق
              </Text>
            ) : (
              <Text style={styles.txCountHint}>—</Text>
            )}
          </View>
        </View>

        <View style={styles.sparkRow}>
          {trend.slice(-7).map((v, i, arr) => {
            const isLast = i === arr.length - 1;
            const heightPct = Math.max(8, Math.round((v / trendMax) * 100));

            return (
              <View
                key={i}
                style={{
                  flex: 1,
                  height: `${heightPct}%`,
                  backgroundColor: isLast ? C.blueLink : C.blueSoft,
                  borderTopLeftRadius: 3,
                  borderTopRightRadius: 3,
                  marginHorizontal: 2,
                }}
              />
            );
          })}
        </View>
      </View>

      <View style={styles.txCountFooter}>
        <Text style={styles.txCountFooterText}>إجمالي الفترة {toLatinDigits(total)}</Text>
      </View>
    </View>
  );
}

function CurrencyLedger({ rows }: { rows: CurrencyLedgerRow[] }) {
  if (rows.length === 0) {
    return (
      <View>
        <SectionHeader title="حركة الحساب حسب العملة" />
        <View style={styles.cardOutlined}>
          <Text style={styles.emptyText}>لا توجد حركات حسابية في الفترة المحددة</Text>
        </View>
      </View>
    );
  }

  return (
    <View>
      <SectionHeader
        title="حركة الحساب حسب العملة"
        rightSlot={
          <TouchableOpacity activeOpacity={0.7}>
            <Text style={styles.linkText}>عرض الكل</Text>
          </TouchableOpacity>
        }
      />

      <View style={styles.cardOutlined}>
        <View style={styles.ledgerHeaderRow}>
          <Text style={[styles.ledgerHeaderCell, styles.colCurrency]}>العملة</Text>
          <Text style={[styles.ledgerHeaderCell, styles.colFlex]}>لنا</Text>
          <Text style={[styles.ledgerHeaderCell, styles.colFlex]}>علينا</Text>
          <Text style={[styles.ledgerHeaderCell, styles.colFlex]}>الصافي</Text>
          <View style={styles.colChevron} />
        </View>

        {rows.map((row, idx) => {
          const netColor =
            row.direction === 'for_me'
              ? C.green
              : row.direction === 'on_me'
                ? C.red
                : C.muted;

          const sign = row.direction === 'for_me' ? '+ ' : row.direction === 'on_me' ? '− ' : '';

          return (
            <TouchableOpacity
              key={row.currency}
              activeOpacity={0.7}
              style={[
                styles.ledgerDataRow,
                idx !== rows.length - 1 && styles.ledgerRowDivider,
              ]}
            >
              <View style={styles.colCurrency}>
                <Text style={styles.ledgerCurrencyCode}>{row.currency}</Text>
              </View>

              <View style={styles.colFlex}>
                <Text style={[styles.ledgerNumber, { color: C.green }]}>
                  {formatAmount(row.totalForMe)}
                </Text>
                {row.countForMe > 0 ? (
                  <Text style={styles.ledgerSubNumber}>
                    {toLatinDigits(row.countForMe)} {row.countForMe === 1 ? 'حركة' : 'حركات'}
                  </Text>
                ) : null}
              </View>

              <View style={styles.colFlex}>
                <Text style={[styles.ledgerNumber, { color: C.red }]}>
                  {formatAmount(row.totalOnMe)}
                </Text>
                {row.countOnMe > 0 ? (
                  <Text style={styles.ledgerSubNumber}>
                    {toLatinDigits(row.countOnMe)} {row.countOnMe === 1 ? 'حركة' : 'حركات'}
                  </Text>
                ) : null}
              </View>

              <View style={styles.colFlex}>
                <Text style={[styles.ledgerNet, { color: netColor }]}>
                  {row.direction === 'balanced' ? '0' : `${sign}${formatAmount(row.finalAmount)}`}
                </Text>
              </View>

              <View style={styles.colChevron}>
                <ChevronLeft size={11} color={C.faint} />
              </View>
            </TouchableOpacity>
          );
        })}
      </View>
    </View>
  );
}

function PendingOperations({
  awaitingMineCount,
  awaitingMineAmount,
  awaitingMineCustomers,
  awaitingMineOldest,
  awaitingOthersCount,
  awaitingOthersAmount,
  awaitingOthersCustomers,
  awaitingOthersOldest,
  onPress,
}: {
  awaitingMineCount: number;
  awaitingMineAmount: number;
  awaitingMineCustomers: number;
  awaitingMineOldest: string;
  awaitingOthersCount: number;
  awaitingOthersAmount: number;
  awaitingOthersCustomers: number;
  awaitingOthersOldest: string;
  onPress: () => void;
}) {
  const totalPending = awaitingMineCount + awaitingOthersCount;

  const mySubtitle = joinMetaParts([
    awaitingMineCount > 0 && `${toLatinDigits(awaitingMineCount)} عمليات`,
    awaitingMineCustomers > 0 && `${toLatinDigits(awaitingMineCustomers)} عملاء`,
    awaitingMineOldest && `أقدمها ${awaitingMineOldest}`,
  ]);

  const othersSubtitle = joinMetaParts([
    awaitingOthersCount > 0 && `${toLatinDigits(awaitingOthersCount)} عملية`,
    awaitingOthersCustomers > 0 && `${toLatinDigits(awaitingOthersCustomers)} عملاء`,
    awaitingOthersOldest && `أقدمها ${awaitingOthersOldest}`,
  ]);

  return (
    <View>
      <SectionHeader
        title="الحركات بانتظار المراجعة"
        rightSlot={
          <View style={styles.pendingBadge}>
            <Text style={styles.pendingBadgeText}>{toLatinDigits(totalPending)} معلّق</Text>
          </View>
        }
      />

      <View style={styles.cardOutlined}>
        <TouchableOpacity
          style={[styles.pendingRow, styles.ledgerRowDivider]}
          activeOpacity={0.7}
          onPress={onPress}
        >
          <View style={[styles.pendingIconCircle, { backgroundColor: C.yellowSoft }]}>
            <Clock3 size={17} color={C.yellow} />
          </View>

          <View style={styles.pendingTextWrap}>
            <Text style={styles.pendingTitle}>بانتظار موافقتي</Text>
            {mySubtitle ? <Text style={styles.pendingSubtitle}>{mySubtitle}</Text> : null}
          </View>

          <View style={styles.pendingAmountWrap}>
            <Text style={[styles.pendingAmount, { color: C.yellow }]}>
              $ {formatAmount(awaitingMineAmount)}
            </Text>
          </View>

          <ChevronLeft size={11} color={C.faint} />
        </TouchableOpacity>

        <TouchableOpacity style={styles.pendingRow} activeOpacity={0.7} onPress={onPress}>
          <View style={[styles.pendingIconCircle, { backgroundColor: C.blueSoft }]}>
            <Users size={17} color={C.blue} />
          </View>

          <View style={styles.pendingTextWrap}>
            <Text style={styles.pendingTitle}>بانتظار العملاء</Text>
            {othersSubtitle ? <Text style={styles.pendingSubtitle}>{othersSubtitle}</Text> : null}
          </View>

          <View style={styles.pendingAmountWrap}>
            <Text style={[styles.pendingAmount, { color: C.blue }]}>
              $ {formatAmount(awaitingOthersAmount)}
            </Text>
          </View>

          <ChevronLeft size={11} color={C.faint} />
        </TouchableOpacity>
      </View>
    </View>
  );
}

function TopCustomers({ customers }: { customers: TopCustomerRow[] }) {
  if (customers.length === 0) return null;

  return (
    <View>
      <SectionHeader
        title="أعلى 3 أرصدة عملاء"
        rightSlot={
          <TouchableOpacity activeOpacity={0.7}>
            <Text style={styles.linkText}>عرض الكل</Text>
          </TouchableOpacity>
        }
      />

      <View style={[styles.cardOutlined, { marginBottom: 16 }]}>
        {customers.map((c, idx) => {
          const color = c.direction === 'for_me' ? C.green : C.red;
          const sign = c.direction === 'for_me' ? '+ ' : '− ';

          const subtitle = joinMetaParts([
            c.count > 0 && `${toLatinDigits(c.count)} حركات`,
            c.lastActivity && `آخر حركة ${c.lastActivity}`,
          ]);

          return (
            <TouchableOpacity
              key={c.id}
              style={[
                styles.customerRow,
                idx !== customers.length - 1 && styles.ledgerRowDivider,
              ]}
              activeOpacity={0.7}
            >
              <View style={styles.customerAvatar}>
                <Text style={styles.customerAvatarText}>{c.initials}</Text>
              </View>

              <View style={styles.customerTextWrap}>
                <Text style={styles.customerName}>{c.name}</Text>
                {subtitle ? <Text style={styles.customerSub}>{subtitle}</Text> : null}
              </View>

              <View style={styles.customerAmountWrap}>
                <Text style={[styles.customerAmount, { color }]}>
                  {sign}
                  {formatAmount(Math.abs(c.amount))} {c.currency}
                </Text>
              </View>
            </TouchableOpacity>
          );
        })}
      </View>
    </View>
  );
}

// ============================================================
// Main screen
// ============================================================

export default function StatisticsScreen() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const { lastRefreshTime } = useDataRefresh();

  const [stats, setStats] = useState<StatisticsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const loadStats = useCallback(async () => {
    if (!currentUser?.userId) {
      setStats(null);
      setLoading(false);
      return;
    }

    try {
      const data = await StatisticsService.fetchAllStatistics(currentUser.userId);
      setStats(data);
    } catch (error) {
      console.error('[StatisticsScreen] loadStats failed:', error);
    } finally {
      setLoading(false);
    }
  }, [currentUser?.userId]);

  useEffect(() => {
    setLoading(true);
    loadStats();
  }, [loadStats]);

  useEffect(() => {
    if (!loading && currentUser?.userId) {
      loadStats();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lastRefreshTime, currentUser?.userId]);

  const onRefresh = async () => {
    setRefreshing(true);
    await loadStats();
    setRefreshing(false);
  };

  const ledgerRows = useMemo(() => buildCurrencyLedgerRows(stats), [stats]);
  const topCustomers = useMemo(() => buildTopCustomers(stats), [stats]);
  const txCount = useMemo(() => buildTxCount(stats), [stats]);

  const totalForMe = useMemo(
    () => sumCurrencyList(stats?.debtStats?.owedToUsByCurrency as any),
    [stats],
  );

  const totalOnMe = useMemo(
    () => sumCurrencyList(stats?.debtStats?.weOweByCurrency as any),
    [stats],
  );

  const customersForMe = Number((stats?.debtStats as any)?.customersOwingUsCount || 0);
  const customersOnMe = Number((stats?.debtStats as any)?.customersWeOweCount || 0);

  const pendingMineAmount = useMemo(
    () => sumCurrencyList(stats?.actionableStats?.awaitingMyApprovalByCurrency as any),
    [stats],
  );

  const pendingOthersAmount = useMemo(
    () => sumCurrencyList(stats?.actionableStats?.awaitingOthersApprovalByCurrency as any),
    [stats],
  );

  const pendingMineCustomers = Number(
    (stats?.actionableStats as any)?.awaitingMyApprovalCustomersCount || 0,
  );

  const pendingOthersCustomers = Number(
    (stats?.actionableStats as any)?.awaitingOthersApprovalCustomersCount || 0,
  );

  const pendingMineOldest = String(
    (stats?.actionableStats as any)?.awaitingMyApprovalOldestLabel || '',
  );

  const pendingOthersOldest = String(
    (stats?.actionableStats as any)?.awaitingOthersApprovalOldestLabel || '',
  );

  const goToNotifications = () => {
    router.push('/(tabs)/notifications' as any);
  };

  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color={C.purple} />
        <Text style={styles.loadingText}>جاري تحميل الإحصائيات...</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <TopBar onBack={() => router.back()} />

      <ScrollView
        style={styles.screen}
        contentContainerStyle={styles.contentContainer}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        showsVerticalScrollIndicator={false}
      >
        <KPISummary
          totalForMe={totalForMe}
          totalOnMe={totalOnMe}
          customersForMe={customersForMe}
          customersOnMe={customersOnMe}
        />

        <TransactionsCount data={txCount} />
        <CurrencyLedger rows={ledgerRows} />

        <PendingOperations
          awaitingMineCount={Number(stats?.actionableStats?.awaitingMyApprovalCount || 0)}
          awaitingMineAmount={pendingMineAmount}
          awaitingMineCustomers={pendingMineCustomers}
          awaitingMineOldest={pendingMineOldest}
          awaitingOthersCount={Number(stats?.actionableStats?.awaitingOthersApprovalCount || 0)}
          awaitingOthersAmount={pendingOthersAmount}
          awaitingOthersCustomers={pendingOthersCustomers}
          awaitingOthersOldest={pendingOthersOldest}
          onPress={goToNotifications}
        />

        <TopCustomers customers={topCustomers} />
      </ScrollView>
    </View>
  );
}

// ============================================================
// Styles
// ============================================================

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: C.bg,
  },

  screen: {
    flex: 1,
  },

  contentContainer: {
    paddingBottom: 28,
  },

  loadingContainer: {
    flex: 1,
    backgroundColor: C.bg,
    justifyContent: 'center',
    alignItems: 'center',
    gap: 14,
  },

  loadingText: {
    fontSize: 15,
    color: C.muted,
    fontWeight: '700',
    writingDirection: 'rtl',
  },

  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingVertical: 16,
    borderBottomWidth: 1,
    borderBottomColor: C.border,
  },

  iconBtn: {
    width: 38,
    height: 38,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: C.border,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: C.bg,
  },

  iconBtnPlaceholder: {
    width: 38,
    height: 38,
  },

  topTitleWrap: {
    alignItems: 'center',
  },

  topTitle: {
    fontSize: 22,
    fontWeight: '900',
    color: C.text,
    writingDirection: 'rtl',
  },

  topSubtitle: {
    fontSize: 13,
    color: C.muted,
    marginTop: 3,
    fontWeight: '500',
    writingDirection: 'rtl',
  },

  kpiRow: {
    flexDirection: 'row',
    borderBottomWidth: 1,
    borderBottomColor: C.border,
  },

  kpiBox: {
    flex: 1,
    paddingVertical: 16,
    paddingHorizontal: 16,
  },

  kpiBoxLeftBorder: {
    borderLeftWidth: 1,
    borderLeftColor: C.border,
  },

  kpiLabel: {
    fontSize: 13,
    color: C.muted,
    marginBottom: 6,
    textAlign: 'right',
    fontWeight: '600',
    writingDirection: 'rtl',
  },

  kpiValue: {
    fontSize: 22,
    fontWeight: '900',
    textAlign: 'right',
    writingDirection: 'rtl',
  },

  kpiHint: {
    fontSize: 12,
    color: C.muted,
    marginTop: 4,
    textAlign: 'right',
    writingDirection: 'rtl',
  },

  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingTop: 20,
    paddingBottom: 10,
  },

  sectionHeaderTitle: {
    fontSize: 17,
    fontWeight: '900',
    color: C.text,
    textAlign: 'right',
    writingDirection: 'rtl',
  },

  sectionHeaderIconWrap: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },

  sectionHeaderIconCircle: {
    width: 28,
    height: 28,
    borderRadius: 8,
    backgroundColor: C.purpleSoft,
    alignItems: 'center',
    justifyContent: 'center',
  },

  linkText: {
    fontSize: 13,
    color: C.blueLink,
    fontWeight: '700',
    writingDirection: 'rtl',
  },

  emptyText: {
    fontSize: 14,
    color: C.muted,
    textAlign: 'center',
    padding: 20,
    fontWeight: '500',
    writingDirection: 'rtl',
  },

  cardOutlined: {
    marginHorizontal: 16,
    borderWidth: 1,
    borderColor: C.border,
    borderRadius: 16,
    overflow: 'hidden',
    backgroundColor: C.bg,
  },

  txCountRow: {
    flexDirection: 'row',
  },

  txCountCol: {
    flex: 1,
    paddingVertical: 18,
    paddingHorizontal: 10,
    alignItems: 'center',
  },

  txCountColBorder: {
    borderLeftWidth: 1,
    borderLeftColor: C.border,
  },

  txCountColToday: {
    backgroundColor: C.bgSofter,
  },

  txCountLabel: {
    fontSize: 12,
    color: C.muted,
    fontWeight: '600',
    writingDirection: 'rtl',
  },

  txCountValue: {
    fontSize: 30,
    fontWeight: '900',
    color: C.text,
    marginTop: 8,
    marginBottom: 4,
  },

  txCountHint: {
    fontSize: 11,
    color: C.muted,
    fontWeight: '600',
    writingDirection: 'rtl',
    textAlign: 'center',
  },

  sparkRow: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    height: 36,
    paddingHorizontal: 12,
    paddingTop: 8,
    paddingBottom: 10,
    borderTopWidth: 1,
    borderTopColor: C.border,
    backgroundColor: C.bgSofter,
  },

  txCountFooter: {
    paddingHorizontal: 16,
    paddingTop: 8,
    alignItems: 'flex-start',
  },

  txCountFooterText: {
    fontSize: 12,
    color: C.muted,
    fontWeight: '500',
    writingDirection: 'rtl',
  },

  ledgerHeaderRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 10,
    backgroundColor: C.bgSoft,
    borderBottomWidth: 1,
    borderBottomColor: C.border,
  },

  ledgerHeaderCell: {
    fontSize: 11,
    color: C.muted,
    fontWeight: '700',
    textAlign: 'center',
    writingDirection: 'rtl',
  },

  colCurrency: {
    width: 52,
    alignItems: 'center',
  },

  colFlex: {
    flex: 1,
    alignItems: 'center',
  },

  colChevron: {
    width: 18,
    alignItems: 'center',
  },

  ledgerDataRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 14,
  },

  ledgerRowDivider: {
    borderBottomWidth: 1,
    borderBottomColor: C.border,
  },

  ledgerCurrencyCode: {
    fontSize: 12,
    fontWeight: '700',
    color: C.muted,
    textAlign: 'center',
  },

  ledgerNumber: {
    fontSize: 14,
    fontWeight: '800',
    textAlign: 'center',
  },

  ledgerSubNumber: {
    fontSize: 10,
    color: C.faint,
    marginTop: 2,
    textAlign: 'center',
    writingDirection: 'rtl',
  },

  ledgerNet: {
    fontSize: 15,
    fontWeight: '900',
    textAlign: 'center',
  },

  pendingBadge: {
    backgroundColor: C.redSoft,
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 999,
  },

  pendingBadgeText: {
    fontSize: 11,
    color: C.red,
    fontWeight: '700',
    writingDirection: 'rtl',
  },

  pendingRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 14,
    paddingVertical: 14,
    gap: 12,
  },

  pendingIconCircle: {
    width: 38,
    height: 38,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
  },

  pendingTextWrap: {
    flex: 1,
    minWidth: 0,
  },

  pendingTitle: {
    fontSize: 14,
    fontWeight: '800',
    color: C.text,
    textAlign: 'right',
    writingDirection: 'rtl',
  },

  pendingSubtitle: {
    fontSize: 11,
    color: C.muted,
    marginTop: 3,
    textAlign: 'right',
    writingDirection: 'rtl',
  },

  pendingAmountWrap: {
    alignItems: 'flex-start',
  },

  pendingAmount: {
    fontSize: 14,
    fontWeight: '900',
  },

  customerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 14,
    paddingVertical: 13,
    gap: 12,
  },

  customerAvatar: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: C.avatarBg,
    alignItems: 'center',
    justifyContent: 'center',
  },

  customerAvatarText: {
    fontSize: 12,
    fontWeight: '800',
    color: C.avatarText,
  },

  customerTextWrap: {
    flex: 1,
    minWidth: 0,
  },

  customerName: {
    fontSize: 14,
    fontWeight: '800',
    color: C.text,
    textAlign: 'right',
    writingDirection: 'rtl',
  },

  customerSub: {
    fontSize: 11,
    color: C.muted,
    marginTop: 3,
    textAlign: 'right',
    writingDirection: 'rtl',
  },

  customerAmountWrap: {
    alignItems: 'flex-start',
  },

  customerAmount: {
    fontSize: 14,
    fontWeight: '900',
  },
});