export interface CustomerDisplaySource {
  name?: string | null;
  linked_user_id?: string | null;
  is_profit_loss_account?: boolean | null;
}

export type CustomerDisplayStatus = 'linked' | 'unlinked' | 'system';

export interface CustomerStatusMeta {
  status: CustomerDisplayStatus;
  label: string;
  backgroundColor: string;
  borderColor: string;
  textColor: string;
  iconColor: string;
}

export function getCustomerDisplayStatus(
  customer?: CustomerDisplaySource | null,
): CustomerDisplayStatus {
  if (customer?.is_profit_loss_account) {
    return 'system';
  }

  return customer?.linked_user_id ? 'linked' : 'unlinked';
}

export function getCustomerStatusMeta(
  customer?: CustomerDisplaySource | null,
): CustomerStatusMeta {
  const status = getCustomerDisplayStatus(customer);

  switch (status) {
    case 'linked':
      return {
        status,
        label: 'مرتبط',
        backgroundColor: '#EEF2FF',
        borderColor: '#C7D2FE',
        textColor: '#4338CA',
        iconColor: '#4F46E5',
      };
    case 'system':
      return {
        status,
        label: 'حساب نظام',
        backgroundColor: '#FEF3C7',
        borderColor: '#FCD34D',
        textColor: '#92400E',
        iconColor: '#D97706',
      };
    default:
      return {
        status,
        label: 'غير مرتبط',
        backgroundColor: '#F8FAFC',
        borderColor: '#CBD5E1',
        textColor: '#475569',
        iconColor: '#64748B',
      };
  }
}

export function sortCustomersByDisplayPriority<T extends CustomerDisplaySource>(
  customers: T[],
): T[] {
  const priority = (customer: CustomerDisplaySource) => {
    const status = getCustomerDisplayStatus(customer);
    if (status === 'linked') return 0;
    if (status === 'unlinked') return 1;
    return 2;
  };

  return [...customers].sort((a, b) => {
    const diff = priority(a) - priority(b);
    if (diff !== 0) return diff;

    return (a.name || '').localeCompare(b.name || '', 'ar');
  });
}

export function sortCustomersKeepingOriginalOrder<T extends CustomerDisplaySource>(
  customers: T[],
): T[] {
  return [...customers]
    .map((customer, index) => ({ customer, index }))
    .sort((a, b) => {
      const statusDiff =
        (getCustomerDisplayStatus(a.customer) === 'linked'
          ? 0
          : getCustomerDisplayStatus(a.customer) === 'unlinked'
            ? 1
            : 2) -
        (getCustomerDisplayStatus(b.customer) === 'linked'
          ? 0
          : getCustomerDisplayStatus(b.customer) === 'unlinked'
            ? 1
            : 2);

      if (statusDiff !== 0) return statusDiff;
      return a.index - b.index;
    })
    .map((item) => item.customer);
}
