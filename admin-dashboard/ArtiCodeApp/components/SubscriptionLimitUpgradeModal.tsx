import { Modal, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { Crown, MessageCircle, ShieldCheck, X } from 'lucide-react-native';
import {
  getAdminSubscriptionWhatsAppDisplayNumber,
  openSubscriptionUpgradeWhatsApp,
} from '@/utils/subscriptionUpgradeRequest';

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

type Props = {
  visible: boolean;
  currentUser?: CurrentUserInfo | null;
  quota?: QuotaInfo | null;
  onClose: () => void;
};

const normalizeQuota = (quota?: QuotaInfo | null) => {
  const customerCount = quota?.customerCount ?? quota?.customer_count ?? null;
  const customerLimit = quota?.customerLimit ?? quota?.customer_limit ?? null;
  return { customerCount, customerLimit };
};

export function SubscriptionLimitUpgradeModal({
  visible,
  currentUser,
  quota,
  onClose,
}: Props) {
  const { customerCount, customerLimit } = normalizeQuota(quota);
  const adminPhoneDisplay = getAdminSubscriptionWhatsAppDisplayNumber();
  const hasQuotaNumbers = typeof customerCount === 'number' || typeof customerLimit === 'number';

  const handleUpgrade = async () => {
    await openSubscriptionUpgradeWhatsApp(currentUser, quota);
    onClose();
  };

  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose}>
      <View style={styles.overlay}>
        <View style={styles.card}>
          <View style={styles.topRow}>
            <TouchableOpacity style={styles.closeButton} onPress={onClose} activeOpacity={0.75}>
              <X size={18} color="#64748B" />
            </TouchableOpacity>
            <View style={styles.iconCircle}>
              <Crown size={28} color="#FFFFFF" />
            </View>
            <View style={styles.closePlaceholder} />
          </View>

          <Text style={styles.title}>فعّل اشتراكك للاستمرار</Text>
          <Text style={styles.subtitle}>
            شكرًا لاستخدامك التطبيق. لقد وصلت إلى الحد المسموح به في باقتك الحالية.
          </Text>

          {hasQuotaNumbers ? (
            <View style={styles.quotaBox}>
              <ShieldCheck size={18} color="#4338CA" />
              <Text style={styles.quotaText}>
                الاستخدام الحالي: {customerCount ?? 'غير معروف'} من {customerLimit ?? 'غير محدد'} عميل/مستخدم
              </Text>
            </View>
          ) : null}

          <Text style={styles.description}>
            لإضافة المزيد من العملاء أو المستخدمين والاستفادة من كامل الصلاحيات، يمكنك إرسال طلب تفعيل الاشتراك إلى مسؤول الاشتراكات عبر واتساب، وسيتم مراجعة الطلب وتفعيله من لوحة الإدارة بعد إتمام الدفع.
          </Text>

          <View style={styles.phoneBox}>
            <Text style={styles.phoneLabel}>رقم مسؤول الاشتراكات</Text>
            <Text style={styles.phoneValue}>{adminPhoneDisplay}</Text>
          </View>

          <TouchableOpacity
            style={styles.primaryButton}
            onPress={handleUpgrade}
            activeOpacity={0.9}
          >
            <MessageCircle size={20} color="#FFFFFF" />
            <Text style={styles.primaryButtonText}>طلب تفعيل الاشتراك عبر واتساب</Text>
          </TouchableOpacity>

          <TouchableOpacity style={styles.laterButton} onPress={onClose} activeOpacity={0.75}>
            <Text style={styles.laterButtonText}>لاحقًا</Text>
          </TouchableOpacity>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    backgroundColor: 'rgba(15, 23, 42, 0.58)',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 20,
  },
  card: {
    width: '100%',
    maxWidth: 390,
    backgroundColor: '#FFFFFF',
    borderRadius: 28,
    paddingHorizontal: 22,
    paddingTop: 20,
    paddingBottom: 18,
    shadowColor: '#0F172A',
    shadowOffset: { width: 0, height: 18 },
    shadowOpacity: 0.2,
    shadowRadius: 28,
    elevation: 18,
  },
  topRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  closeButton: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: '#F1F5F9',
    alignItems: 'center',
    justifyContent: 'center',
  },
  closePlaceholder: {
    width: 36,
    height: 36,
  },
  iconCircle: {
    width: 68,
    height: 68,
    borderRadius: 34,
    backgroundColor: '#4F46E5',
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 5,
    borderColor: '#EEF2FF',
  },
  title: {
    marginTop: 16,
    fontSize: 21,
    fontWeight: '900',
    color: '#111827',
    textAlign: 'center',
    lineHeight: 30,
  },
  subtitle: {
    marginTop: 10,
    fontSize: 14.5,
    color: '#475569',
    textAlign: 'center',
    lineHeight: 23,
  },
  quotaBox: {
    marginTop: 14,
    borderRadius: 18,
    backgroundColor: '#EEF2FF',
    borderWidth: 1,
    borderColor: '#C7D2FE',
    paddingVertical: 12,
    paddingHorizontal: 14,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },
  quotaText: {
    flex: 1,
    fontSize: 13.5,
    fontWeight: '800',
    color: '#312E81',
    textAlign: 'right',
    lineHeight: 21,
  },
  description: {
    marginTop: 14,
    fontSize: 14,
    color: '#64748B',
    textAlign: 'center',
    lineHeight: 23,
  },
  phoneBox: {
    marginTop: 14,
    borderRadius: 18,
    paddingVertical: 12,
    paddingHorizontal: 14,
    backgroundColor: '#F8FAFC',
    borderWidth: 1,
    borderColor: '#E2E8F0',
    alignItems: 'center',
  },
  phoneLabel: {
    fontSize: 12,
    fontWeight: '700',
    color: '#64748B',
  },
  phoneValue: {
    marginTop: 4,
    fontSize: 17,
    fontWeight: '900',
    color: '#0F172A',
    letterSpacing: 0.4,
  },
  primaryButton: {
    marginTop: 16,
    minHeight: 54,
    borderRadius: 18,
    backgroundColor: '#16A34A',
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 10,
    paddingHorizontal: 16,
  },
  primaryButtonText: {
    fontSize: 15.5,
    fontWeight: '900',
    color: '#FFFFFF',
  },
  laterButton: {
    marginTop: 10,
    minHeight: 42,
    alignItems: 'center',
    justifyContent: 'center',
  },
  laterButtonText: {
    fontSize: 14,
    fontWeight: '800',
    color: '#64748B',
  },
});
