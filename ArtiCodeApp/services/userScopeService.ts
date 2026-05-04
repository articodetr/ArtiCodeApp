import { supabase } from '@/lib/supabase';
import { Customer } from '@/types/database';

/**
 * Customers owned by the current app user only.
 * Use this for normal customer lists so a user does not see the other side's
 * private customer records as editable records.
 */
export function buildOwnedCustomerFilter(
  userId: string,
  ownerField: string = 'user_id',
): string {
  return `${ownerField}.eq.${userId}`;
}

/**
 * Customers where the current user is either the owner or the linked counterparty.
 * Use this for statistics, notifications, and approval dashboards.
 */
export function buildUserScopeFilter(
  userId: string,
  ownerField: string = 'user_id',
  linkedField: string = 'linked_user_id',
): string {
  return `${ownerField}.eq.${userId},${linkedField}.eq.${userId}`;
}

/**
 * Main app customer filter.
 *
 * IMPORTANT:
 * Profit/loss accounts must stay private to their owner.
 * We do NOT append any global profit/loss conditions here, because doing so
 * would make accounts like PROFIT_LOSS_ACCOUNT appear shared across users.
 *
 * The includeProfitLoss argument is kept only for backward compatibility.
 */
export function buildScopedCustomerFilter(
  userId: string,
  _includeProfitLoss: boolean = false,
): string {
  return buildOwnedCustomerFilter(userId);
}

/**
 * Statistics/approvals filter.
 *
 * This must include owned customers and linked-counterparty customers so
 * pending approvals and linked movements still appear correctly.
 *
 * We intentionally do NOT add any standalone profit/loss conditions.
 * If a profit/loss customer belongs to the current user, it is already covered
 * by the normal user scope.
 */
export function buildStatisticsCustomerFilter(
  userId: string,
  _includeProfitLoss: boolean = true,
): string {
  return buildUserScopeFilter(userId);
}

/**
 * Read/detail customer filter.
 *
 * Used when opening a specific record from notifications or approvals.
 * Keeps read access aligned with user scope without leaking global
 * profit/loss accounts.
 */
export function buildReadableCustomerFilter(
  userId: string,
  _includeProfitLoss: boolean = false,
): string {
  return buildUserScopeFilter(userId);
}

export async function fetchAccessibleCustomers(
  userId: string,
  includeProfitLoss: boolean = false,
): Promise<Customer[]> {
  const { data, error } = await supabase
    .from('customers')
    .select('*')
    .or(buildScopedCustomerFilter(userId, includeProfitLoss))
    .order('name', { ascending: true });

  if (error) {
    throw error;
  }

  return (data || []) as Customer[];
}

export async function fetchAccessibleCustomerIds(
  userId: string,
  includeProfitLoss: boolean = false,
): Promise<string[]> {
  const { data, error } = await supabase
    .from('customers')
    .select('id')
    .or(buildScopedCustomerFilter(userId, includeProfitLoss));

  if (error) {
    throw error;
  }

  return (data || []).map((item) => item.id as string);
}

export async function fetchAccessibleCustomerById(
  userId: string,
  customerId: string,
  includeProfitLoss: boolean = false,
): Promise<Customer | null> {
  const { data, error } = await supabase
    .from('customers')
    .select('*')
    .eq('id', customerId)
    .or(buildReadableCustomerFilter(userId, includeProfitLoss))
    .maybeSingle();

  if (error) {
    throw error;
  }

  return (data as Customer | null) || null;
}
