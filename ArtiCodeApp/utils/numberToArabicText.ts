import { Currency } from '@/types/database';

const ones = ['', 'واحد', 'اثنان', 'ثلاثة', 'أربعة', 'خمسة', 'ستة', 'سبعة', 'ثمانية', 'تسعة'];
const tens = ['', '', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون', 'ستون', 'سبعون', 'ثمانون', 'تسعون'];
const teens = [
  'عشرة',
  'أحد عشر',
  'اثنا عشر',
  'ثلاثة عشر',
  'أربعة عشر',
  'خمسة عشر',
  'ستة عشر',
  'سبعة عشر',
  'ثمانية عشر',
  'تسعة عشر',
];
const hundreds = [
  '',
  'مائة',
  'مائتان',
  'ثلاثمائة',
  'أربعمائة',
  'خمسمائة',
  'ستمائة',
  'سبعمائة',
  'ثماني مائة',
  'تسعمائة',
];

const thousands = ['', 'ألف', 'ألفان', 'ثلاثة آلاف', 'أربعة آلاف', 'خمسة آلاف', 'ستة آلاف', 'سبعة آلاف', 'ثمانية آلاف', 'تسعة آلاف'];

function convertHundreds(num: number): string {
  if (num === 0) return '';

  const hundred = Math.floor(num / 100);
  const remainder = num % 100;

  let result = hundreds[hundred];

  if (remainder >= 10 && remainder < 20) {
    result += (result ? ' و' : '') + teens[remainder - 10];
  } else {
    const ten = Math.floor(remainder / 10);
    const one = remainder % 10;

    if (ten > 0) {
      result += (result ? ' و' : '') + tens[ten];
    }
    if (one > 0) {
      result += (result ? ' و' : '') + ones[one];
    }
  }

  return result;
}

function convertThousands(num: number): string {
  if (num === 0) return '';

  const thousand = Math.floor(num / 1000);
  const remainder = num % 1000;

  let result = '';

  if (thousand > 0 && thousand < 10) {
    result = thousands[thousand];
  } else if (thousand >= 10) {
    result = convertHundreds(thousand) + ' ألف';
  }

  if (remainder > 0) {
    const hundredsPart = convertHundreds(remainder);
    if (hundredsPart) {
      result += (result ? ' و' : '') + hundredsPart;
    }
  }

  return result;
}

function convertMillions(num: number): string {
  if (num === 0) return 'صفر';

  const million = Math.floor(num / 1000000);
  const remainder = num % 1000000;

  let result = '';

  if (million > 0) {
    if (million === 1) {
      result = 'مليون';
    } else if (million === 2) {
      result = 'مليونان';
    } else if (million >= 3 && million <= 10) {
      result = convertHundreds(million) + ' ملايين';
    } else {
      result = convertThousands(million) + ' مليون';
    }
  }

  if (remainder > 0) {
    const remainderText = remainder >= 1000 ? convertThousands(remainder) : convertHundreds(remainder);
    if (remainderText) {
      result += (result ? ' و' : '') + remainderText;
    }
  }

  return result;
}

export function numberToArabicText(num: number): string {
  if (num === 0) return 'صفر';

  const integerPart = Math.floor(num);

  if (integerPart >= 1000000) {
    return convertMillions(integerPart);
  } else if (integerPart >= 1000) {
    return convertThousands(integerPart);
  } else {
    return convertHundreds(integerPart);
  }
}

function getCurrencyNameInArabic(currency: Currency): string {
  const currencyNames: Record<Currency, string> = {
    USD: 'دولار أمريكي',
    TRY: 'ليرة تركية',
    SAR: 'ريال سعودي',
    EUR: 'يورو',
    YER: 'ريال يمني',
    GBP: 'جنيه إسترليني',
    AED: 'درهم إماراتي',
  };

  return currencyNames[currency] || currency;
}

export function numberToArabicTextWithCurrency(num: number, currency: Currency): string {
  const integerPart = Math.floor(num);
  const arabicText = numberToArabicText(integerPart);
  const currencyName = getCurrencyNameInArabic(currency);

  return `${arabicText} ${currencyName} لا غير`;
}
