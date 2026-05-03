import Constants from 'expo-constants';
import { Alert, Linking } from 'react-native';
import { supabase } from '@/lib/supabase';

type CurrentUserInfo = {
  userId?: string | null;
  userName?: string | null;
  fullName?: string | null;
  accountNumber?: string | null;
};

type QuotaInfo = {
  customerCount?: number | null;
  customerLimit?: number | null;
  customer_count?: number | null;
  customer_limit?: number | null;
  message?: string | null;
};

const FALLBACK_ADMIN_WHATSAPP_NUMBER = '905352973229';

const ADMIN_WHATSAPP_NUMBER =
  process.env.EXPO_PUBLIC_ADMIN_WHATSAPP_NUMBER ||
  (Constants.expoConfig?.extra as any)?.EXPO_PUBLIC_ADMIN_WHATSAPP_NUMBER ||
  FALLBACK_ADMIN_WHATSAPP_NUMBER;

const normalizePhoneNumber = (value?: string | null) => {
  const cleaned = String(value || '').replace(/[^0-9]/g, '');
  if (!cleaned || cleaned === '000000000000' || cleaned === '905000000000') {
    return '';
  }
  return cleaned;
};

const formatPhoneForDisplay = (value?: string | null) => {
  const cleaned = normalizePhoneNumber(value);
  return cleaned ? `+${cleaned}` : 'لم يتم ضبط رقم مسؤول الاشتراكات بعد';
};

export const getAdminSubscriptionWhatsAppNumber = () => normalizePhoneNumber(ADMIN_WHATSAPP_NUMBER);

export const getAdminSubscriptionWhatsAppDisplayNumber = () =>
  formatPhoneForDisplay(ADMIN_WHATSAPP_NUMBER);

export const isCustomerLimitReachedMessage = (message?: string | null) => {
  const normalized = String(message || '').toLowerCase();
  const compactArabic = String(message || '').replace(/\s+/g, ' ');

  return (
    normalized.includes('customer_limit_reached') ||
    normalized.includes('customer quota') ||
    normalized.includes('quota') ||
    normalized.includes('limit') ||
    normalized.includes('subscription limit') ||
    compactArabic.includes('الحد المسموح') ||
    compactArabic.includes('الحد الأقصى') ||
    compactArabic.includes('الحد الاقصى') ||
    compactArabic.includes('بلغت الحد') ||
    compactArabic.includes('وصل المستخدم إلى الحد') ||
    compactArabic.includes('وصلت إلى الحد') ||
    compactArabic.includes('تفعيل الاشتراك') ||
    (compactArabic.includes('الحد') && compactArabic.includes('الاشتراك')) ||
    (compactArabic.includes('الحد') && compactArabic.includes('العملاء')) ||
    (compactArabic.includes('الحد') && compactArabic.includes('المستخدمين'))
  );
};

const normalizeQuota = (quota?: QuotaInfo | null) => {
  const customerCount = quota?.customerCount ?? quota?.customer_count ?? null;
  const customerLimit = quota?.customerLimit ?? quota?.customer_limit ?? null;
  return { customerCount, customerLimit };
};

const buildUpgradeMessage = (
  currentUser?: CurrentUserInfo | null,
  quota?: QuotaInfo | null
) => {
  const { customerCount, customerLimit } = normalizeQuota(quota);

  const lines = [
    'السلام عليكم،',
    '',
    'أرغب في طلب تفعيل/تجديد الاشتراك لحسابي في تطبيق ArtiCode.',
    'وصلت إلى الحد المسموح في باقتي الحالية، وأرغب في تفعيل الاشتراك لإضافة المزيد من العملاء/المستخدمين والاستفادة من الصلاحيات الكاملة.',
    '',
    'بيانات الحساب:',
    `الاسم: ${currentUser?.fullName || 'غير متوفر'}`,
    `اسم المستخدم: ${currentUser?.userName || 'غير متوفر'}`,
    `رقم الحساب: ${currentUser?.accountNumber || 'غير متوفر'}`,
    `معرف المستخدم: ${currentUser?.userId || 'غير متوفر'}`,
  ];

  if (typeof customerCount === 'number' || typeof customerLimit === 'number') {
    lines.push(
      `الاستخدام الحالي: ${customerCount ?? 'غير معروف'} من ${customerLimit ?? 'غير معروف'} عميل/مستخدم`
    );
  }

  lines.push(
    '',
    'يرجى إفادتي بطريقة الدفع، ثم تفعيل الاشتراك من لوحة الإدارة بعد إتمام العملية. شكرًا لكم.'
  );

  return lines.join('\n');
};

const recordSubscriptionUpgradeRequest = async (
  currentUser?: CurrentUserInfo | null,
  quota?: QuotaInfo | null,
  message?: string
) => {
  try {
    const { customerCount, customerLimit } = normalizeQuota(quota);
    await supabase.rpc('app_create_subscription_request', {
      p_user_id: currentUser?.userId || null,
      p_user_name: currentUser?.userName || null,
      p_full_name: currentUser?.fullName || null,
      p_account_number: currentUser?.accountNumber || null,
      p_customer_count: typeof customerCount === 'number' ? customerCount : null,
      p_customer_limit: typeof customerLimit === 'number' ? customerLimit : null,
      p_whatsapp_number: getAdminSubscriptionWhatsAppNumber(),
      p_message: message || null,
    });
  } catch (error) {
    // لا نمنع فتح واتساب إذا لم يتم تطبيق ملف SQL بعد.
    console.warn('[subscription-request] Failed to record request:', error);
  }
};

export const openSubscriptionUpgradeWhatsApp = async (
  currentUser?: CurrentUserInfo | null,
  quota?: QuotaInfo | null
) => {
  const adminPhone = getAdminSubscriptionWhatsAppNumber();
  const message = buildUpgradeMessage(currentUser, quota);
  await recordSubscriptionUpgradeRequest(currentUser, quota, message);
  const encodedMessage = encodeURIComponent(message);
  const appUrl = adminPhone
    ? `whatsapp://send?phone=${adminPhone}&text=${encodedMessage}`
    : `whatsapp://send?text=${encodedMessage}`;
  const webUrl = adminPhone
    ? `https://wa.me/${adminPhone}?text=${encodedMessage}`
    : `https://api.whatsapp.com/send?text=${encodedMessage}`;

  try {
    await Linking.openURL(appUrl);
  } catch (error) {
    try {
      await Linking.openURL(webUrl);
    } catch (fallbackError) {
      Alert.alert(
        'تعذر فتح واتساب',
        'لم نتمكن من فتح واتساب تلقائيًا. تأكد من تثبيت واتساب أو اضبط رقم واتساب مسؤول الاشتراكات داخل app.json.'
      );
    }
  }
};

export const showCustomerLimitReachedAlert = (
  currentUser?: CurrentUserInfo | null,
  quota?: QuotaInfo | null
) => {
  const { customerCount, customerLimit } = normalizeQuota(quota);
  const adminPhoneDisplay = formatPhoneForDisplay(ADMIN_WHATSAPP_NUMBER);

  const limitText =
    typeof customerLimit === 'number' && customerLimit > 0
      ? `لقد وصلت إلى الحد المسموح في باقتك الحالية. الحد الحالي هو ${customerLimit} عميل/مستخدم${typeof customerCount === 'number' ? `، والاستخدام الحالي ${customerCount}` : ''}.`
      : 'لقد وصلت إلى الحد المسموح من العملاء/المستخدمين في باقتك الحالية.';

  Alert.alert(
    'تفعيل الاشتراك مطلوب',
    `${limitText}\n\nلإضافة المزيد والاستفادة من كامل الصلاحيات، أرسل طلب تفعيل إلى مسؤول الاشتراكات عبر واتساب.\nرقم مسؤول الاشتراكات: ${adminPhoneDisplay}`,
    [
      {
        text: 'لاحقًا',
        style: 'cancel',
      },
      {
        text: 'طلب التفعيل عبر واتساب',
        onPress: () => openSubscriptionUpgradeWhatsApp(currentUser, quota),
      },
    ]
  );
};
