import { useState, useEffect, useCallback } from 'react';
import {
  View, Text, StyleSheet, ScrollView, TouchableOpacity, Alert, Linking, ActivityIndicator, Modal, TextInput, I18nManager, } from 'react-native';
import { useRouter, useLocalSearchParams } from 'expo-router';
import { useFocusEffect } from '@react-navigation/native';
import { LinearGradient } from 'expo-linear-gradient';
import { useDataRefresh } from '@/contexts/DataRefreshContext';
import { useAuth } from '@/contexts/AuthContext';
import { ArrowRight, MessageCircle, Settings, Plus, Receipt, ChartBar as BarChart3, Calculator, FileText, ChevronDown, ChevronUp, Search, X, Calendar, Link as LinkIcon } from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import { buildReadableCustomerFilter } from '@/services/userScopeService';import { Customer, AccountMovement, CURRENCIES } from '@/types/database';
import { format, isSameMonth, isSameYear, startOfDay, endOfDay } from 'date-fns';
import { ar } from 'date-fns/locale';
import * as Print from 'expo-print';
import * as Sharing from 'expo-sharing';
import { generateAccountStatementHTML } from '@/utils/accountStatementGenerator';
import { getLogoBase64 } from '@/utils/logoHelper';
import QuickAddMovementSheet from '@/components/QuickAddMovementSheet';
import CalendarRangePicker from '@/components/CalendarRangePicker';
import {
  fetchWhatsAppTemplates,
  replaceTemplateVariables,
  formatBalancesForWhatsApp,
  formatMovementsForWhatsApp,
  getFormattedDate,
} from '@/utils/whatsappTemplates';
import {
  getMovementApprovalLabel,
  isPendingMovement,
  isPostedMovement,
  isRejectedMovement,
  normalizeMovementApprovalStatus,
  requiresCounterpartyApproval,
} from '@/utils/movementApproval';

interface GroupedMovements {
  [key: string]: AccountMovement[];
}

interface CurrencyBalance {
  currency: string;
  incoming: number;
  outgoing: number;
  balance: number;
}

function groupMovementsByMonth(movements: AccountMovement[]): GroupedMovements {
  const grouped: GroupedMovements = {};

  movements.forEach((movement) => {
    const date = new Date(movement.created_at);
    const key = format(date, 'MMMM yyyy', { locale: ar });

    if (!grouped[key]) {
      grouped[key] = [];
    }
    grouped[key].push(movement);
  });

  return grouped;
}

function getCurrencySymbol(code: string): string {
  const currency = CURRENCIES.find((c) => c.code === code);
  return currency?.symbol || code;
}

function getCurrencyName(code: string): string {
  const currency = CURRENCIES.find((c) => c.code === code);
  return currency?.name || code;
}

interface CurrencyTotals {
  currency: string;
  incoming: number;
  outgoing: number;
}

function calculateCurrencyTotals(
  movements: AccountMovement[],
): CurrencyTotals[] {
  const currencyMap: { [key: string]: CurrencyTotals } = {};

  movements.forEach((movement) => {
    const currency = movement.currency;
    if (!currencyMap[currency]) {
      currencyMap[currency] = {
        currency,
        incoming: 0,
        outgoing: 0,
      };
    }

    const amount = Number(movement.amount);
    if (movement.movement_type === 'incoming') {
      currencyMap[currency].incoming += amount;
    } else {
      currencyMap[currency].outgoing += amount;
    }
  });

  return Object.values(currencyMap);
}

function calculateBalanceByCurrency(
  movements: AccountMovement[],
): CurrencyBalance[] {
  const currencyMap: { [key: string]: CurrencyBalance } = {};

  movements.forEach((movement) => {
    const currency = movement.currency;
    if (!currencyMap[currency]) {
      currencyMap[currency] = {
        currency,
        incoming: 0,
        outgoing: 0,
        balance: 0,
      };
    }

    const amount = Number(movement.amount);

    if (movement.movement_type === 'incoming') {
      currencyMap[currency].incoming += amount;
    } else {
      currencyMap[currency].outgoing += amount;
    }
  });

  Object.values(currencyMap).forEach((item) => {
    item.balance = item.incoming - item.outgoing;
  });

  return Object.values(currencyMap).filter((item) => item.balance !== 0);
}

function shouldIncludeMovementInBalance(movement: AccountMovement): boolean {
  return !(movement as any).is_commission_movement && isPostedMovement(movement);
}

function getCombinedAmount(
  movement: AccountMovement,
  allMovements: AccountMovement[],
): number {
  const baseAmount = Number(movement.amount);

  const relatedCommissions = allMovements.filter(
    (m) =>
      (m as any).is_commission_movement === true &&
      (m as any).related_commission_movement_id === movement.id &&
      m.customer_id === movement.customer_id &&
      m.movement_type === movement.movement_type &&
      m.currency === movement.currency
  );

  const commissionTotal = relatedCommissions.reduce(
    (sum, m) => sum + Number(m.amount),
    0,
  );

  return baseAmount + commissionTotal;
}

function getRelatedCommission(
  movement: AccountMovement,
  allMovements: AccountMovement[],
): number {
  const relatedCommissions = allMovements.filter(
    (m) =>
      (m as any).is_commission_movement === true &&
      (m as any).related_commission_movement_id === movement.id &&
      m.customer_id === movement.customer_id &&
      m.movement_type === movement.movement_type &&
      m.currency === movement.currency
  );

  return relatedCommissions.reduce((sum, m) => sum + Number(m.amount), 0);
}

function isMovementCreatedByCurrentUser(
  movement: AccountMovement,
  currentUser?: {
    userId?: string | null;
    userName?: string | null;
    fullName?: string | null;
  } | null,
): boolean {
  const createdByUserId = (movement as any).created_by_user_id;
  const sourceUserId = (movement as any).source_user_id;
  const createdByUserName = (movement as any).created_by_user_name?.trim();

  return (
    (Boolean(currentUser?.userId) && sourceUserId === currentUser?.userId) ||
    (Boolean(currentUser?.userId) && createdByUserId === currentUser?.userId) ||
    (Boolean(currentUser?.fullName) && createdByUserName === currentUser?.fullName) ||
    (Boolean(currentUser?.userName) && createdByUserName === currentUser?.userName)
  );
}

function getMovementCreatorLabel(
  movement: AccountMovement,
  currentUser?: {
    userId?: string | null;
    userName?: string | null;
    fullName?: string | null;
  } | null,
): string {
  if (isMovementCreatedByCurrentUser(movement, currentUser)) {
    return 'أنا';
  }

  return 'العميل';
}

function renderMovementApprovalBadge(movement: Pick<AccountMovement, 'approval_status' | 'pending_approval'>) {
  const normalizedStatus = normalizeMovementApprovalStatus(movement);
  const label = getMovementApprovalLabel(movement);

  if (normalizedStatus === 'pending') {
    return (
      <View style={[styles.movementStatusBadge, styles.movementStatusBadgePending]}>
        <Text style={[styles.movementStatusText, styles.movementStatusTextPending]}>
          {label}
        </Text>
      </View>
    );
  }

  if (normalizedStatus === 'rejected') {
    return (
      <View style={[styles.movementStatusBadge, styles.movementStatusBadgeRejected]}>
        <Text style={[styles.movementStatusText, styles.movementStatusTextRejected]}>
          {label}
        </Text>
      </View>
    );
  }

  if (normalizedStatus === 'approved') {
    return (
      <View style={[styles.movementStatusBadge, styles.movementStatusBadgeApproved]}>
        <Text style={[styles.movementStatusText, styles.movementStatusTextApproved]}>
          {label}
        </Text>
      </View>
    );
  }

  return null;
}


function getMovementApprovalLookupIds(movement: AccountMovement): string[] {
  return Array.from(
    new Set(
      [
        movement.id,
        movement.mirror_movement_id,
        movement.related_transfer_id,
        movement.related_commission_movement_id,
      ].filter((value): value is string => Boolean(value)),
    ),
  );
}

export default function CustomerDetailsScreen() {
  const router = useRouter();
  const { id } = useLocalSearchParams();
  const { lastRefreshTime } = useDataRefresh();
  const { settings, currentUser } = useAuth();
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [movements, setMovements] = useState<AccountMovement[]>([]);
  const [totalIncoming, setTotalIncoming] = useState(0);
  const [totalOutgoing, setTotalOutgoing] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [isPrinting, setIsPrinting] = useState(false);
  const [showCurrencyDetails, setShowCurrencyDetails] = useState(false);
  const [showQuickAdd, setShowQuickAdd] = useState(false);
  const [showSettingsMenu, setShowSettingsMenu] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [showDateRangeModal, setShowDateRangeModal] = useState(false);
  const [startDate, setStartDate] = useState<Date | null>(null);
  const [endDate, setEndDate] = useState<Date | null>(null); const loadCustomerData = useCallback(async () => {
    try {
      if (!currentUser?.userId || !currentUser?.userName) {
        console.error('[CustomerDetails] Missing user data:', currentUser);
        Alert.alert('خطأ', 'لم يتم العثور على المستخدم');
        router.back();
        return;
      }

      console.log('[CustomerDetails] Loading data for user:', currentUser.userName);

      const [customerResult, movementsResult] = await Promise.all([
        supabase
          .from('customers')
          .select('*, linked_user:app_security!customers_linked_user_id_fkey(id, user_name, full_name, account_number)')
          .eq('id', id)
          .or(buildReadableCustomerFilter(currentUser.userId, true))
          .maybeSingle(),
        supabase.rpc('get_customer_movements_with_user', {
          p_user_name: currentUser.userName,
          p_customer_id: id
        })
      ]);

      console.log('[CustomerDetails] Customer result:', customerResult.error ? 'ERROR' : 'SUCCESS', customerResult.error?.message);
      console.log('[CustomerDetails] Movements result:', movementsResult.error ? 'ERROR' : 'SUCCESS', movementsResult.error?.message);

      if (customerResult.error || !customerResult.data) {
        Alert.alert('خطأ', 'لم يتم العثور على العميل');
        router.back();
        return;
      }

      if (movementsResult.error) {
        console.error('[CustomerDetails] Movements error details:', JSON.stringify(movementsResult.error, null, 2));
        Alert.alert('خطأ', 'حدث خطأ أثناء تحميل الحركات المالية');
        setCustomer(customerResult.data);
        setMovements([]);
        return;
      }

      // معالجة نتيجة الدالة - قد تكون array مباشرة أو داخل data
      const movementsData: AccountMovement[] = Array.isArray(movementsResult.data)
        ? movementsResult.data
        : (movementsResult.data || []);

      console.log('[CustomerDetails] Number of movements:', movementsData.length);

      setCustomer(customerResult.data);
      setMovements(movementsData);

      const approvedOnlyMovements = movementsData.filter((m) =>
        shouldIncludeMovementInBalance(m as AccountMovement)
      );

      const incoming =
        approvedOnlyMovements
          ?.filter((m) => m.movement_type === 'incoming')
          .reduce((sum, m) => sum + Number(m.amount), 0) || 0;

      const outgoing =
        approvedOnlyMovements
          ?.filter((m) => m.movement_type === 'outgoing')
          .reduce((sum, m) => sum + Number(m.amount), 0) || 0;

      setTotalIncoming(incoming);
      setTotalOutgoing(outgoing);
    } catch (error) {
      console.error('Error loading customer data:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء تحميل البيانات');
    } finally {
      setIsLoading(false);
    }
  }, [id, currentUser]); useFocusEffect(
    useCallback(() => {
      if (id) {
        setIsLoading(true);
        loadCustomerData(); }
    }, [id, loadCustomerData]),
  );

  useEffect(() => {
    if (id && !isLoading) {
      console.log('[CustomerDetails] Auto-refreshing due to data change');
      loadCustomerData();
    }
  }, [lastRefreshTime]);

  // الاستماع للتغييرات في الإشعارات لتحديث العداد تلقائياً
  useEffect(() => {
    if (!currentUser?.userId) return;

    const channel = supabase
      .channel(`notifications-counter-${currentUser.userId}-${Date.now()}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'movement_notifications',
          filter: `user_id=eq.${currentUser.userId}`,
        },
        () => { },
      )
      .subscribe();

    return () => {
      try {
        supabase.removeChannel(channel);
      } catch {
        // Ignore duplicate cleanup errors.
      }
    };
  }, [currentUser?.userId]);

  const handleWhatsApp = async () => {
    if (customer?.phone) {
      const cleanPhone = customer.phone.replace(/[^0-9]/g, '');
      const approvedOnlyMovements = movements.filter(shouldIncludeMovementInBalance);
      const balances = calculateBalanceByCurrency(approvedOnlyMovements);

      const templates = await fetchWhatsAppTemplates();

      const balanceText = balances.length === 0
        ? 'الحساب متساوي'
        : formatBalancesForWhatsApp(
            balances.map(b => ({
              currency: getCurrencySymbol(b.currency),
              balance: b.balance
            }))
          );

      const message = replaceTemplateVariables(templates.account_statement, {
        customer_name: customer.name,
        account_number: customer.account_number,
        date: getFormattedDate(),
        balance: balanceText,
      });

      const encodedMessage = encodeURIComponent(message);
      Linking.openURL(
        `whatsapp://send?phone=${cleanPhone}&text=${encodedMessage}`,
      );
    } else {
      Alert.alert('تنبيه', 'لا يوجد رقم هاتف مسجل لهذا العميل');
    }
  };

  const handlePrint = () => {
    if (!customer) {
      return;
    }

    const approvedOnlyMovements = movements.filter(shouldIncludeMovementInBalance);

    if (approvedOnlyMovements.length === 0) {
      Alert.alert('تنبيه', 'لا توجد حركات معتمدة لطباعتها');
      return;
    }

    setShowDateRangeModal(true);
  };

  const executePrint = async (movementsToPrint: AccountMovement[]) => {
    if (!customer) {
      return;
    }

    if (movementsToPrint.length === 0) {
      Alert.alert('تنبيه', 'لا توجد حركات في الفترة المحددة');
      return;
    }

    setIsPrinting(true);
    setShowDateRangeModal(false);

    try {
      let logoDataUrl: string | undefined;
      try {
        console.log('[CustomerDetails] Loading logo for PDF...');
        logoDataUrl = await getLogoBase64(false, null, { userId: currentUser?.userId });

        if (logoDataUrl && logoDataUrl.length > 0) {
          console.log('[CustomerDetails] Logo loaded successfully. Length:', logoDataUrl.length);
        } else {
          console.warn('[CustomerDetails] Logo is empty, will use fallback');
          logoDataUrl = undefined;
        }
      } catch (logoError) {
        console.warn(
          '[CustomerDetails] Could not load logo, continuing without it:',
          logoError,
        );
        logoDataUrl = undefined;
      }

      console.log('[CustomerDetails] Generating HTML for PDF...');
      const html = generateAccountStatementHTML(
        customer.name,
        movementsToPrint,
        logoDataUrl,
        customer.is_profit_loss_account,
      );

      console.log('[CustomerDetails] Creating PDF file...');
      const { uri } = await Print.printToFileAsync({ html });
      console.log('[CustomerDetails] PDF created at:', uri);

      const canShare = await Sharing.isAvailableAsync();
      if (canShare) {
        await Sharing.shareAsync(uri, {
          mimeType: 'application/pdf',
          dialogTitle: `كشف حساب ${customer.name}`,
          UTI: 'com.adobe.pdf',
        });
      } else {
        Alert.alert('نجح', 'تم إنشاء كشف الحساب بنجاح');
      }
    } catch (error) {
      console.error('[CustomerDetails] Error generating PDF:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء إنشاء كشف الحساب');
    } finally {
      setIsPrinting(false);
    }
  };

  const handleCalendarConfirm = (selectedStartDate: Date, selectedEndDate: Date) => {
    setStartDate(selectedStartDate);
    setEndDate(selectedEndDate);
    setShowDateRangeModal(false);

    const filtered = movements.filter((movement) => {
      if (!shouldIncludeMovementInBalance(movement)) {
        return false;
      }

      const movementDate = new Date(movement.created_at);
      return (
        movementDate >= startOfDay(selectedStartDate) &&
        movementDate <= endOfDay(selectedEndDate)
      );
    });

    executePrint(filtered);
  };

  const handlePrintAll = () => {
    executePrint(movements.filter(shouldIncludeMovementInBalance));
  };

  const handleSettleUp = () => {
    Alert.alert('تسوية الحساب', 'ميزة تسوية الحساب قيد التطوير');
  };

  const handleResetAccount = () => {
    if (!customer) return;

    Alert.alert(
      'تصفير الحساب',
      `هل أنت متأكد من تصفير حساب ${customer.name}?\n\nسيتم حذف جميع الحركات (${movements.length} حركة) مع الاحتفاظ ببيانات العميل.\n\nلا يمكن التراجع عن هذه العملية!`,
      [
        { text: 'إلغاء', style: 'cancel' },
        {
          text: 'تصفير',
          style: 'destructive',
          onPress: async () => {
            try {
              const { data, error } = await supabase.rpc(
                'reset_customer_account',
                {
                  p_customer_id: id,
                },
              );

              if (error) {
                Alert.alert('خطأ', 'حدث خطأ أثناء تصفير الحساب');
                console.error('Error resetting account:', error);
                return;
              }

              const result = data as {
                success: boolean;
                message: string;
                movements_deleted: number;
              };

              if (result.success) {
                Alert.alert(
                  'نجح',
                  `تم تصفير الحساب بنجاح\nتم حذف ${result.movements_deleted} حركة`,
                  [
                    {
                      text: 'حسناً',
                      onPress: () => {
                        loadCustomerData();
                      },
                    },
                  ],
                );
              } else {
                Alert.alert('خطأ', result.message);
              }
            } catch (error) {
              console.error('Error resetting account:', error);
              Alert.alert('خطأ', 'حدث خطأ غير متوقع');
            }
          },
        },
      ],
    );
  };

  const handleDeleteCustomer = () => {
    if (!customer) return;

    const approvedOnlyMovements = movements.filter(shouldIncludeMovementInBalance);
    const balances = calculateBalanceByCurrency(approvedOnlyMovements);
    const hasBalance =
      balances.length > 0 && balances.some((b) => b.balance !== 0);

    let warningMessage = `هل أنت متأكد من حذف ${customer.name} نهائياً؟\n\n`;

    if (hasBalance) {
      warningMessage += 'تحذير: العميل لديه رصيد غير صفري!\n';
      balances.forEach((currBalance) => {
        const symbol = getCurrencySymbol(currBalance.currency);
        if (currBalance.balance > 0) {
          warningMessage += `• له ${Math.round(currBalance.balance)} ${symbol}\n`;
        } else {
          warningMessage += `• عليه ${Math.round(Math.abs(currBalance.balance))} ${symbol}\n`;
        }
      });
      warningMessage += '\n';
    }

    warningMessage += `سيتم حذف:\n`;
    warningMessage += `• جميع بيانات العميل\n`;
    warningMessage += `• جميع الحركات (${movements.length} حركة)\n\n`;
    warningMessage += `لا يمكن التراجع عن هذه العملية!`;

    Alert.alert('حذف العميل', warningMessage, [
      { text: 'إلغاء', style: 'cancel' },
      {
        text: 'حذف',
        style: 'destructive',
        onPress: () => {
          Alert.alert('تأكيد نهائي', 'هل أنت متأكد تماماً من حذف هذا العميل؟', [
            { text: 'إلغاء', style: 'cancel' },
            {
              text: 'نعم، احذف',
              style: 'destructive',
              onPress: async () => {
                try {
                  const { data, error } = await supabase.rpc(
                    'delete_customer_completely',
                    {
                      p_customer_id: id,
                    },
                  );

                  if (error) {
                    Alert.alert('خطأ', 'حدث خطأ أثناء حذف العميل');
                    console.error('Error deleting customer:', error);
                    return;
                  }

                  const result = data as {
                    success: boolean;
                    message: string;
                    movements_deleted: number;
                  };

                  if (result.success) {
                    Alert.alert(
                      'تم الحذف',
                      `تم حذف العميل بنجاح\nتم حذف ${result.movements_deleted} حركة`,
                      [
                        {
                          text: 'حسناً',
                          onPress: () => router.back(),
                        },
                      ],
                    );
                  } else {
                    Alert.alert('خطأ', result.message);
                  }
                } catch (error) {
                  console.error('Error deleting customer:', error);
                  Alert.alert('خطأ', 'حدث خطأ غير متوقع');
                }
              },
            },
          ]);
        },
      },
    ]);
  };

  const handleShareAccount = async () => {
    if (!customer) return;

    const templates = await fetchWhatsAppTemplates();
    const approvedOnlyMovements = movements.filter(shouldIncludeMovementInBalance);
    const balances = calculateBalanceByCurrency(approvedOnlyMovements);

    const balancesText = balances.length === 0
      ? 'الحساب متساوي'
      : formatBalancesForWhatsApp(
          balances.map(b => ({
            currency: getCurrencySymbol(b.currency),
            balance: b.balance
          }))
        );

    const movementsFormatted = approvedOnlyMovements.map(m => ({
      created_at: m.created_at,
      movement_type: m.movement_type,
      amount: Number(m.amount),
      currency: getCurrencySymbol(m.currency),
      notes: m.notes,
    }));

    const movementsText = formatMovementsForWhatsApp(movementsFormatted);

    const message = replaceTemplateVariables(templates.share_account, {
      customer_name: customer.name,
      account_number: customer.account_number,
      date: getFormattedDate(),
      balances: balancesText,
      movements: movementsText,
      shop_name: settings?.shop_name || 'محل الصرافة',
    });

    try {
      await Linking.openURL(
        `whatsapp://send?text=${encodeURIComponent(message)}`,
      );
    } catch (error) {
      Alert.alert('مشاركة الحساب', message, [
        { text: 'إغلاق', style: 'cancel' },
      ]);
    }
  };

  const handleAddMovement = () => {
    console.log('[CustomerDetails] handleAddMovement called');
    setShowQuickAdd(true);
    console.log('[CustomerDetails] setShowQuickAdd(true) called');
  };

  const openCustomerNotifications = useCallback(() => {
    if (!id) return;

    router.push({
      pathname: '/customer-notifications',
      params: {
        customerId: String(id),
        customerName: customer?.name || '',
      },
    });
  }, [customer?.name, id, router]);

  const handleMovementPress = async (movement: AccountMovement) => {
    if (isPendingMovement(movement)) {
      openCustomerNotifications();
      return;
    }

    const movementTypeText =
      movement.movement_type === 'outgoing' ? 'عليه' : 'له';
    const currencySymbol = getCurrencySymbol(movement.currency);
    const amount = Math.round(Number(movement.amount));

    Alert.alert(
      movementTypeText,
      `${amount} ${currencySymbol}`,
      [
        {
          text: 'طباعة السند',
          onPress: () => handlePrintMovementReceipt(movement),
        },
        {
          text: 'تعديل',
          onPress: () => handleEditMovement(movement),
        },
        {
          text: 'حذف',
          onPress: () => handleDeleteMovement(movement),
          style: 'destructive',
        },
        {
          text: 'إلغاء',
          style: 'cancel',
        },
      ],
    );
  };

  const handleEditMovement = (movement: AccountMovement) => {
    router.push({
      pathname: '/edit-movement',
      params: {
        movementId: movement.id,
        customerName: customer?.name,
        customerAccountNumber: customer?.account_number,
  customerId: customer?.id,
      },
    });
  };

  const handleDeleteMovement = (movement: AccountMovement) => {
    const movementTypeText =
      movement.movement_type === 'outgoing' ? 'عليه' : 'له';
    const currencySymbol = getCurrencySymbol(movement.currency);
    const amount = Math.round(Number(movement.amount));

    Alert.alert(
      'تأكيد الحذف',
      `هل أنت متأكد من حذف هذه الحركة؟\n\n${movementTypeText}\nالمبلغ: ${amount} ${currencySymbol}\n\nلا يمكن التراجع.`,
      [
        { text: 'إلغاء', style: 'cancel' },
        {
          text: 'حذف',
          style: 'destructive',
          onPress: () => confirmDeleteMovement(movement),
        },
      ],
    );
  };

  const confirmDeleteMovement = async (movement: AccountMovement) => {
    if (!currentUser?.userName) {
      Alert.alert('خطأ', 'لم يتم العثور على معلومات المستخدم');
      return;
    }

    try {
      const { data, error } = await supabase.rpc('request_movement_deletion', {
        p_movement_id: movement.id,
        p_user_name: currentUser.userName,
      });

      if (error) throw error;

      const result = data as any;

      if (result?.deleted) {
        Alert.alert('تم الحذف', 'تم حذف الحركة بنجاح');
      } else if (result?.requires_approval) {
        Alert.alert(
          'طلب الموافقة',
          'تم إرسال طلب الموافقة على الحذف إلى منشئ الحركة. سيتم حذف الحركة بعد موافقته.'
        );
      }

      loadCustomerData();
    } catch (error: any) {
      console.error('Error deleting movement:', error);
      Alert.alert('خطأ', error.message || 'حدث خطأ أثناء حذف الحركة');
    }
  };

  const handlePrintMovementReceipt = (movement: AccountMovement) => {
    router.push({
      pathname: '/receipt-preview',
      params: {
        movementId: movement.id,
        customerName: customer?.name,
        customerAccountNumber: customer?.account_number,
      },
    });
  };

  const balance = customer?.balance || 0;

  const filteredMovements = movements
    .filter((movement) => {
      if (customer?.is_profit_loss_account) {
        return true;
      }
      return (movement as any).is_commission_movement !== true;
    })
    .filter((movement) => {
      if (!searchQuery.trim()) return true;

      const query = searchQuery.toLowerCase();
      const movementNumber = movement.movement_number.toLowerCase();
      const notes = (movement.notes || '').toLowerCase();
      const amount = movement.amount.toString();
      const date = format(new Date(movement.created_at), 'dd/MM/yyyy');
      const movementTypeText =
        movement.movement_type === 'outgoing' ? 'عليه' : 'له';
      const senderName = (movement.sender_name || '').toLowerCase();
      const beneficiaryName = (movement.beneficiary_name || '').toLowerCase();

      return (
        movementNumber.includes(query) ||
        notes.includes(query) ||
        amount.includes(query) ||
        date.includes(query) ||
        movementTypeText.includes(query) ||
        senderName.includes(query) ||
        beneficiaryName.includes(query)
      );
    });

  const approvedMovements = movements.filter((movement) => shouldIncludeMovementInBalance(movement));

  const pendingMovements = movements.filter(
    (movement) =>
      !(movement as any).is_commission_movement &&
      isPendingMovement(movement) &&
      !(movement as any).is_voided
  ); const groupedMovements = groupMovementsByMonth(filteredMovements);
  const currencyBalances = calculateBalanceByCurrency(approvedMovements);
  const currencyTotals = calculateCurrencyTotals(approvedMovements);
  const balancesOwedToCustomer = currencyBalances.filter((currBalance) => currBalance.balance > 0);
  const balancesOwedFromCustomer = currencyBalances.filter((currBalance) => currBalance.balance < 0);

  if (isLoading) {
    return (
      <View style={styles.container}>
        <LinearGradient
          colors={['#059669', '#10B981', '#34D399']}
          style={styles.gradientHeader}
        >
          <View style={styles.headerContent}>
            <TouchableOpacity
              style={styles.backButton}
              onPress={() => router.back()}
            >
              <ArrowRight size={24} color="#FFFFFF" />
            </TouchableOpacity>
            <Text style={styles.headerTitle}>تفاصيل العميل</Text>
            <View style={{ width: 40 }} />
          </View>
        </LinearGradient>
        <View style={styles.loadingContainer}>
          <Text style={styles.loadingText}>جاري التحميل...</Text>
        </View>
      </View>
    );
  }

  if (!customer) return null;

  return (
    <View style={styles.container}>
      <LinearGradient
        colors={['#059669', '#10B981', '#34D399']}
        style={styles.gradientHeader}
      >
        <View style={styles.headerContent}>
          <TouchableOpacity
            style={styles.backButton}
            onPress={() => router.back()}
          >
            <ArrowRight size={24} color="#FFFFFF" />
          </TouchableOpacity>
          <Text style={styles.headerTitle} numberOfLines={1} ellipsizeMode="tail">
            {customer.name}
          </Text>
          <TouchableOpacity
            style={styles.settingsButton}
            onPress={() => setShowSettingsMenu(true)}
          >
            <Settings size={24} color="#FFFFFF" />
          </TouchableOpacity>
        </View>
        <View style={styles.headerInfo}>
          <View style={styles.headerBadge}>
            <Receipt size={14} color="#FFFFFF" />
            <Text style={styles.headerBadgeText}>{approvedMovements.length} حركة معتمدة</Text>
          </View>
          <View style={styles.headerBadge}>
            <Text style={styles.headerBadgeText}>
              رقم الحساب: {customer.account_number}
            </Text>
          </View>
          {customer.linked_user_id && (customer as any).linked_user && (
            <TouchableOpacity
              style={[styles.headerBadge, styles.linkedUserBadge]}
              onPress={() => Alert.alert(
                'حساب مرتبط',
                `هذا العميل مرتبط بحساب المستخدم:\n\n${(customer as any).linked_user.full_name}\nرقم الحساب: ${(customer as any).linked_user.account_number}\n\nجميع الحركات متزامنة بشكل تلقائي مع حساب هذا المستخدم.`,
                [{ text: 'حسناً' }]
              )}
            >
              <LinkIcon size={14} color="#FFFFFF" />
              <Text style={styles.headerBadgeText}>
                مرتبط بحساب {(customer as any).linked_user?.full_name || 'مستخدم'}
              </Text>
            </TouchableOpacity>
          )}
        </View>
      </LinearGradient>

      <ScrollView style={styles.content}>
        <View style={styles.summarySection}>
          <View style={styles.summaryPanel}>
            <View style={styles.summarySectionHeader}>
              <Text style={styles.summarySectionTitle}>ملخص الحساب</Text>
              <View style={styles.summarySectionIcon}>
                <Calculator size={14} color="#7C3AED" />
              </View>
            </View>

            <View style={styles.summaryCardsRow}>
              <View style={[styles.summaryCard, styles.summaryCardNegative]}>
                <View style={styles.summaryCardHeader}>
                  <View style={styles.summaryCardHeaderSide}>
                    <View style={[styles.summaryCardToneDot, styles.summaryCardToneDotNegative]} />
                    <Text style={[styles.summaryCardTitle, styles.summaryCardTitleNegative]}>عليه</Text>
                  </View>
                  <Text style={styles.summaryCardHint}>
                    {balancesOwedFromCustomer.length === 0
                      ? 'لا يوجد'
                      : `${balancesOwedFromCustomer.length} عملات`}
                  </Text>
                </View>

                {balancesOwedFromCustomer.length === 0 ? (
                  <View style={styles.summaryCardEmptyRow}>
                    <Text style={styles.summaryCardEmpty}>لا يوجد</Text>
                  </View>
                ) : (
                  balancesOwedFromCustomer.map((currBalance) => (
                    <View key={`negative-${currBalance.currency}`} style={styles.summaryCardRow}>
                      <View style={[styles.summaryCardCurrencyChip, styles.summaryCardCurrencyChipNegative]}>
                        <Text style={[styles.summaryCardCurrency, styles.summaryCardCurrencyNegative]}>
                          {currBalance.currency}
                        </Text>
                      </View>
                      <Text style={[styles.summaryCardAmount, styles.summaryCardAmountNegative]}>
                        {Math.round(Math.abs(currBalance.balance))} {getCurrencySymbol(currBalance.currency)}
                      </Text>
                    </View>
                  ))
                )}
              </View>

              <View style={[styles.summaryCard, styles.summaryCardPositive]}>
                <View style={styles.summaryCardHeader}>
                  <View style={styles.summaryCardHeaderSide}>
                    <View style={[styles.summaryCardToneDot, styles.summaryCardToneDotPositive]} />
                    <Text style={[styles.summaryCardTitle, styles.summaryCardTitlePositive]}>له</Text>
                  </View>
                  <Text style={styles.summaryCardHint}>
                    {balancesOwedToCustomer.length === 0
                      ? 'لا يوجد'
                      : `${balancesOwedToCustomer.length} عملات`}
                  </Text>
                </View>

                {balancesOwedToCustomer.length === 0 ? (
                  <View style={styles.summaryCardEmptyRow}>
                    <Text style={styles.summaryCardEmpty}>لا يوجد</Text>
                  </View>
                ) : (
                  balancesOwedToCustomer.map((currBalance) => (
                    <View key={`positive-${currBalance.currency}`} style={styles.summaryCardRow}>
                      <View style={[styles.summaryCardCurrencyChip, styles.summaryCardCurrencyChipPositive]}>
                        <Text style={[styles.summaryCardCurrency, styles.summaryCardCurrencyPositive]}>
                          {currBalance.currency}
                        </Text>
                      </View>
                      <Text style={[styles.summaryCardAmount, styles.summaryCardAmountPositive]}>
                        {Math.round(currBalance.balance)} {getCurrencySymbol(currBalance.currency)}
                      </Text>
                    </View>
                  ))
                )}
              </View>
            </View>
          </View>
        </View>

        {currencyTotals.length > 0 && (
          <View style={styles.currencyDetailsSection}>
            <TouchableOpacity
              style={styles.currencyDetailsToggle}
              onPress={() => setShowCurrencyDetails(!showCurrencyDetails)}
            >
              <View style={styles.currencyDetailsToggleContent}>
                {showCurrencyDetails ? (
                  <ChevronUp size={20} color="#6B7280" />
                ) : (
                  <ChevronDown size={20} color="#6B7280" />
                )}
                <Text style={styles.currencyDetailsToggleText}>
                  ملخص الحركات
                </Text>
              </View>
            </TouchableOpacity>

            {showCurrencyDetails && (
              <View style={styles.currencyDetailsContent}>
                {currencyTotals.map((total) => (
                  <View key={total.currency} style={styles.currencyDetailsCard}>
                    <Text style={styles.currencyDetailsName}>
                      {getCurrencyName(total.currency)}:
                    </Text>
                    <View style={styles.currencyDetailsRow}>
                      <Text style={styles.currencyDetailsValueGreen}>
                        {total.incoming.toFixed(2)}{' '}
                        {getCurrencySymbol(total.currency)}
                      </Text>
                      <Text style={styles.currencyDetailsLabelGreen}>
                        له:
                      </Text>
                    </View>
                    <View style={styles.currencyDetailsRow}>
                      <Text style={styles.currencyDetailsValueRed}>
                        {total.outgoing.toFixed(2)}{' '}
                        {getCurrencySymbol(total.currency)}
                      </Text>
                      <Text style={styles.currencyDetailsLabelRed}>عليه:</Text>
                    </View>
                  </View>
                ))}
              </View>
            )}
          </View>
        )}

        <View style={styles.tabButtons}>
          <TouchableOpacity
            style={styles.tabButtonPrimary}
            onPress={handleShareAccount}
          >
            <Text style={styles.tabButtonPrimaryText}>مشاركة الحساب</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.tabButton, isPrinting && styles.tabButtonDisabled]}
            onPress={handlePrint}
            disabled={isPrinting || movements.length === 0}
          >
            {isPrinting ? (
              <ActivityIndicator size="small" color="#6B7280" />
            ) : (
              <FileText size={16} color="#6B7280" />
            )}
            <Text style={styles.tabButtonText}>طباعة PDF</Text>
          </TouchableOpacity>
          <TouchableOpacity style={styles.tabButton} onPress={handleWhatsApp}>
            <MessageCircle size={16} color="#6B7280" />
            <Text style={styles.tabButtonText}>واتساب</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.tabButton}
            onPress={() => openCustomerNotifications()}
          >
            <Text style={styles.tabButtonText}>الإشعارات</Text>
          </TouchableOpacity>
        </View>

        <View style={styles.searchSection}>
          <View style={styles.searchContainer}>
            <Search size={20} color="#9CA3AF" style={styles.searchIcon} />
            <TextInput
              style={styles.searchInput}
              placeholder="ابحث في الحركات (رقم، مبلغ، تاريخ، ملاحظات...)"
              placeholderTextColor="#9CA3AF"
              value={searchQuery}
              onChangeText={setSearchQuery}
              textAlign="right"
            />
            {searchQuery !== '' && (
              <TouchableOpacity
                onPress={() => setSearchQuery('')}
                style={styles.clearButton}
              >
                <X size={18} color="#9CA3AF" />
              </TouchableOpacity>
            )}
          </View>
          {searchQuery !== '' && (
            <Text style={styles.searchResultText}>
              {filteredMovements.length} نتيجة
            </Text>
          )}
        </View>

        <View style={styles.movementsSection}>
          {filteredMovements.length === 0 ? (
            <View style={styles.emptyContainer}>
              <Text style={styles.emptyText}>لا توجد حركات</Text>
            </View>
          ) : (
            Object.entries(groupedMovements).map(
              ([monthYear, monthMovements]) => (
	                <View key={monthYear}>
	                  <Text style={styles.monthHeader}>{monthYear}</Text>
                    <View style={styles.movementColumnsHeader}>
                      <View style={styles.movementDateHeader}>
                        <Text style={styles.movementColumnLabel}>التاريخ</Text>
                      </View>
                      <View style={styles.movementCreatorHeader}>
                        <Text style={styles.movementColumnLabel}>المنشأ</Text>
                      </View>
                      <View style={styles.movementTypeHeader}>
                        <Text style={styles.movementColumnLabel}>الحركة</Text>
                      </View>
                      <View style={styles.movementCurrencyHeader}>
                        <Text style={styles.movementColumnLabel}>العملة</Text>
                      </View>
                      <View style={styles.movementAmountHeader}>
                        <Text style={styles.movementColumnLabel}>المبلغ</Text>
                      </View>
                    </View>
	                  {monthMovements.map((movement) => {
                      const creatorLabel = getMovementCreatorLabel(movement, currentUser);
                      const isCurrentUserCreator = isMovementCreatedByCurrentUser(
                        movement,
                        currentUser,
                      );

                      return (
	                    <TouchableOpacity
	                      key={movement.id}
	                      style={[
	                        styles.movementRow,
	                        isPendingMovement(movement) && styles.movementRowPending,
	                        isRejectedMovement(movement) && styles.movementRowRejected,
	                      ]}
	                      activeOpacity={0.7}
	                      onPress={() => handleMovementPress(movement)}
	                    >
	                      <View style={styles.movementDate}>
	                        <Text style={styles.movementDateMonth}>
	                          {format(new Date(movement.created_at), 'MMM', {
	                            locale: ar,
	                          })}
	                        </Text>
	                        <Text style={styles.movementDateDay}>
	                          {format(new Date(movement.created_at), 'dd')}
	                        </Text>
	                      </View>

	                      <View style={styles.movementCreatorContainer}>
	                        <Text
	                          style={[
	                            styles.movementCreatorValue,
	                            isCurrentUserCreator &&
	                              styles.movementCreatorValueCurrent,
	                          ]}
	                          numberOfLines={1}
	                        >
	                          {creatorLabel}
	                        </Text>
                          {renderMovementApprovalBadge(movement)}
	                      </View>

	                      <View style={styles.movementTypeContainer}>
	                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
	                          <Text
	                            style={[
	                              styles.movementType,
	                              {
	                                color: (movement as any).is_internal_transfer
	                                  ? '#F59E0B'
	                                  : movement.movement_type === 'outgoing'
	                                    ? '#EF4444'
	                                    : '#10B981',
	                              },
	                            ]}
	                          >
	                            {(movement as any).is_internal_transfer
	                              ? 'تحويل داخلي'
	                              : movement.movement_type === 'outgoing'
	                                ? 'عليه'
	                                : 'له'}
	                          </Text>
	                        </View>
	                        {(movement as any).is_internal_transfer && (
	                          <Text style={styles.movementNotes} numberOfLines={1}>
	                            {movement.movement_type === 'outgoing'
	                              ? `إلى: ${movement.beneficiary_name || 'عميل آخر'}`
	                              : `من: ${movement.sender_name || 'عميل آخر'}`}
	                          </Text>
	                        )}
	                        {!(movement as any).is_internal_transfer &&
	                          !movement.mirror_movement_id &&
	                          movement.notes && (
	                            <Text
	                              style={styles.movementNotes}
	                              numberOfLines={1}
	                            >
	                              {movement.notes}
	                            </Text>
	                          )}
	                      </View>

	                      <View
	                        style={[
	                          styles.movementIcon,
	                          {
	                            backgroundColor: (movement as any)
	                              .is_internal_transfer
	                              ? '#FEF3C7'
	                              : movement.movement_type === 'outgoing'
	                                ? '#FEE2E2'
	                                : '#ECFDF5',
	                          },
	                        ]}
	                      >
	                        <Text
	                          style={[
	                            styles.currencySymbolText,
	                            {
	                              color: (movement as any).is_internal_transfer
	                                ? '#F59E0B'
	                                : movement.movement_type === 'outgoing'
	                                  ? '#EF4444'
	                                  : '#10B981',
	                            },
	                          ]}
	                        >
	                          {getCurrencySymbol(movement.currency)}
	                        </Text>
	                      </View>

	                      <View style={styles.movementAmount}>
	                        <Text
	                          style={[
	                            styles.movementAmountText,
	                            {
	                              color: (movement as any).is_internal_transfer
	                                ? '#F59E0B'
	                                : movement.movement_type === 'outgoing'
	                                  ? '#EF4444'
	                                  : '#10B981',
	                            },
	                          ]}
	                        >
	                          {Math.round(getCombinedAmount(movement, movements))}
	                        </Text>
	                        {getRelatedCommission(movement, movements) > 0 && (
	                          <Text style={styles.commissionBadge}>
	                            شامل {Math.round(getRelatedCommission(movement, movements))} عمولة
	                          </Text>
	                        )}
	                        <Text style={styles.movementLabel}>
	                          {(movement as any).is_internal_transfer
	                            ? 'تحويل'
	                            : movement.movement_type === 'outgoing'
	                              ? 'من العميل'
	                              : 'للعميل'}
	                        </Text>
	                      </View>
	                    </TouchableOpacity>
                      );
                    })}
	                </View>
	              ),
	            )
	          )}
        </View>
      </ScrollView>

      <TouchableOpacity style={styles.fab} onPress={handleAddMovement}>
        <Plus size={28} color="#FFFFFF" />
      </TouchableOpacity>

      {customer && (
        <QuickAddMovementSheet
          visible={showQuickAdd}
          onClose={() => setShowQuickAdd(false)}
          customerId={customer.id}
          customerName={customer.name}
          customerAccountNumber={customer.account_number}
          currentBalances={currencyBalances}
          requiresApproval={requiresCounterpartyApproval(customer.linked_user_id, currentUser?.userId)}
          onSuccess={() => {
            loadCustomerData();
          }}
        />
      )}

      <Modal
        visible={showSettingsMenu}
        transparent
        animationType="fade"
        onRequestClose={() => setShowSettingsMenu(false)}
      >
        <TouchableOpacity
          style={styles.modalOverlay}
          activeOpacity={1}
          onPress={() => setShowSettingsMenu(false)}
        >
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>إدارة العميل</Text>
            <Text style={styles.modalSubtitle}>{customer?.name}</Text>

            <TouchableOpacity
              style={styles.menuItem}
              onPress={() => {
                setShowSettingsMenu(false);
                router.push({
                  pathname: '/add-customer',
                  params: { id: customer.id },
                });
              }}
            >
              <Text style={styles.menuItemText}>تعديل البيانات</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={styles.menuItem}
              onPress={() => {
                setShowSettingsMenu(false);
                handleWhatsApp();
              }}
            >
              <Text style={styles.menuItemText}>إرسال واتساب</Text>
            </TouchableOpacity>


            <View style={styles.menuDivider} />

            <TouchableOpacity
              style={styles.menuItemDanger}
              onPress={() => {
                setShowSettingsMenu(false);
                handleResetAccount();
              }}
            >
              <Text style={styles.menuItemDangerText}>تصفير الحساب</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={styles.menuItemDanger}
              onPress={() => {
                setShowSettingsMenu(false);
                handleDeleteCustomer();
              }}
            >
              <Text style={styles.menuItemDangerText}>حذف العميل</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={styles.menuItemCancel}
              onPress={() => setShowSettingsMenu(false)}
            >
              <Text style={styles.menuItemCancelText}>إلغاء</Text>
            </TouchableOpacity>
          </View>
        </TouchableOpacity>
      </Modal>

      <CalendarRangePicker
        visible={showDateRangeModal}
        onClose={() => setShowDateRangeModal(false)}
        onConfirm={handleCalendarConfirm}
        onPrintAll={handlePrintAll}
        initialStartDate={startDate}
        initialEndDate={endDate}
        maxDate={new Date()}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F3F4F6',
  },
  gradientHeader: {
    paddingTop: 16,
    paddingBottom: 36,
  },
  headerContent: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 20,
    marginBottom: 16,
  },
  backButton: {
    width: 40,
    height: 40,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: 'rgba(255, 255, 255, 0.2)',
    borderRadius: 20,
    flexShrink: 0,
  },
  settingsButton: {
    width: 40,
    height: 40,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: 'rgba(255, 255, 255, 0.2)',
    borderRadius: 20,
    flexShrink: 0,
  },
  headerTitle: {
    flex: 1,
    fontSize: 24,
    fontWeight: 'bold',
    color: '#FFFFFF',
    textAlign: 'center',
    marginHorizontal: 8,
  },
  headerInfo: {
    paddingHorizontal: 20,
    flexDirection: 'row',
    gap: 12,
    flexWrap: 'wrap',
    justifyContent: 'flex-end',
  },
  headerBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: 'rgba(255, 255, 255, 0.25)',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 20,
  },
  headerBadgeText: {
    color: '#FFFFFF',
    fontSize: 13,
    fontWeight: '600',
  },
  linkedUserBadge: {
    backgroundColor: 'rgba(79, 70, 229, 0.5)',
  },
  pendingHeaderBadge: {
    backgroundColor: 'rgba(245, 158, 11, 0.45)',
  },
  content: {
    flex: 1,
  },
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {
    fontSize: 16,
    color: '#9CA3AF',
  },
  summarySection: {
    backgroundColor: '#FFFFFF',
    marginTop: 8,
    marginHorizontal: 20,
    marginBottom: 8,
    padding: 6,
    borderRadius: 18,
    shadowColor: '#0F172A',
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.05,
    shadowRadius: 14,
    elevation: 2,
  },
  summaryPanel: {
    backgroundColor: '#FCFCFD',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 10,
  },
  summarySectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    marginBottom: 10,
  },
  summarySectionIcon: {
    width: 22,
    height: 22,
    borderRadius: 7,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#EDE9FE',
  },
  summarySectionTitle: {
    fontSize: 14,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'center',
  },
  summaryCardsRow: {
    flexDirection: 'row',
    gap: 8,
  },
  summaryCard: {
    flex: 1,
    borderRadius: 14,
    paddingHorizontal: 8,
    paddingVertical: 8,
    borderWidth: 1,
    minHeight: 116,
  },
  summaryCardPositive: {
    backgroundColor: '#F7FEF9',
    borderColor: '#D8F5E3',
  },
  summaryCardNegative: {
    backgroundColor: '#FFF7F7',
    borderColor: '#F6D8D8',
  },
  summaryCardHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 6,
  },
  summaryCardHeaderSide: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  summaryCardToneDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  summaryCardToneDotPositive: {
    backgroundColor: '#22C55E',
  },
  summaryCardToneDotNegative: {
    backgroundColor: '#EF4444',
  },
  summaryCardHint: {
    fontSize: 10,
    fontWeight: '700',
    color: '#94A3B8',
    textAlign: 'right',
  },
  summaryCardTitle: {
    fontSize: 14,
    fontWeight: '800',
    textAlign: 'right',
  },
  summaryCardTitlePositive: {
    color: '#15803D',
  },
  summaryCardTitleNegative: {
    color: '#DC2626',
  },
  summaryCardRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 6,
    backgroundColor: '#FFFFFF',
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#E8EDF4',
    paddingHorizontal: 8,
    paddingVertical: 8,
    marginTop: 6,
  },
  summaryCardEmptyRow: {
    marginTop: 6,
    backgroundColor: 'rgba(255, 255, 255, 0.7)',
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#E8EDF4',
    paddingHorizontal: 8,
    paddingVertical: 10,
    alignItems: 'flex-end',
  },
  summaryCardAmount: {
    flex: 1,
    fontSize: 14,
    fontWeight: '800',
    lineHeight: 18,
    textAlign: 'right',
    flexShrink: 1,
  },
  summaryCardAmountPositive: {
    color: '#059669',
  },
  summaryCardAmountNegative: {
    color: '#DC2626',
  },
  summaryCardCurrencyChip: {
    minWidth: 38,
    height: 28,
    borderRadius: 14,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 8,
  },
  summaryCardCurrencyChipPositive: {
    backgroundColor: '#DCFCE7',
  },
  summaryCardCurrencyChipNegative: {
    backgroundColor: '#FEE2E2',
  },
  summaryCardCurrency: {
    fontSize: 9,
    fontWeight: '700',
    textAlign: 'center',
  },
  summaryCardCurrencyPositive: {
    color: '#15803D',
  },
  summaryCardCurrencyNegative: {
    color: '#DC2626',
  },
  summaryCardEmpty: {
    fontSize: 11,
    fontWeight: '600',
    color: '#94A3B8',
    textAlign: 'right',
  },
  currencyDetailsSection: {
    backgroundColor: '#FFFFFF',
    marginTop: 8,
    paddingVertical: 12,
  },
  currencyDetailsToggle: {
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  currencyDetailsToggleContent: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
  },
  currencyDetailsToggleText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#374151',
    marginLeft: 8,
  },
  currencyDetailsContent: {
    paddingHorizontal: 20,
    paddingTop: 12,
  },
  currencyDetailsCard: {
    marginBottom: 8,
  },
  currencyDetailsName: {
    fontSize: 12,
    fontWeight: '400',
    color: '#6B7280',
    marginBottom: 4,
    textAlign: 'right',
  },
  currencyDetailsRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 2,
  },
  currencyDetailsLabelGreen: {
    fontSize: 12,
    color: '#10B981',
    textAlign: 'right',
  },
  currencyDetailsLabelRed: {
    fontSize: 12,
    color: '#EF4444',
    textAlign: 'right',
  },
  currencyDetailsValueGreen: {
    fontSize: 12,
    fontWeight: '400',
    color: '#10B981',
    textAlign: 'right',
  },
  currencyDetailsValueRed: {
    fontSize: 12,
    fontWeight: '400',
    color: '#EF4444',
    textAlign: 'right',
  },
  tabButtons: {
    flexDirection: 'row',
    paddingHorizontal: 16,
    paddingVertical: 16,
    gap: 10,
    backgroundColor: '#FFFFFF',
    flexWrap: 'wrap',
  },
  tabButtonPrimary: {
    backgroundColor: '#F97316',
    paddingHorizontal: 18,
    paddingVertical: 10,
    borderRadius: 22,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    minWidth: 140,
  },
  tabButtonPrimaryText: {
    color: '#FFFFFF',
    fontSize: 14,
    fontWeight: '700',
  },
  tabButton: {
    backgroundColor: '#F3F4F6',
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderRadius: 22,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    flex: 1,
    minWidth: 100,
  },
  tabButtonDisabled: {
    opacity: 0.5,
  },
  tabButtonText: {
    color: '#374151',
    fontSize: 13,
    fontWeight: '600',
  },
  movementsSection: {
    backgroundColor: '#FFFFFF',
    marginTop: 8,
    paddingBottom: 100,
  },
  monthHeader: {
    fontSize: 14,
    fontWeight: 'bold',
    color: '#111827',
    paddingHorizontal: 16,
    paddingVertical: 12,
    backgroundColor: '#F9FAFB',
    textAlign: 'right',
  },
  movementColumnsHeader: {
    flexDirection: I18nManager.isRTL ? 'row-reverse' : 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 12,
    paddingVertical: 8,
    backgroundColor: '#FFFFFF',
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  movementColumnLabel: {
    fontSize: 10,
    fontWeight: '700',
    color: '#6B7280',
    textAlign: 'center',
  },
  movementDateHeader: {
    width: 44,
    alignItems: 'center',
  },
  movementTypeHeader: {
    width: 80,
    alignItems: 'center',
  },
  movementCreatorHeader: {
    width: 66,
    alignItems: 'center',
  },
  movementCurrencyHeader: {
    width: 34,
    alignItems: 'center',
  },
  movementAmountHeader: {
    width: 62,
    alignItems: 'center',
  },
  movementRow: {
    flexDirection: I18nManager.isRTL ? 'row-reverse' : 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 12,
    paddingHorizontal: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  movementRowPending: {
    backgroundColor: '#FFFBEB',
    borderLeftWidth: 3,
    borderLeftColor: '#F59E0B',
  },
  movementRowRejected: {
    backgroundColor: '#FEF2F2',
    borderLeftWidth: 3,
    borderLeftColor: '#EF4444',
  },
  movementDate: {
    alignItems: 'center',
    width: 44,
  },
  movementDateMonth: {
    fontSize: 11,
    color: '#9CA3AF',
    textTransform: 'uppercase',
    textAlign: 'center',
  },
  movementDateDay: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#374151',
    textAlign: 'center',
  },
  movementIcon: {
    width: 34,
    height: 34,
    borderRadius: 17,
    justifyContent: 'center',
    alignItems: 'center',
  },
  currencySymbolText: {
    fontSize: 16,
    fontWeight: 'bold',
    textAlign: 'center',
  },
  movementTypeContainer: {
    justifyContent: 'center',
    width: 80,
    alignItems: 'center',
  },
  movementType: {
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 2,
    textAlign: 'center',
  },
  movementCreatorContainer: {
    width: 66,
    justifyContent: 'center',
    alignItems: 'center',
  },
  movementCreatorValue: {
    fontSize: 11,
    fontWeight: '600',
    color: '#374151',
    textAlign: 'center',
  },
  movementCreatorValueCurrent: {
    color: '#2563EB',
  },
  movementStatusBadge: {
    borderRadius: 8,
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderWidth: 1,
    marginTop: 4,
    alignItems: 'center',
  },
  movementStatusBadgePending: {
    backgroundColor: '#FEF3C7',
    borderColor: '#F59E0B',
  },
  movementStatusBadgeRejected: {
    backgroundColor: '#FEE2E2',
    borderColor: '#EF4444',
  },
  movementStatusBadgeApproved: {
    backgroundColor: '#DCFCE7',
    borderColor: '#22C55E',
  },
  movementStatusText: {
    fontSize: 9,
    fontWeight: '600',
    textAlign: 'center',
  },
  movementStatusTextPending: {
    color: '#F59E0B',
  },
  movementStatusTextRejected: {
    color: '#B91C1C',
  },
  movementStatusTextApproved: {
    color: '#15803D',
  },
  movementNotes: {
    fontSize: 11,
    color: '#9CA3AF',
    textAlign: 'center',
  },
  movementAmount: {
    alignItems: 'center',
    width: 62,
  },
  movementAmountText: {
    fontSize: 15,
    fontWeight: 'bold',
    marginBottom: 2,
    textAlign: 'center',
  },
  movementLabel: {
    fontSize: 10,
    color: '#9CA3AF',
    textAlign: 'center',
  },
  commissionBadge: {
    fontSize: 9,
    color: '#9CA3AF',
    marginTop: 2,
    textAlign: 'center',
  },
  emptyContainer: {
    padding: 32,
    alignItems: 'center',
  },
  emptyText: {
    fontSize: 14,
    color: '#9CA3AF',
  },
  fab: {
    position: 'absolute',
    bottom: 24,
    left: 24,
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: '#10B981',
    justifyContent: 'center',
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 8,
    elevation: 8,
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    justifyContent: 'flex-end',
  },
  modalContent: {
    backgroundColor: '#FFFFFF',
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    paddingTop: 24,
    paddingBottom: 32,
    paddingHorizontal: 20,
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
    textAlign: 'center',
    marginBottom: 8,
  },
  modalSubtitle: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'center',
    marginBottom: 20,
  },
  menuItem: {
    paddingVertical: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  menuItemText: {
    fontSize: 16,
    color: '#374151',
    textAlign: 'right',
  },
  menuItemDanger: {
    paddingVertical: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  menuItemDangerText: {
    fontSize: 16,
    color: '#EF4444',
    textAlign: 'right',
    fontWeight: '600',
  },
  menuItemCancel: {
    paddingVertical: 16,
    marginTop: 8,
  },
  menuItemCancelText: {
    fontSize: 16,
    color: '#6B7280',
    textAlign: 'center',
    fontWeight: '600',
  },
  menuDivider: {
    height: 8,
    backgroundColor: '#F9FAFB',
    marginVertical: 8,
    marginHorizontal: -20,
  },
  searchSection: {
    backgroundColor: '#FFFFFF',
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 8,
  },
  searchContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#F9FAFB',
    borderRadius: 12,
    paddingHorizontal: 12,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  searchIcon: {
    marginLeft: 8,
  },
  searchInput: {
    flex: 1,
    height: 44,
    fontSize: 14,
    color: '#111827',
  },
  clearButton: {
    padding: 4,
  },
  searchResultText: {
    fontSize: 12,
    color: '#6B7280',
    marginTop: 8,
    textAlign: 'right',
  },
  dateRangeModalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    justifyContent: 'flex-end',
  },
  dateRangeModalContent: {
    backgroundColor: '#FFFFFF',
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    maxHeight: '90%',
  },
  dateRangeHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 20,
    paddingTop: 20,
    paddingBottom: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  dateRangeTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
    textAlign: 'center',
  },
  dateRangeCloseButton: {
    width: 40,
    height: 40,
    justifyContent: 'center',
    alignItems: 'center',
  },
  dateRangeScroll: {
    maxHeight: 500,
  },
  quickOptionsSection: {
    padding: 20,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: '600',
    color: '#374151',
    marginBottom: 12,
    textAlign: 'right',
  },
  quickOptionsGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 12,
    justifyContent: 'space-between',
  },
  quickOptionButton: {
    backgroundColor: '#ECFDF5',
    paddingVertical: 12,
    paddingHorizontal: 16,
    borderRadius: 12,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    flex: 1,
    minWidth: '45%',
    justifyContent: 'center',
    borderWidth: 1,
    borderColor: '#D1FAE5',
  },
  quickOptionText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#059669',
  },
  customDateSection: {
    padding: 20,
  },
  dateFormatHint: {
    fontSize: 12,
    color: '#9CA3AF',
    marginBottom: 16,
    textAlign: 'right',
  },
  dateInputContainer: {
    marginBottom: 16,
  },
  dateInputLabel: {
    fontSize: 14,
    fontWeight: '600',
    color: '#374151',
    marginBottom: 8,
    textAlign: 'right',
  },
  dateInput: {
    backgroundColor: '#F9FAFB',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 12,
    fontSize: 16,
    color: '#111827',
    textAlign: 'right',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  dateInputText: {
    fontSize: 16,
    color: '#111827',
    flex: 1,
  },
  applyCustomDateButton: {
    backgroundColor: '#10B981',
    paddingVertical: 12,
    borderRadius: 12,
    alignItems: 'center',
    marginTop: 8,
  },
  applyCustomDateButtonText: {
    color: '#FFFFFF',
    fontSize: 15,
    fontWeight: '600',
  },
  selectedRangePreview: {
    margin: 20,
    marginTop: 0,
    padding: 16,
    backgroundColor: '#F0F9FF',
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#BAE6FD',
  },
  selectedRangeTitle: {
    fontSize: 14,
    fontWeight: '600',
    color: '#0369A1',
    marginBottom: 8,
    textAlign: 'right',
  },
  selectedRangeText: {
    fontSize: 13,
    color: '#075985',
    marginBottom: 4,
    textAlign: 'right',
  },
  movementsCountText: {
    fontSize: 13,
    fontWeight: '600',
    color: '#0369A1',
    marginTop: 8,
    textAlign: 'right',
  },
  dateRangeActions: {
    padding: 20,
    paddingTop: 16,
    gap: 12,
    borderTopWidth: 1,
    borderTopColor: '#F3F4F6',
  },
  printAllButton: {
    backgroundColor: '#10B981',
    paddingVertical: 14,
    paddingHorizontal: 20,
    borderRadius: 12,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },
  printAllButtonText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '600',
  },
  printRangeButton: {
    backgroundColor: '#3B82F6',
    paddingVertical: 14,
    paddingHorizontal: 20,
    borderRadius: 12,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },
  printRangeButtonDisabled: {
    backgroundColor: '#9CA3AF',
    opacity: 0.5,
  },
  printRangeButtonText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '600',
  },
  linkedAccountInfo: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginTop: 12,
    paddingTop: 12,
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
  },
  linkedAccountInfoText: {
    fontSize: 14,
    color: '#6366F1',
    fontWeight: '600',
    flex: 1,
    textAlign: 'right',
  },
  notificationSummaryCard: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
    marginTop: 16,
    backgroundColor: '#FFFBEB',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#FCD34D',
    paddingVertical: 14,
    paddingHorizontal: 16,
  },
  notificationSummaryContent: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  notificationSummaryTextWrap: {
    flex: 1,
  },
  notificationSummaryTitle: {
    fontSize: 16,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'right',
    marginBottom: 4,
  },
  notificationSummarySubtitle: {
    fontSize: 13,
    fontWeight: '600',
    color: '#B45309',
    textAlign: 'right',
  },
  notificationSummaryIcon: {
    width: 38,
    height: 38,
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#FEF3C7',
  },
  notificationSummaryCountBadge: {
    minWidth: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: '#B45309',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 10,
  },
  notificationSummaryCountText: {
    fontSize: 16,
    fontWeight: '800',
    color: '#FFFFFF',
  },
  pendingSection: {
    marginTop: 16,
    backgroundColor: '#FFFFFF',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#FCD34D',
    padding: 14,
  },
  pendingSectionHeader: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: 12,
    marginBottom: 12,
  },
  pendingSectionTitleWrap: {
    flex: 1,
  },
  pendingSectionTitle: {
    fontSize: 16,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'right',
    marginBottom: 4,
  },
  pendingSectionSubtitle: {
    fontSize: 12,
    color: '#6B7280',
    textAlign: 'right',
    lineHeight: 20,
  },
  pendingSectionButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: '#FFFBEB',
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#FCD34D',
    paddingVertical: 8,
    paddingHorizontal: 10,
  },
  pendingSectionButtonText: {
    fontSize: 12,
    fontWeight: '700',
    color: '#B45309',
  },
  pendingMovementCard: {
    backgroundColor: '#FFFBEB',
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#FDE68A',
    padding: 12,
    marginBottom: 10,
  },
  pendingMovementTop: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 10,
    marginBottom: 10,
  },
  pendingMovementStatusBadge: {
    backgroundColor: '#FEF3C7',
    borderRadius: 999,
    borderWidth: 1,
    borderColor: '#F59E0B',
    paddingVertical: 4,
    paddingHorizontal: 10,
  },
  pendingMovementStatusText: {
    fontSize: 11,
    fontWeight: '800',
    color: '#B45309',
  },
  pendingMovementNumber: {
    fontSize: 12,
    color: '#6B7280',
    fontWeight: '700',
  },
  pendingMovementRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 8,
  },
  pendingMovementAmount: {
    fontSize: 18,
    fontWeight: '800',
  },
  pendingMovementDirection: {
    fontSize: 13,
    fontWeight: '800',
  },
  pendingMovementAmountGreen: {
    color: '#10B981',
  },
  pendingMovementAmountRed: {
    color: '#EF4444',
  },
  pendingMovementHint: {
    fontSize: 12,
    color: '#92400E',
    textAlign: 'right',
    lineHeight: 20,
    marginBottom: 8,
    fontWeight: '600',
  },
  pendingMovementDate: {
    fontSize: 11,
    color: '#9CA3AF',
    textAlign: 'right',
  },
  pendingMoreText: {
    marginTop: 4,
    fontSize: 12,
    color: '#6B7280',
    textAlign: 'right',
  },
});

