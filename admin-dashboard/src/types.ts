export type BillingCycle = 'monthly' | 'yearly';
export type SubscriptionStatus = 'active' | 'ending_soon' | 'expired' | 'canceled' | 'trial' | 'all';
export type PaymentStatus = 'paid' | 'pending' | 'failed' | 'refunded' | 'all';
export type SubscriptionRequestStatus = 'new' | 'contacted' | 'activated' | 'closed' | 'all';
export type MovementType = 'incoming' | 'outgoing' | 'all';
export type TransferDirection = 'shop_to_customer' | 'customer_to_shop' | 'customer_to_customer' | 'all';

export interface AdminUser {
  id: string;
  user_name: string;
  full_name: string;
  account_number?: string | null;
  role: string;
}

export interface AdminSession {
  token: string;
  expires_at: string;
  admin: AdminUser;
}

export interface DashboardStats {
  total_users: number;
  active_users: number;
  active_subscribers: number;
  monthly_subscriptions: number;
  yearly_subscriptions: number;
  ending_soon: number;
  expired_subscriptions: number;
  monthly_revenue: number;
  total_revenue: number;
}

export interface GrowthPoint {
  month: string;
  count: number;
}

export interface BillingBreakdown {
  monthly: number;
  yearly: number;
}

export interface UserRow {
  id: string;
  user_name: string;
  full_name: string;
  account_number?: string | null;
  role: string;
  is_active: boolean;
  created_at?: string | null;
  updated_at?: string | null;
  last_login?: string | null;
  subscription_id?: string | null;
  plan_name?: string | null;
  billing_cycle?: BillingCycle | null;
  start_date?: string | null;
  end_date?: string | null;
  subscription_status?: SubscriptionStatus | null;
  amount?: number | null;
  currency?: string | null;
  auto_renew?: boolean | null;
  customer_count?: number;
  customer_limit?: number | null;
  free_customer_limit?: number;
  has_active_subscription?: boolean;
  can_add_customer?: boolean;
  quota_message?: string | null;
  admin_activity_count?: number;
  paid_invoices_count?: number;
}

export interface SubscriptionRow {
  id: string;
  user_id: string;
  plan_name: string;
  billing_cycle: BillingCycle;
  start_date: string;
  end_date: string;
  status: string;
  effective_status: SubscriptionStatus;
  amount: number;
  currency: string;
  auto_renew: boolean;
  max_customers?: number | null;
  notes?: string | null;
  created_at?: string;
  updated_at?: string;
  user_name: string;
  full_name: string;
  account_number?: string | null;
  role?: string;
  is_active?: boolean;
}


export interface SubscriptionRequestRow {
  id: string;
  user_id?: string | null;
  full_name?: string | null;
  user_name?: string | null;
  account_number?: string | null;
  customer_count?: number | null;
  customer_limit?: number | null;
  whatsapp_number?: string | null;
  request_message?: string | null;
  status: SubscriptionRequestStatus;
  source?: string | null;
  created_at: string;
  updated_at?: string | null;
  subscription_status?: string | null;
  end_date?: string | null;
}

export interface PaymentRow {
  id: string;
  user_id: string;
  subscription_id?: string | null;
  amount: number;
  currency: string;
  status: PaymentStatus;
  paid_at: string;
  invoice_no?: string | null;
  payment_method?: string | null;
  notes?: string | null;
  created_at?: string;
  user_name: string;
  full_name: string;
  account_number?: string | null;
  plan_name?: string | null;
  billing_cycle?: BillingCycle | null;
}

export interface TransferCurrencyTotal {
  currency: string;
  incoming_amount: number;
  outgoing_amount: number;
  net_amount: number;
}

export interface TransferStats {
  total_movements: number;
  incoming_movements: number;
  outgoing_movements: number;
  customer_to_customer: number;
  shop_to_customer: number;
  customer_to_shop: number;
  pending_approval: number;
  approved_movements: number;
  rejected_movements: number;
  total_amount_by_currency: TransferCurrencyTotal[];
}

export interface TransferUserSummary {
  user_id?: string | null;
  user_name?: string | null;
  full_name?: string | null;
  account_number?: string | null;
  total_movements: number;
  incoming_movements: number;
  outgoing_movements: number;
  last_movement_at?: string | null;
}

export interface TransferMovementRow {
  id: string;
  movement_number?: string | null;
  transfer_number?: string | null;
  customer_id?: string | null;
  customer_name?: string | null;
  customer_account_number?: string | null;
  owner_user_id?: string | null;
  owner_user_name?: string | null;
  owner_full_name?: string | null;
  owner_account_number?: string | null;
  linked_user_id?: string | null;
  linked_user_name?: string | null;
  linked_full_name?: string | null;
  movement_type: 'incoming' | 'outgoing';
  transfer_direction?: 'shop_to_customer' | 'customer_to_shop' | 'customer_to_customer' | null;
  amount: number;
  currency: string;
  commission?: number | null;
  commission_currency?: string | null;
  sender_name?: string | null;
  beneficiary_name?: string | null;
  from_customer_id?: string | null;
  from_customer_name?: string | null;
  to_customer_id?: string | null;
  to_customer_name?: string | null;
  approval_status?: 'pending' | 'approved' | 'rejected' | null;
  pending_approval?: boolean | null;
  approved_by_user_id?: string | null;
  approved_at?: string | null;
  created_by_user_id?: string | null;
  created_by_user_name?: string | null;
  source_user_id?: string | null;
  source_user_name?: string | null;
  related_transfer_id?: string | null;
  mirror_movement_id?: string | null;
  notes?: string | null;
  created_at: string;
}

export interface TransferMovementsData {
  stats: TransferStats;
  movements: TransferMovementRow[];
  user_summary: TransferUserSummary[];
}

export interface ActivityRow {
  id: string;
  user_id?: string | null;
  full_name?: string | null;
  user_name?: string | null;
  source?: string;
  action: string;
  details?: Record<string, unknown> | null;
  device?: string | null;
  ip_address?: string | null;
  created_at: string;
}

export interface OverviewData {
  stats: DashboardStats;
  subscription_growth: GrowthPoint[];
  billing_breakdown: BillingBreakdown;
  recent_users: UserRow[];
  ending_soon_list: UserRow[];
  recent_activity: ActivityRow[];
}

export interface UserDetailData {
  user: UserRow | null;
  subscriptions: SubscriptionRow[];
  payments: PaymentRow[];
  activity: ActivityRow[];
  transfers: TransferMovementRow[];
}

export interface SaveSubscriptionInput {
  subscriptionId?: string | null;
  userId: string;
  planName: string;
  billingCycle: BillingCycle;
  startDate: string;
  endDate: string;
  amount: number;
  currency: string;
  status: 'active' | 'expired' | 'canceled' | 'trial';
  autoRenew: boolean;
  maxCustomers?: number | null;
  notes?: string;
}

export interface SavePaymentInput {
  userId: string;
  subscriptionId?: string | null;
  amount: number;
  currency: string;
  status: 'paid' | 'pending' | 'failed' | 'refunded';
  paidAt: string;
  invoiceNo?: string;
  paymentMethod?: string;
  notes?: string;
}
