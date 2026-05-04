export const ARABIC_CURRENCY_NAMES: Record<string, string> = {
  USD: 'دولار',
  SAR: 'ريال سعودي',
  TRY: 'ليرة تركية',
  YER: 'ريال يمني',
};

export const CURRENCY_SYMBOLS: Record<string, string> = {
  USD: '$',
  SAR: 'ر.س',
  TRY: '₺',
  YER: 'ر.ي',
};

export function formatSmartNumber(value: number | string | null | undefined) {
  const numberValue = Number(value ?? 0);

  if (!Number.isFinite(numberValue)) {
    return '0';
  }

  return numberValue.toLocaleString('en-US', {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

export function getCurrencySymbol(currency?: string | null) {
  const key = String(currency || 'USD').toUpperCase();
  return CURRENCY_SYMBOLS[key] || key;
}

export function getArabicCurrencyName(currency?: string | null) {
  const key = String(currency || 'USD').toUpperCase();
  return ARABIC_CURRENCY_NAMES[key] || key;
}

export function formatAmountArabic(
  amount: number | string | null | undefined,
  currency?: string | null,
) {
  const numericAmount = Number(amount ?? 0);

  if (!Number.isFinite(numericAmount)) {
    return `0 ${getCurrencySymbol(currency)}`;
  }

  const sign = numericAmount < 0 ? '-' : '';
  return `${sign}${formatSmartNumber(Math.abs(numericAmount))} ${getCurrencySymbol(currency)}`;
}

function pad2(value: number) {
  return String(value).padStart(2, '0');
}

export function formatDateTimeArabic(value: Date | string | number | null | undefined) {
  if (!value) return '';

  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) return '';

  const day = pad2(date.getDate());
  const month = pad2(date.getMonth() + 1);
  const year = date.getFullYear();

  const hours24 = date.getHours();
  const period = hours24 >= 12 ? 'م' : 'ص';
  const hours12 = hours24 % 12 || 12;
  const minutes = pad2(date.getMinutes());

  return `${day}/${month}/${year} - ${pad2(hours12)}:${minutes} ${period}`;
}
