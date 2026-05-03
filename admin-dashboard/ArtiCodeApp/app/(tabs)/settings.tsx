import { useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ScrollView,
  Alert,
} from 'react-native';
import { useRouter } from 'expo-router';
import {
  LogOut,
  Lock,
  Database,
  Info,
  ChevronLeft,
  Building2,
  MessageCircle,
  Link as LinkIcon,
} from 'lucide-react-native';
import { useAuth } from '@/contexts/AuthContext';

export default function SettingsScreen() {
  const router = useRouter();
  const { logout, settings, refreshSettings, currentUser } = useAuth();

  useEffect(() => {
    if (!settings) {
      refreshSettings();
    }
  }, [settings, refreshSettings]);

  const handleLogout = () => {
    Alert.alert('تسجيل الخروج', 'هل أنت متأكد من تسجيل الخروج؟', [
      { text: 'إلغاء', style: 'cancel' },
      {
        text: 'خروج',
        style: 'destructive',
        onPress: async () => {
          await logout();
          router.replace('/(auth)/login' as any);
        },
      },
    ]);
  };

  const menuItems = [
    {
      icon: Building2,
      title: 'إعدادات المحل',
      subtitle: 'اسم المحل والهاتف والعنوان والترويسة والطباعة',
      color: '#4F46E5',
      onPress: () => router.push('/shop-settings' as any),
    },
    {
      icon: LinkIcon,
      title: 'الحسابات المتبادلة',
      subtitle: 'المستخدمون المربوطون بك كعملاء',
      color: '#3B82F6',
      onPress: () => router.push('/linked-accounts' as any),
    },
    {
      icon: MessageCircle,
      title: 'قوالب رسائل الواتساب',
      subtitle: 'تخصيص قوالب الرسائل المرسلة',
      color: '#25D366',
      onPress: () => router.push('/whatsapp-templates' as any),
    },
    {
      icon: Lock,
      title: 'إدارة رمز PIN',
      subtitle: 'تعيين أو تغيير رمز الأمان',
      color: '#EF4444',
      onPress: () => router.push('/pin-settings' as any),
    },
    {
      icon: Database,
      title: 'النسخ الاحتياطي',
      subtitle: 'نسخ واستعادة البيانات',
      color: '#10B981',
      onPress: () => router.push('/backup' as any),
    },
    {
      icon: Info,
      title: 'حول التطبيق',
      subtitle: 'الإصدار والمعلومات',
      color: '#6B7280',
      onPress: () =>
        Alert.alert(
          'ArtiCode',
          'الإصدار 1.0.0\n\nتطبيق ArtiCode لإدارة الحوالات المالية والعملاء'
        ),
    },
  ];

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerTitle}>الإعدادات</Text>
      </View>

      <ScrollView style={styles.content} contentContainerStyle={styles.contentContainer}>
        <View style={styles.profileCard}>
          <Text style={styles.profileName}>
            {currentUser?.fullName || 'المستخدم'}
          </Text>
          {currentUser?.accountNumber ? (
            <Text style={styles.profilePhone}>
              رقم الحساب: {currentUser.accountNumber}
            </Text>
          ) : null}
        </View>

        <View style={styles.menuSection}>
          {menuItems.map((item, index) => {
            const IconComponent = item.icon as any;

            return (
              <TouchableOpacity
                key={item.title}
                style={[
                  styles.menuItem,
                  index === menuItems.length - 1 && styles.lastMenuItem,
                ]}
                onPress={item.onPress}
                activeOpacity={0.85}
              >
                <ChevronLeft size={20} color="#9CA3AF" />
                <View style={styles.menuItemContent}>
                  <View style={[styles.menuIcon, { backgroundColor: item.color + '15' }]}>
                    <IconComponent size={22} color={item.color} />
                  </View>

                  <View style={styles.menuTextContainer}>
                    <Text style={styles.menuTitle}>{item.title}</Text>
                    <Text style={styles.menuSubtitle}>{item.subtitle}</Text>
                  </View>
                </View>
              </TouchableOpacity>
            );
          })}
        </View>

        <TouchableOpacity style={styles.logoutButton} onPress={handleLogout}>
          <LogOut size={20} color="#EF4444" />
          <Text style={styles.logoutText}>تسجيل الخروج</Text>
        </TouchableOpacity>

        <View style={styles.footer}>
          <Text style={styles.footerText}>ArtiCode</Text>
          <Text style={styles.footerVersion}>الإصدار 1.0.0</Text>
        </View>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F9FAFB',
  },
  header: {
    backgroundColor: '#FFFFFF',
    paddingTop: 16,
    paddingHorizontal: 20,
    paddingBottom: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  headerTitle: {
    fontSize: 28,
    fontWeight: 'bold',
    color: '#111827',
    textAlign: 'right',
  },
  content: {
    flex: 1,
  },
  contentContainer: {
    paddingBottom: 24,
  },
  profileCard: {
    backgroundColor: '#FFFFFF',
    margin: 16,
    padding: 24,
    borderRadius: 16,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  profileName: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 4,
    textAlign: 'center',
  },
  profilePhone: {
    fontSize: 16,
    color: '#6B7280',
    textAlign: 'center',
  },
  menuSection: {
    backgroundColor: '#FFFFFF',
    marginHorizontal: 16,
    marginBottom: 16,
    borderRadius: 16,
    overflow: 'hidden',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  menuItem: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#F3F4F6',
  },
  lastMenuItem: {
    borderBottomWidth: 0,
  },
  menuItemContent: {
    flexDirection: 'row',
    alignItems: 'center',
    flex: 1,
  },
  menuIcon: {
    width: 48,
    height: 48,
    borderRadius: 24,
    justifyContent: 'center',
    alignItems: 'center',
    marginLeft: 12,
  },
  menuTextContainer: {
    flex: 1,
  },
  menuTitle: {
    fontSize: 16,
    fontWeight: '600',
    color: '#111827',
    marginBottom: 4,
    textAlign: 'right',
  },
  menuSubtitle: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'right',
  },
  logoutButton: {
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#FEE2E2',
    marginHorizontal: 16,
    marginBottom: 16,
    padding: 16,
    borderRadius: 12,
  },
  logoutText: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#EF4444',
    marginLeft: 8,
  },
  footer: {
    padding: 24,
    alignItems: 'center',
  },
  footerText: {
    fontSize: 14,
    color: '#9CA3AF',
    marginBottom: 4,
  },
  footerVersion: {
    fontSize: 12,
    color: '#D1D5DB',
  },
});
