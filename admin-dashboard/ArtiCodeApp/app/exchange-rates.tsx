import { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  RefreshControl,
  Alert,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, RefreshCw, TrendingUp, TrendingDown } from 'lucide-react-native';
import { updateExchangeRates, getAllExchangeRates } from '@/services/exchangeRateService';
import { ExchangeRate, CURRENCIES } from '@/types/database';
import { format } from 'date-fns';
import { ar } from 'date-fns/locale';

export default function ExchangeRatesScreen() {
  const router = useRouter();
  const [rates, setRates] = useState<ExchangeRate[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [isUpdating, setIsUpdating] = useState(false);

  useEffect(() => {
    loadRates();
  }, []);

  const loadRates = async () => {
    try {
      const data = await getAllExchangeRates();
      setRates(data);
    } catch (error) {
      console.error('Error loading rates:', error);
    }
  };

  const handleRefresh = async () => {
    setRefreshing(true);
    await loadRates();
    setRefreshing(false);
  };

  const handleUpdateRates = async () => {
    setIsUpdating(true);
    try {
      await updateExchangeRates();
      await loadRates();
      Alert.alert('نجح', 'تم تحديث أسعار الصرف بنجاح');
    } catch (error) {
      Alert.alert('خطأ', 'حدث خطأ أثناء تحديث الأسعار');
    } finally {
      setIsUpdating(false);
    }
  };

  const getCurrencyName = (code: string) => {
    const currency = CURRENCIES.find((c) => c.code === code);
    return currency?.name || code;
  };

  const getCurrencySymbol = (code: string) => {
    const currency = CURRENCIES.find((c) => c.code === code);
    return currency?.symbol || code;
  };

  const groupedRates = rates.reduce((acc, rate) => {
    if (rate.from_currency === 'USD') {
      acc.push(rate);
    }
    return acc;
  }, [] as ExchangeRate[]);

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>أسعار الصرف</Text>
        <TouchableOpacity
          style={styles.updateButton}
          onPress={handleUpdateRates}
          disabled={isUpdating}
        >
          <RefreshCw size={20} color="#4F46E5" />
        </TouchableOpacity>
      </View>

      <ScrollView
        style={styles.content}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={handleRefresh} />}
      >
        <View style={styles.infoCard}>
          <Text style={styles.infoTitle}>التحديث التلقائي</Text>
          <Text style={styles.infoText}>
            يتم تحديث أسعار الصرف تلقائياً من مصادر موثوقة
          </Text>
          {groupedRates.length > 0 && (
            <Text style={styles.infoDate}>
              آخر تحديث:{' '}
              {format(new Date(groupedRates[0].created_at), 'dd MMMM yyyy - HH:mm', {
                locale: ar,
              })}
            </Text>
          )}
        </View>

        <View style={styles.ratesContainer}>
          {groupedRates.map((rate, index) => {
            if (rate.to_currency === 'USD') return null;

            return (
              <View key={rate.id} style={styles.rateCard}>
                <View style={styles.rateHeader}>
                  <View style={styles.currencyInfo}>
                    <Text style={styles.currencyCode}>{rate.to_currency}</Text>
                    <Text style={styles.currencyName}>{getCurrencyName(rate.to_currency)}</Text>
                  </View>
                  <View
                    style={[
                      styles.iconContainer,
                      { backgroundColor: index % 2 === 0 ? '#10B98115' : '#EF444415' },
                    ]}
                  >
                    {index % 2 === 0 ? (
                      <TrendingUp size={24} color="#10B981" />
                    ) : (
                      <TrendingDown size={24} color="#EF4444" />
                    )}
                  </View>
                </View>

                <View style={styles.rateBody}>
                  <View style={styles.rateRow}>
                    <Text style={styles.rateLabel}>دولار واحد =</Text>
                    <Text style={styles.rateValue}>
                      {Number(rate.rate).toFixed(4)} {getCurrencySymbol(rate.to_currency)}
                    </Text>
                  </View>
                  <View style={styles.rateDivider} />
                  <View style={styles.rateRow}>
                    <Text style={styles.rateLabel}>
                      {getCurrencySymbol(rate.to_currency)} واحد =
                    </Text>
                    <Text style={styles.rateValue}>
                      {(1 / Number(rate.rate)).toFixed(6)} $
                    </Text>
                  </View>
                </View>

                <View style={styles.rateFooter}>
                  <View style={styles.sourceBadge}>
                    <Text style={styles.sourceText}>
                      {rate.source === 'api' ? 'تلقائي' : 'يدوي'}
                    </Text>
                  </View>
                </View>
              </View>
            );
          })}
        </View>

        {groupedRates.length === 0 && (
          <View style={styles.emptyContainer}>
            <Text style={styles.emptyText}>لا توجد أسعار صرف</Text>
            <TouchableOpacity style={styles.loadButton} onPress={handleUpdateRates}>
              <Text style={styles.loadButtonText}>تحميل الأسعار</Text>
            </TouchableOpacity>
          </View>
        )}
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
  updateButton: {
    width: 40,
    height: 40,
    justifyContent: 'center',
    alignItems: 'center',
  },
  content: {
    flex: 1,
  },
  infoCard: {
    backgroundColor: '#EEF2FF',
    margin: 16,
    padding: 16,
    borderRadius: 12,
  },
  infoTitle: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#4F46E5',
    marginBottom: 4,
    textAlign: 'right',
  },
  infoText: {
    fontSize: 14,
    color: '#6B7280',
    marginBottom: 8,
    textAlign: 'right',
  },
  infoDate: {
    fontSize: 12,
    color: '#9CA3AF',
    textAlign: 'right',
  },
  ratesContainer: {
    padding: 16,
  },
  rateCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 16,
    padding: 16,
    marginBottom: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  rateHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 16,
  },
  currencyInfo: {
    flex: 1,
  },
  currencyCode: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 4,
    textAlign: 'right',
  },
  currencyName: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'right',
  },
  iconContainer: {
    width: 48,
    height: 48,
    borderRadius: 24,
    justifyContent: 'center',
    alignItems: 'center',
  },
  rateBody: {
    marginBottom: 12,
  },
  rateRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 8,
  },
  rateLabel: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'right',
  },
  rateValue: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#111827',
    textAlign: 'right',
  },
  rateDivider: {
    height: 1,
    backgroundColor: '#F3F4F6',
    marginVertical: 4,
  },
  rateFooter: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
  },
  sourceBadge: {
    backgroundColor: '#F3F4F6',
    paddingHorizontal: 12,
    paddingVertical: 4,
    borderRadius: 12,
  },
  sourceText: {
    fontSize: 12,
    color: '#6B7280',
    fontWeight: '600',
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
    marginBottom: 16,
  },
  loadButton: {
    backgroundColor: '#4F46E5',
    paddingHorizontal: 24,
    paddingVertical: 12,
    borderRadius: 12,
  },
  loadButtonText: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
});
