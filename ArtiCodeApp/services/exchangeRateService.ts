import { supabase } from '@/lib/supabase';
import { ExchangeRate, Currency } from '@/types/database';

const EXCHANGE_API_URL = 'https://api.exchangerate-api.com/v4/latest/USD';

export async function fetchExchangeRates(): Promise<Record<string, number>> {
  try {
    const response = await fetch(EXCHANGE_API_URL);
    const data = await response.json();
    return data.rates;
  } catch (error) {
    console.error('Error fetching exchange rates:', error);
    throw error;
  }
}

export async function updateExchangeRates(): Promise<void> {
  try {
    const rates = await fetchExchangeRates();
    const currencies: Currency[] = ['TRY', 'SAR', 'EUR', 'GBP', 'AED'];

    for (const currency of currencies) {
      if (rates[currency]) {
        await supabase
          .from('exchange_rates')
          .upsert(
            {
              from_currency: 'USD',
              to_currency: currency,
              rate: rates[currency],
              source: 'api',
            },
            {
              onConflict: 'from_currency,to_currency',
            }
          );
      }
    }

    await supabase
      .from('exchange_rates')
      .upsert(
        {
          from_currency: 'USD',
          to_currency: 'USD',
          rate: 1,
          source: 'api',
        },
        {
          onConflict: 'from_currency,to_currency',
        }
      );
  } catch (error) {
    console.error('Error updating exchange rates:', error);
    throw error;
  }
}

export async function getExchangeRate(
  fromCurrency: string,
  toCurrency: string
): Promise<number> {
  try {
    if (fromCurrency === toCurrency) return 1;

    const { data, error } = await supabase
      .from('exchange_rates')
      .select('rate')
      .eq('from_currency', fromCurrency)
      .eq('to_currency', toCurrency)
      .maybeSingle();

    if (error || !data) {
      if (fromCurrency === 'USD') {
        const rates = await fetchExchangeRates();
        return rates[toCurrency] || 1;
      }
      return 1;
    }

    return Number(data.rate);
  } catch (error) {
    console.error('Error getting exchange rate:', error);
    return 1;
  }
}

export async function getAllExchangeRates(): Promise<ExchangeRate[]> {
  try {
    const { data, error } = await supabase
      .from('exchange_rates')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) throw error;
    return data || [];
  } catch (error) {
    console.error('Error getting all exchange rates:', error);
    return [];
  }
}
