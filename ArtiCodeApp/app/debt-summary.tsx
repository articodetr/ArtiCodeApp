import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Alert,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, Download } from 'lucide-react-native';
import * as Print from 'expo-print';
import * as Sharing from 'expo-sharing';

import { supabase } from '@/lib/supabase';
import { CustomerBalanceByCurrency, CURRENCIES } from '@/types/database';
import { generatePDFHeaderHTML, generatePDFHeaderStyles } from '@/utils/pdfHeaderGenerator';
import { getLogoBase64 } from '@/utils/logoHelper';
import { useAuth } from '@/contexts/AuthContext';
import { useDataRefresh } from '@/contexts/DataRefreshContext';
import { buildStatisticsCustomerFilter } from '@/services/userScopeService';

type CustomerRow = {
  id: string;
  name: string;
  accountNumber: string;
};

type ReportRow = {
  key: string;
  customerId: string;
  customerName: string;
  accountNumber: string;
  currency: string;
  currencyName: string;
  currencySymbol: string;
  amount: number;
  statusLabel: 'له' | 'عليه' | 'متساوي';
  statusColor: string;
  statusBg: string;
  amountPrefix: '+' | '-' | '';
};

function formatAmount(value: number) {
  return Number(value || 0).toLocaleString('en-US', {
    maximumFractionDigits: 2,
    minimumFractionDigits: Number(value || 0) % 1 === 0 ? 0 : 2,
  });
}

function toLatinDigits(input: number | string) {
  const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
  const easternArabicIndic = '۰۱۲۳۴۵۶۷۸۹';

  return String(input ?? '')
    .replace(/[٠-٩]/g, (d) => String(arabicIndic.indexOf(d)))
    .replace(/[۰-۹]/g, (d) => String(easternArabicIndic.indexOf(d)));
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

function getBalanceMeta(amount: number) {
  if (amount > 0) {
    return { label: 'له' as const, color: '#16A34A', bg: '#ECFDF3', sign: '+' as const };
  }

  if (amount < 0) {
    return { label: 'عليه' as const, color: '#DC2626', bg: '#FEF2F2', sign: '-' as const };
  }

  return { label: 'متساوي' as const, color: '#6B7280', bg: '#F3F4F6', sign: '' as const };
}

export default function DebtSummaryScreen() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const { lastRefreshTime } = useDataRefresh();

  const [rows, setRows] = useState<ReportRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [isGeneratingPdf, setIsGeneratingPdf] = useState(false);
  const hasLoadedOnceRef = useRef(false);

  const loadData = useCallback(
    async (options?: { silent?: boolean }) => {
      const silent = options?.silent === true;

      try {
        if (!silent) {
          setIsLoading(true);
        }

        if (!currentUser?.userId) {
          setRows([]);
          return;
        }

        const { data: customersData, error: customersError } = await supabase
          .from('customers')
          .select('id, name, account_number, is_profit_loss_account')
          .or(buildStatisticsCustomerFilter(currentUser.userId))
          .order('name', { ascending: true });

        if (customersError) {
          throw customersError;
        }

        const visibleCustomers = ((customersData || []) as any[])
          .filter((customer) => !customer.is_profit_loss_account)
          .map(
            (customer) =>
              ({
                id: customer.id,
                name: customer.name,
                accountNumber: customer.account_number || '-',
              }) satisfies CustomerRow,
          );

        if (visibleCustomers.length === 0) {
          setRows([]);
          hasLoadedOnceRef.current = true;
          return;
        }

        const customerMap = new Map<string, CustomerRow>(
          visibleCustomers.map((customer) => [customer.id, customer]),
        );

        const customerIds = visibleCustomers.map((customer) => customer.id);

        const { data: balancesData, error: balancesError } = await supabase
          .from('customer_balances_by_currency')
          .select('*')
          .in('customer_id', customerIds)
          .order('customer_name', { ascending: true });

        if (balancesError) {
          throw balancesError;
        }

        const nextRows: ReportRow[] = ((balancesData || []) as CustomerBalanceByCurrency[])
          .map((balance) => {
            const customer = customerMap.get(balance.customer_id);
            if (!customer) return null;

            const amount = Number((balance as any).balance || 0);
            const currencyInfo = getCurrencyInfo(balance.currency);
            const meta = getBalanceMeta(amount);

            return {
              key: `${balance.customer_id}-${balance.currency}`,
              customerId: balance.customer_id,
              customerName: customer.name || (balance as any).customer_name || 'عميل',
              accountNumber: customer.accountNumber || '-',
              currency: balance.currency,
              currencyName: currencyInfo.name,
              currencySymbol: currencyInfo.symbol,
              amount,
              statusLabel: meta.label,
              statusColor: meta.color,
              statusBg: meta.bg,
              amountPrefix: meta.sign,
            } satisfies ReportRow;
          })
          .filter((item): item is ReportRow => Boolean(item))
          .sort((a, b) => {
            const customerCompare = a.customerName.localeCompare(b.customerName, 'ar');
            if (customerCompare !== 0) return customerCompare;
            return a.currency.localeCompare(b.currency);
          });

        setRows(nextRows);
        hasLoadedOnceRef.current = true;
      } catch (error) {
        console.error('[DebtSummary] Error loading report:', error);
        Alert.alert('خطأ', 'تعذر تحميل تقرير الديون الشامل');
        if (!silent) {
          setRows([]);
        }
      } finally {
        if (!silent) {
          setIsLoading(false);
        }
      }
    },
    [currentUser?.userId],
  );

  useEffect(() => {
    if (!currentUser?.userId) {
      setRows([]);
      setIsLoading(false);
      hasLoadedOnceRef.current = false;
      return;
    }

    loadData({ silent: false });
  }, [currentUser?.userId, loadData]);

  useEffect(() => {
    if (!currentUser?.userId) return;
    if (!hasLoadedOnceRef.current) return;

    loadData({ silent: true });
  }, [lastRefreshTime, currentUser?.userId, loadData]);

  const onRefresh = async () => {
    setRefreshing(true);
    try {
      await loadData({ silent: true });
    } finally {
      setRefreshing(false);
    }
  };

  const summary = useMemo(() => {
    const uniqueCustomers = new Set(rows.map((row) => row.customerId)).size;
    return {
      customersCount: uniqueCustomers,
      balancesCount: rows.length,
    };
  }, [rows]);

  const generatePDF = async () => {
    try {
      setIsGeneratingPdf(true);

      let logoDataUrl: string | undefined;
      try {
        logoDataUrl = await getLogoBase64(false, null, { userId: currentUser?.userId });
      } catch (logoError) {
        console.warn('[DebtSummary] Could not load logo:', logoError);
      }

      const headerHTML = generatePDFHeaderHTML({
        title: 'تقرير الديون الشامل',
        logoDataUrl,
        primaryColor: '#5B5AF7',
        darkColor: '#3730A3',
        height: 150,
        showPhones: true,
      });

      const rowsHtml = rows
        .map(
          (row) => `
            <tr>
              <td>${row.customerName}</td>
              <td>${row.accountNumber || '-'}</td>
              <td>${row.currencyName}</td>
              <td>
                <span style="
                  display:inline-block;
                  padding:4px 10px;
                  border-radius:999px;
                  background:${row.statusBg};
                  color:${row.statusColor};
                  font-weight:700;
                  font-size:12px;
                ">
                  ${row.statusLabel}
                </span>
              </td>
              <td style="font-weight:700; color:${row.statusColor};">
                ${row.amountPrefix ? `${row.amountPrefix} ` : ''}${formatAmount(Math.abs(row.amount))} ${row.currencySymbol}
              </td>
            </tr>
          `,
        )
        .join('');

      const html = `
        <html dir="rtl" lang="ar">
          <head>
            <meta charset="utf-8" />
            <style>
              ${generatePDFHeaderStyles()}
              body {
                font-family: Arial, sans-serif;
                direction: rtl;
                color: #111827;
                margin: 0;
                padding: 0;
                background: #ffffff;
              }
              .page {
                padding: 24px;
              }
              .summary {
                display: flex;
                gap: 12px;
                margin-bottom: 18px;
                flex-wrap: wrap;
              }
              .summary-box {
                border: 1px solid #E5E7EB;
                border-radius: 12px;
                padding: 12px 14px;
                min-width: 150px;
                background: #F9FAFB;
              }
              .summary-label {
                font-size: 12px;
                color: #6B7280;
                margin-bottom: 6px;
              }
              .summary-value {
                font-size: 18px;
                font-weight: 800;
                color: #111827;
              }
              table {
                width: 100%;
                border-collapse: collapse;
                margin-top: 8px;
                font-size: 13px;
              }
              th {
                background: #F8FAFC;
                color: #374151;
                font-weight: 700;
                border: 1px solid #E5E7EB;
                padding: 10px;
                text-align: center;
              }
              td {
                border: 1px solid #E5E7EB;
                padding: 10px;
                text-align: center;
              }
              .empty {
                text-align: center;
                padding: 24px;
                color: #6B7280;
                border: 1px solid #E5E7EB;
                border-radius: 14px;
                margin-top: 18px;
              }
            </style>
          </head>
          <body>
            ${headerHTML}
            <div class="page">
              <div class="summary">
                <div class="summary-box">
                  <div class="summary-label">عدد العملاء</div>
                  <div class="summary-value">${toLatinDigits(summary.customersCount)}</div>
                </div>
                <div class="summary-box">
                  <div class="summary-label">عدد الصفوف</div>
                  <div class="summary-value">${toLatinDigits(summary.balancesCount)}</div>
                </div>
              </div>

              ${
                rowsHtml
                  ? `
                    <table>
                      <thead>
                        <tr>
                          <th>اسم العميل</th>
                          <th>رقم الحساب</th>
                          <th>العملة</th>
                          <th>الحالة</th>
                          <th>المبلغ</th>
                        </tr>
                      </thead>
                      <tbody>
                        ${rowsHtml}
                      </tbody>
                    </table>
                  `
                  : `<div class="empty">لا توجد بيانات</div>`
              }
            </div>
          </body>
        </html>
      `;

      const { uri } = await Print.printToFileAsync({ html });

      if (await Sharing.isAvailableAsync()) {
        await Sharing.shareAsync(uri);
      } else {
        Alert.alert('نجح', 'تم إنشاء التقرير بنجاح');
      }
    } catch (error) {
      console.error('[DebtSummary] Error generating PDF:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء إنشاء التقرير');
    } finally {
      setIsGeneratingPdf(false);
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.topHeader}>
        <TouchableOpacity
          style={styles.topIconButton}
          onPress={() => router.back()}
          activeOpacity={0.8}
        >
          <ArrowRight size={20} color="#1E1B4B" />
        </TouchableOpacity>

        <View style={styles.titleWrap}>
          <Text style={styles.pageTitle}>تقرير الديون الشامل</Text>
          <Text style={styles.pageSubtitle}>عرض مبسط على شكل بيانات واضحة</Text>
        </View>

        <TouchableOpacity
          style={styles.topActionButton}
          onPress={generatePDF}
          activeOpacity={0.8}
          disabled={isGeneratingPdf}
        >
          <Download size={16} color="#5B5AF7" />
          <Text style={styles.topActionText}>{isGeneratingPdf ? 'جاري...' : 'PDF'}</Text>
        </TouchableOpacity>
      </View>

      <ScrollView
        style={styles.screen}
        contentContainerStyle={styles.contentContainer}
        showsVerticalScrollIndicator={false}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
      >
        <View style={styles.summaryRow}>
          <View style={styles.summaryCard}>
            <Text style={styles.summaryValue}>{toLatinDigits(summary.customersCount)}</Text>
            <Text style={styles.summaryLabel}>عدد العملاء</Text>
          </View>

          <View style={styles.summaryCard}>
            <Text style={styles.summaryValue}>{toLatinDigits(summary.balancesCount)}</Text>
            <Text style={styles.summaryLabel}>عدد الصفوف</Text>
          </View>
        </View>

        <View style={styles.tableCard}>
          <View style={styles.tableHeader}>
            <Text style={[styles.headerCell, styles.customerCell]}>العميل</Text>
            <Text style={[styles.headerCell, styles.currencyCell]}>العملة</Text>
            <Text style={[styles.headerCell, styles.statusCell]}>الحالة</Text>
            <Text style={[styles.headerCell, styles.amountCell]}>المبلغ</Text>
          </View>

          {isLoading ? (
            <View style={styles.emptyBox}>
              <Text style={styles.emptyText}>جاري التحميل...</Text>
            </View>
          ) : rows.length === 0 ? (
            <View style={styles.emptyBox}>
              <Text style={styles.emptyText}>لا توجد بيانات</Text>
            </View>
          ) : (
            rows.map((row, index) => (
              <View
                key={row.key}
                style={[styles.tableRow, index !== rows.length - 1 && styles.rowBorder]}
              >
                <View style={styles.customerCell}>
                  <Text style={styles.customerName}>{row.customerName}</Text>
                  <Text style={styles.accountNumber}>#{row.accountNumber || '-'}</Text>
                </View>

                <View style={styles.currencyCell}>
                  <Text style={styles.currencyCode}>{row.currency}</Text>
                  <Text style={styles.currencyName}>{row.currencyName}</Text>
                </View>

                <View style={styles.statusCell}>
                  <View style={[styles.statusPill, { backgroundColor: row.statusBg }]}>
                    <Text style={[styles.statusPillText, { color: row.statusColor }]}>
                      {row.statusLabel}
                    </Text>
                  </View>
                </View>

                <View style={styles.amountCell}>
                  <Text style={[styles.amountText, { color: row.statusColor }]}>
                    {row.amountPrefix ? `${row.amountPrefix} ` : ''}
                    {formatAmount(Math.abs(row.amount))} {row.currencySymbol}
                  </Text>
                </View>
              </View>
            ))
          )}
        </View>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F7F7FC',
  },
  screen: {
    flex: 1,
  },
  contentContainer: {
    paddingHorizontal: 14,
    paddingBottom: 24,
  },

  topHeader: {
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 10,
    paddingHorizontal: 14,
    paddingTop: 8,
    paddingBottom: 14,
  },
  titleWrap: {
    flex: 1,
    alignItems: 'center',
  },
  pageTitle: {
    fontSize: 22,
    fontWeight: '900',
    color: '#1E1B4B',
    textAlign: 'center',
  },
  pageSubtitle: {
    marginTop: 4,
    fontSize: 12,
    color: '#7C84A3',
    fontWeight: '500',
    textAlign: 'center',
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
  topActionButton: {
    minWidth: 72,
    height: 42,
    paddingHorizontal: 12,
    borderRadius: 14,
    backgroundColor: '#FFFFFF',
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 6,
    shadowColor: '#0F172A',
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.04,
    shadowRadius: 10,
    elevation: 2,
  },
  topActionText: {
    fontSize: 13,
    color: '#5B5AF7',
    fontWeight: '800',
  },

  summaryRow: {
    flexDirection: 'row',
    gap: 10,
    marginBottom: 14,
  },
  summaryCard: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    paddingVertical: 16,
    paddingHorizontal: 14,
    borderWidth: 1,
    borderColor: '#ECECF7',
    alignItems: 'center',
    justifyContent: 'center',
  },
  summaryValue: {
    fontSize: 22,
    fontWeight: '900',
    color: '#1E1B4B',
  },
  summaryLabel: {
    marginTop: 4,
    fontSize: 12,
    color: '#7C84A3',
    fontWeight: '600',
  },

  tableCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    borderWidth: 1,
    borderColor: '#ECECF7',
    overflow: 'hidden',
  },
  tableHeader: {
    flexDirection: 'row-reverse',
    backgroundColor: '#F8FAFC',
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
    paddingVertical: 12,
    paddingHorizontal: 12,
  },
  headerCell: {
    fontSize: 12,
    fontWeight: '800',
    color: '#475569',
    textAlign: 'center',
  },

  tableRow: {
    flexDirection: 'row-reverse',
    alignItems: 'center',
    paddingVertical: 12,
    paddingHorizontal: 12,
    backgroundColor: '#FFFFFF',
  },
  rowBorder: {
    borderBottomWidth: 1,
    borderBottomColor: '#EEF2F7',
  },

  customerCell: {
    flex: 1.6,
    alignItems: 'flex-end',
    paddingHorizontal: 4,
  },
  currencyCell: {
    flex: 1,
    alignItems: 'center',
    paddingHorizontal: 4,
  },
  statusCell: {
    flex: 0.9,
    alignItems: 'center',
    paddingHorizontal: 4,
  },
  amountCell: {
    flex: 1.2,
    alignItems: 'flex-start',
    paddingHorizontal: 4,
  },

  customerName: {
    fontSize: 13,
    fontWeight: '800',
    color: '#1E1B4B',
    textAlign: 'right',
  },
  accountNumber: {
    fontSize: 11,
    color: '#7C84A3',
    marginTop: 3,
    textAlign: 'right',
  },

  currencyCode: {
    fontSize: 12,
    fontWeight: '800',
    color: '#1E1B4B',
    textAlign: 'center',
  },
  currencyName: {
    fontSize: 10,
    color: '#6B7280',
    marginTop: 2,
    textAlign: 'center',
  },

  statusPill: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 999,
  },
  statusPillText: {
    fontSize: 11,
    fontWeight: '800',
  },

  amountText: {
    fontSize: 13,
    fontWeight: '900',
    textAlign: 'left',
  },

  emptyBox: {
    padding: 24,
    alignItems: 'center',
    justifyContent: 'center',
  },
  emptyText: {
    fontSize: 14,
    color: '#7C84A3',
    fontWeight: '600',
  },
});