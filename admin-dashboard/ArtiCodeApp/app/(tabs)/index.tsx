import { useEffect, useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  RefreshControl,
} from 'react-native';
import { useRouter } from 'expo-router';
import {
  Users,
  BarChart3,
  FileText,
} from 'lucide-react-native';
import { useAuth } from '@/contexts/AuthContext';

export default function DashboardScreen() {
  const router = useRouter();
  const { settings, refreshSettings } = useAuth();
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    if (!settings) {
      refreshSettings();
    }
  }, [settings, refreshSettings]);

  const onRefresh = async () => {
    setRefreshing(true);
    await refreshSettings();
    setRefreshing(false);
  };

  const menuItems = [
    {
      icon: Users,
      title: 'الحسابات',
      subtitle: 'إدارة العملاء',
      color: '#8B5CF6',
      route: '/(tabs)/customers',
    },
    {
      icon: FileText,
      title: 'تقرير الحسابات',
      subtitle: 'تقارير مفصلة',
      color: '#10B981',
      route: '/reports',
    },
    {
      icon: BarChart3,
      title: 'إحصائيات',
      subtitle: 'إحصائيات شاملة',
      color: '#EC4899',
      route: '/statistics',
    },
  ];

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <View>
          <Text style={styles.headerTitle}>{settings?.shop_name || 'الصرافة'}</Text>
          <Text style={styles.headerSubtitle}>
            {new Date().toLocaleDateString('ar-EG', {
              weekday: 'long',
              year: 'numeric',
              month: 'long',
              day: 'numeric',
            })}
          </Text>
        </View>
      </View>

      <ScrollView
        style={styles.content}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
      >
        <View style={styles.menuGrid}>
          {menuItems.map((item, index) => (
            <TouchableOpacity
              key={index}
              style={styles.menuItem}
              onPress={() => router.push(item.route as any)}
            >
              <View style={[styles.menuIconContainer, { backgroundColor: `${item.color}15` }]}>
                <item.icon size={32} color={item.color} />
              </View>
              <Text style={styles.menuTitle}>{item.title}</Text>
              <Text style={styles.menuSubtitle}>{item.subtitle}</Text>
            </TouchableOpacity>
          ))}
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
    paddingBottom: 20,
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  headerTitle: {
    fontSize: 28,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 4,
    textAlign: 'right',
  },
  headerSubtitle: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'right',
  },
  content: {
    flex: 1,
  },
  menuGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'space-between',
    padding: 16,
    gap: 16,
  },
  menuItem: {
    width: '47%',
    backgroundColor: '#FFFFFF',
    borderRadius: 16,
    padding: 20,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  menuIconContainer: {
    width: 64,
    height: 64,
    borderRadius: 32,
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 12,
  },
  menuTitle: {
    fontSize: 13,
    fontWeight: 'bold',
    color: '#111827',
    textAlign: 'center',
    marginBottom: 4,
  },
  menuSubtitle: {
    fontSize: 11,
    color: '#6B7280',
    textAlign: 'center',
  },
});
