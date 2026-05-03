import Constants from 'expo-constants';
import { Alert, Linking } from 'react-native';

type SubscriptionPlanChoice = 'monthly' | 'yearly';

type CurrentUserInfo = {
  userId?: string | null;
  userName?: string | null;
  fullName?: string | null;
  accountNumber?: string | null;
};

type QuotaInfo = {
  customerCount?: number | null;
  customerLimit?: number | null;
};

const ADMIN_WHATSAPP_NUMBER =
  process.env.EXPO_PUBLIC_ADMIN_WHATSAPP_NUMBER ||
  (Constants.expoConfig?.extra as any)?.EXPO_PUBLIC_ADMIN_WHATSAPP_NUMBER ||
  '';

const normalizePhoneNumber = (value?: string | null) => {
  const cleaned = String(value || '').replace(/[^0-9]/g, '');
  if (!cleaned || cleaned === '000000000000' || cleaned === '905000000000') {
    return '';
  }
  return cleaned;
};

export const isCustomerLimitReachedMessage = (message?: string | null) => {
  const normalized = String(message || '').toLowerCase();
  return (
    normalized.includes('customer_limit_reached') ||
    normalized.includes('quota') ||
    normalized.includes('limit') ||
    (normalized.includes('الحد') && normalized.includes('العملاء')) ||
    normalized.includes('الحد المسموح') ||
    normalized.includes('الحد الأقصى')
  );
};

const getPlanLabel = (plan: SubscriptionPlanChoice) => {
  return plan === 'yearly' ? 'الاشتراك السنوي' : 'الاشتراك الشهري';
};

const buildUpgradeMessage = (
  plan: SubscriptionPlanChoice,
  currentUser?: CurrentUserInfo | null,
  quota?: QuotaInfo
) => {
  const lines = [
    'السلام عليكم،',
    '',
    `أرغب في تفعيل ${getPlanLabel(plan)} لفتح إمكانية إضافة عملاء/مستخدمين إضافيين في التطبيق.`,
    '',
    'بيانات الحساب:',
    `الاسم: ${currentUser?.fullName || 'غير متوفر'}`,
    `اسم المستخدم: ${currentUser?.userName || 'غير متوفر'}`,
    `رقم الحساب: ${currentUser?.accountNumber || 'غير متوفر'}`,
    `معرف المستخدم: ${currentUser?.userId || 'غير متوفر'}`,
  ];

  if (typeof quota?.customerCount === 'number' || typeof quota?.customerLimit === 'number') {
    lines.push(
      `الاستخدام الحالي: ${quota?.customerCount ?? 'غير معروف'} من ${quota?.customerLimit ?? 'غير معروف'} عميل/مستخدم`
    );
  }

  lines.push('', 'الرجاء تفعيل الاشتراك المناسب وإرسال طريقة الدفع.');

  return lines.join('\n');
};

export const openSubscriptionUpgradeWhatsApp = async (
  plan: SubscriptionPlanChoice,
  currentUser?: CurrentUserInfo | null,
  quota?: QuotaInfo
) => {
  const adminPhone = normalizePhoneNumber(ADMIN_WHATSAPP_NUMBER);
  const message = buildUpgradeMessage(plan, currentUser, quota);
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
        'لم نتمكن من فتح واتساب تلقائيًا. تأكد من تثبيت واتساب أو اضبط رقم واتساب الأدمن داخل إعدادات التطبيق.'
      );
    }
  }
};

export const showCustomerLimitReachedAlert = (
  currentUser?: CurrentUserInfo | null,
  quota?: QuotaInfo
) => {
  const limitText =
    typeof quota?.customerLimit === 'number' && quota.customerLimit > 0
      ? `الحد الحالي المسموح لك هو ${quota.customerLimit} عميل/مستخدم.`
      : 'لقد بلغت الحد الأقصى المسموح لك من العملاء/المستخدمين.';

  Alert.alert(
    'تم الوصول إلى الحد الأقصى',
    `${limitText}\n\nلتتمكن من إضافة المزيد، اختر نوع الاشتراك وسيتم تجهيز رسالة واتساب تلقائيًا للأدمن لطلب التفعيل والدفع.`,
    [
      {
        text: 'لاحقًا',
        style: 'cancel',
      },
      {
        text: 'اشتراك شهري',
        onPress: () => openSubscriptionUpgradeWhatsApp('monthly', currentUser, quota),
      },
      {
        text: 'اشتراك سنوي',
        onPress: () => openSubscriptionUpgradeWhatsApp('yearly', currentUser, quota),
      },
    ]
  );
};
