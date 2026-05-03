import { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TextInput,
  TouchableOpacity,
  Modal,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, ArrowRightLeft } from 'lucide-react-native';
import { KeyboardAwareView } from '@/components/KeyboardAwareView';
import { getExchangeRate } from '@/services/exchangeRateService';
import { Currency, CURRENCIES } from '@/types/database';

export default function CalculatorScreen() {
  const router = useRouter();
  const [fromCurrency, setFromCurrency] = useState<Currency>('USD');
  const [toCurrency, setToCurrency] = useState<Currency>('TRY');
  const [amount, setAmount] = useState('');
  const [result, setResult] = useState('');
  const [exchangeRate, setExchangeRate] = useState(0);
  const [showCurrencyPicker, setShowCurrencyPicker] = useState(false);
  const [currencyPickerType, setCurrencyPickerType] = useState<'from' | 'to'>('from');

  useEffect(() => {
    loadExchangeRate();
  }, [fromCurrency, toCurrency]);

  useEffect(() => {
    if (amount && exchangeRate) {
      const calculated = Number(amount) * exchangeRate;
      setResult(calculated.toFixed(2));
    } else {
      setResult('');
    }
  }, [amount, exchangeRate]);

  const loadExchangeRate = async () => {
    try {
      const rate = await getExchangeRate(fromCurrency, toCurrency);
      setExchangeRate(rate);
    } catch (error) {
      console.error('Error loading exchange rate:', error);
    }
  };

  const handleSwapCurrencies = () => {
    setFromCurrency(toCurrency);
    setToCurrency(fromCurrency);
  };

  const selectCurrency = (currency: Currency) => {
    if (currencyPickerType === 'from') {
      setFromCurrency(currency);
    } else {
      setToCurrency(currency);
    }
    setShowCurrencyPicker(false);
  };

  const getCurrencyName = (code: string) => {
    return CURRENCIES.find((c) => c.code === code)?.name || code;
  };

  const getCurrencySymbol = (code: string) => {
    return CURRENCIES.find((c) => c.code === code)?.symbol || code;
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>حاسبة العملات</Text>
        <View style={{ width: 40 }} />
      </View>

      <KeyboardAwareView contentContainerStyle={styles.content}>
        <View style={styles.calculatorCard}>
          <View style={styles.currencySection}>
            <Text style={styles.sectionLabel}>من</Text>
            <TouchableOpacity
              style={styles.currencyButton}
              onPress={() => {
                setCurrencyPickerType('from');
                setShowCurrencyPicker(true);
              }}
            >
              <Text style={styles.currencyCode}>{fromCurrency}</Text>
              <Text style={styles.currencyName}>{getCurrencyName(fromCurrency)}</Text>
            </TouchableOpacity>
            <TextInput
              style={styles.amountInput}
              value={amount}
              onChangeText={setAmount}
              placeholder="0.00"
              placeholderTextColor="#9CA3AF"
              keyboardType="decimal-pad"
              textAlign="center"
            />
          </View>

          <TouchableOpacity style={styles.swapButton} onPress={handleSwapCurrencies}>
            <ArrowRightLeft size={32} color="#4F46E5" />
          </TouchableOpacity>

          <View style={styles.exchangeRateContainer}>
            <Text style={styles.exchangeRateLabel}>سعر الصرف</Text>
            <Text style={styles.exchangeRateValue}>{exchangeRate.toFixed(4)}</Text>
          </View>

          <View style={styles.currencySection}>
            <Text style={styles.sectionLabel}>إلى</Text>
            <TouchableOpacity
              style={styles.currencyButton}
              onPress={() => {
                setCurrencyPickerType('to');
                setShowCurrencyPicker(true);
              }}
            >
              <Text style={styles.currencyCode}>{toCurrency}</Text>
              <Text style={styles.currencyName}>{getCurrencyName(toCurrency)}</Text>
            </TouchableOpacity>
            <View style={styles.resultContainer}>
              <Text style={styles.resultValue}>{result || '0.00'}</Text>
              <Text style={styles.resultSymbol}>{getCurrencySymbol(toCurrency)}</Text>
            </View>
          </View>
        </View>
      </KeyboardAwareView>

      <Modal
        visible={showCurrencyPicker}
        animationType="slide"
        transparent={true}
        onRequestClose={() => setShowCurrencyPicker(false)}
      >
        <View style={styles.modalContainer}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>اختر عملة</Text>
            {CURRENCIES.map((currency) => (
              <TouchableOpacity
                key={currency.code}
                style={styles.modalItem}
                onPress={() => selectCurrency(currency.code)}
              >
                <Text style={styles.modalItemText}>
                  {currency.code} - {currency.name}
                </Text>
                <Text style={styles.modalItemSymbol}>{currency.symbol}</Text>
              </TouchableOpacity>
            ))}
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
  content: {
    flex: 1,
    padding: 16,
  },
  calculatorCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 24,
    padding: 24,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.1,
    shadowRadius: 12,
    elevation: 4,
  },
  currencySection: {
    marginBottom: 24,
  },
  sectionLabel: {
    fontSize: 16,
    color: '#6B7280',
    marginBottom: 12,
    textAlign: 'right',
  },
  currencyButton: {
    backgroundColor: '#EEF2FF',
    borderRadius: 16,
    padding: 20,
    marginBottom: 16,
    alignItems: 'center',
  },
  currencyCode: {
    fontSize: 32,
    fontWeight: 'bold',
    color: '#4F46E5',
    marginBottom: 4,
  },
  currencyName: {
    fontSize: 16,
    color: '#6B7280',
  },
  amountInput: {
    backgroundColor: '#F9FAFB',
    borderRadius: 16,
    paddingVertical: 20,
    paddingHorizontal: 24,
    fontSize: 36,
    fontWeight: 'bold',
    color: '#111827',
    borderWidth: 2,
    borderColor: '#E5E7EB',
  },
  swapButton: {
    alignSelf: 'center',
    width: 64,
    height: 64,
    borderRadius: 32,
    backgroundColor: '#EEF2FF',
    justifyContent: 'center',
    alignItems: 'center',
    marginVertical: 16,
  },
  exchangeRateContainer: {
    backgroundColor: '#F9FAFB',
    borderRadius: 12,
    padding: 16,
    alignItems: 'center',
    marginBottom: 24,
  },
  exchangeRateLabel: {
    fontSize: 14,
    color: '#6B7280',
    marginBottom: 4,
  },
  exchangeRateValue: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#4F46E5',
  },
  resultContainer: {
    backgroundColor: '#ECFDF5',
    borderRadius: 16,
    padding: 20,
    alignItems: 'center',
    borderWidth: 2,
    borderColor: '#10B981',
  },
  resultValue: {
    fontSize: 40,
    fontWeight: 'bold',
    color: '#10B981',
    marginBottom: 4,
  },
  resultSymbol: {
    fontSize: 20,
    color: '#059669',
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
    maxHeight: '70%',
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 16,
    textAlign: 'center',
  },
  modalItem: {
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  modalItemText: {
    fontSize: 16,
    color: '#111827',
    textAlign: 'right',
  },
  modalItemSymbol: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#4F46E5',
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
