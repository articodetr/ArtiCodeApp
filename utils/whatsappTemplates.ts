import { format } from 'date-fns';
import { ar } from 'date-fns/locale';
import { supabase } from '@/lib/supabase';

export const APP_SETTINGS_FIXED_ID = '00000000-0000-0000-0000-000000000000';

export interface TemplateVariables {
  customer_name?: string;
  account_number?: string;
  date?: string;
  balance?: string;
  balances?: string;
  movements?: string;
  shop_name?: string;
}

export interface WhatsAppTemplates {
  account_statement: string;
  share_account: string;
}

export const DEFAULT_WHATSAPP_TEMPLATES: WhatsAppTemplates = {
  account_statement: [
    'مرحبا {الاسم}',
    '',
    '{الرصيد}',
  ].join('\n'),
  share_account: [
    'مرحبا {الاسم}',
    '',
    'كشف الحساب التفصيلي',
    '',
    '{الأرصدة}',
    '',
    'الحركات المالية',
    '',
    '{الحركات المالية}',
    '',
    '{اسم_المحل}',
  ].join('\n'),
};

const PLACEHOLDER_ALIASES: Record<keyof TemplateVariables, string[]> = {
  customer_name: ['customer_name', 'الاسم'],
  account_number: ['account_number', 'رقم_الحساب'],
  date: ['date', 'التاريخ'],
  balance: ['balance', 'الرصيد'],
  balances: ['balances', 'الأرصدة'],
  movements: ['movements', 'الحركات المالية'],
  shop_name: ['shop_name', 'اسم_المحل'],
};

export async function fetchWhatsAppTemplates(): Promise<WhatsAppTemplates> {
  try {
    const { data, error } = await supabase
      .from('app_settings')
      .select('whatsapp_account_statement_template, whatsapp_share_account_template')
      .eq('id', APP_SETTINGS_FIXED_ID)
      .maybeSingle();

    if (error) {
      console.error('Error fetching WhatsApp templates:', error);
      return DEFAULT_WHATSAPP_TEMPLATES;
    }

    if (!data) {
      return DEFAULT_WHATSAPP_TEMPLATES;
    }

    return {
      account_statement:
        data.whatsapp_account_statement_template ||
        DEFAULT_WHATSAPP_TEMPLATES.account_statement,
      share_account:
        data.whatsapp_share_account_template ||
        DEFAULT_WHATSAPP_TEMPLATES.share_account,
    };
  } catch (error) {
    console.error('Error fetching WhatsApp templates:', error);
    return DEFAULT_WHATSAPP_TEMPLATES;
  }
}

export function replaceTemplateVariables(
  template: string,
  variables: TemplateVariables
): string {
  let result = template;

  (Object.keys(PLACEHOLDER_ALIASES) as Array<keyof TemplateVariables>).forEach((key) => {
    const value = variables[key];
    if (value === undefined || value === null) return;

    const aliases = PLACEHOLDER_ALIASES[key];
    aliases.forEach((alias) => {
      const escaped = alias.replace(/[.*+?^\${}()|[\]\\]/g, '\\$&');
      result = result.replace(new RegExp('\\{' + escaped + '\\}', 'g'), String(value));
    });
  });

  return result;
}

export function formatHumanNumber(value: number): string {
  if (!Number.isFinite(value)) return '0';

  const fixed = Number(value).toFixed(2);
  return fixed.replace(/\.00$/, '').replace(/(\.\d)0$/, '$1');
}

export function getArabicCurrencyName(currency: string): string {
  const upper = String(currency || '').toUpperCase();

  const map: Record<string, string> = {
    USD: 'دولار',
    SAR: 'ريال سعودي',
    TRY: 'ليرة تركية',
    YER: 'ريال يمني',
  };

  return map[upper] || upper;
}

export function formatBalancesForWhatsApp(
  balances: Array<{ currency: string; balance: number }>
): string {
  if (!balances.length) {
    return 'لا توجد أرصدة';
  }

  return balances
    .map((item) => {
      const value = Number(item.balance || 0);
      const amount = formatHumanNumber(Math.abs(value));
      const currency = getArabicCurrencyName(item.currency);

      if (value > 0) {
        return 'لكم ' + amount + ' ' + currency;
      }

      if (value < 0) {
        return 'عليكم ' + amount + ' ' + currency;
      }

      return amount + ' ' + currency;
    })
    .join('\n');
}

export function formatMovementsForWhatsApp(
  movements: Array<{
    created_at: string;
    movement_type: string;
    amount: number;
    currency: string;
    notes?: string;
  }>
): string {
  if (!movements.length) {
    return 'لا توجد حركات';
  }

  return movements
    .map((movement) => {
      const date = format(new Date(movement.created_at), 'dd/MM/yyyy', { locale: ar });
      const type = movement.movement_type === 'incoming' ? 'وارد' : 'صادر';
      const amount = formatHumanNumber(Number(movement.amount || 0));
      const currency = getArabicCurrencyName(movement.currency);
      const notes = movement.notes?.trim();

      const lines = [
        type + ': ' + amount + ' ' + currency,
        'التاريخ: ' + date,
      ];

      if (notes) {
        lines.push('الملاحظة: ' + notes);
      }

      return lines.join('\n');
    })
    .join('\n\n');
}

export function getFormattedDate(): string {
  return format(new Date(), 'dd/MM/yyyy', { locale: ar });
}

export function validateTemplate(template: string, requiredVariables: string[]): boolean {
  return requiredVariables.every((variable) => {
    return template.includes('{' + variable + '}');
  });
}

export function getAccountStatementVariables(): Array<{
  key: string;
  description: string;
  example: string;
}> {
  return [
    {
      key: '{الاسم}',
      description: 'اسم العميل',
      example: 'محمد أحمد',
    },
    {
      key: '{رقم_الحساب}',
      description: 'رقم الحساب',
      example: 'A-001',
    },
    {
      key: '{التاريخ}',
      description: 'التاريخ الحالي',
      example: '27/04/2026',
    },
    {
      key: '{الرصيد}',
      description: 'الأرصدة المختصرة',
      example: 'لكم 500 دولار\nعليكم 600 ريال سعودي',
    },
  ];
}

export function getShareAccountVariables(): Array<{
  key: string;
  description: string;
  example: string;
}> {
  return [
    {
      key: '{الاسم}',
      description: 'اسم العميل',
      example: 'محمد أحمد',
    },
    {
      key: '{رقم_الحساب}',
      description: 'رقم الحساب',
      example: 'A-001',
    },
    {
      key: '{التاريخ}',
      description: 'التاريخ الحالي',
      example: '27/04/2026',
    },
    {
      key: '{الأرصدة}',
      description: 'الأرصدة التفصيلية',
      example: 'لكم 500 دولار\nعليكم 600 ريال سعودي',
    },
    {
      key: '{الحركات المالية}',
      description: 'الحركات التفصيلية',
      example: 'وارد: 500 دولار\nالتاريخ: 27/04/2026\nالملاحظة: دفعة',
    },
    {
      key: '{اسم_المحل}',
      description: 'اسم المحل',
      example: 'ArtiCode Exchange',
    },
  ];
}

export function generatePreviewMessage(
  template: string,
  templateType: 'account_statement' | 'share_account'
): string {
  const sampleVariables: TemplateVariables = {
    customer_name: 'محمد أحمد',
    account_number: 'A-001',
    date: getFormattedDate(),
    balance: 'لكم 500 دولار\nعليكم 600 ريال سعودي',
    balances: 'لكم 500 دولار\nعليكم 600 ريال سعودي\nلكم 1250 ليرة تركية',
    movements: [
      'وارد: 500 دولار',
      'التاريخ: 27/04/2026',
      'الملاحظة: دفعة أولى',
      '',
      'صادر: 300 ريال سعودي',
      'التاريخ: 26/04/2026',
      'الملاحظة: تسليم',
    ].join('\n'),
    shop_name: 'ArtiCode Exchange',
  };

  const safeTemplate =
    templateType === 'account_statement'
      ? template || DEFAULT_WHATSAPP_TEMPLATES.account_statement
      : template || DEFAULT_WHATSAPP_TEMPLATES.share_account;

  return replaceTemplateVariables(safeTemplate, sampleVariables);
}
