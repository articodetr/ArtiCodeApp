import { useState, useEffect, useCallback } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { Tabs } from 'expo-router';
import { Home, Users, Bell, Settings } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';

// =========================================================
// Pending notifications badge helpers
// The tab badge should count still-pending approvals,
// not only unread notifications.
// =========================================================

type PendingNotificationRow = {
  id: string;
  status?: string | null;
  action_required?: boolean | null;
  notification_type?: string | null;
  extra_data?: {
    approval_status?: string | null;
    [key: string]: unknown;
  } | null;
  movement?: {
    approval_status?: string | null;
    pending_approval?: boolean | null;
  } | null;
};

function isStillPendingNotification(item: PendingNotificationRow) {
  const status = String(
    item.status ||
      item.extra_data?.approval_status ||
      item.movement?.approval_status ||
      '',
  ).toLowerCase();

  if (
    status === 'approved' ||
    status === 'rejected' ||
    status === 'done' ||
    status === 'cancelled' ||
    status === 'canceled'
  ) {
    return false;
  }

  return (
    status === 'pending' ||
    item.notification_type === 'approval_needed' ||
    item.action_required === true ||
    item.movement?.pending_approval === true
  );
}

export default function TabsLayout() {
  const insets = useSafeAreaInsets();
  const { currentUser } = useAuth();
  const [unreadCount, setUnreadCount] = useState(0);

  const loadUnreadCount = useCallback(async () => {
    if (!currentUser?.userId) {
      setUnreadCount(0);
      return;
    }

    const { data, error } = await supabase
      .from('movement_notifications')
      .select(`
        id,
        status,
        action_required,
        notification_type,
        extra_data,
        movement:account_movements!movement_id(
          approval_status,
          pending_approval
        )
      `)
      .eq('user_id', currentUser.userId)
      .is('deleted_at', null);

    if (error) {
      console.error('[TabsLayout] Error loading pending notifications count:', error);
      setUnreadCount(0);
      return;
    }

    const pendingCount = ((data || []) as PendingNotificationRow[]).filter(
      isStillPendingNotification,
    ).length;

    setUnreadCount(pendingCount);
  }, [currentUser?.userId]);

  useEffect(() => {
    loadUnreadCount();
  }, [loadUnreadCount]);

  useEffect(() => {
    if (!currentUser?.userId) return;

    const baseTopic = 'tab-badge-notifications';

    // Remove any previous channels using the same base topic
    // to avoid adding callbacks after subscribe().
    supabase
      .getChannels()
      .filter((channel) => {
        const topic = (channel as { topic?: string })?.topic ?? '';
        return String(topic).includes(baseTopic);
      })
      .forEach((channel) => {
        try {
          void supabase.removeChannel(channel);
        } catch {
          // ignore cleanup errors
        }
      });

    const channelName = `${baseTopic}-${currentUser.userId}-${Date.now()}`;

    const channel = supabase
      .channel(channelName)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'movement_notifications',
          filter: `user_id=eq.${currentUser.userId}`,
        },
        () => {
          loadUnreadCount();
        },
      )
      .subscribe();

    return () => {
      try {
        void supabase.removeChannel(channel);
      } catch {
        // ignore duplicate cleanup
      }
    };
  }, [currentUser?.userId, loadUnreadCount]);

  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: '#2563EB',
        tabBarInactiveTintColor: '#9CA3AF',
        tabBarLabelStyle: {
          fontSize: 12,
          fontWeight: '600',
        },
        tabBarStyle: {
          height: 64 + insets.bottom,
          paddingBottom: Math.max(insets.bottom, 8),
          paddingTop: 8,
          borderTopWidth: 1,
          borderTopColor: '#E5E7EB',
        },
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: 'الرئيسية',
          tabBarIcon: ({ size, color }) => <Home size={size} color={color} />,
        }}
      />

      <Tabs.Screen
        name="customers"
        options={{
          title: 'العملاء',
          tabBarIcon: ({ size, color }) => <Users size={size} color={color} />,
        }}
      />

      <Tabs.Screen
        name="notifications"
        options={{
          title: 'الإشعارات',
          tabBarIcon: ({ size, color }) => (
            <View>
              <Bell size={size} color={color} />
              {unreadCount > 0 && (
                <View style={badgeStyles.badge}>
                  <Text style={badgeStyles.badgeText}>
                    {unreadCount > 99 ? '99+' : unreadCount}
                  </Text>
                </View>
              )}
            </View>
          ),
        }}
      />

      <Tabs.Screen
        name="transactions"
        options={{
          href: null,
        }}
      />

      <Tabs.Screen
        name="settings"
        options={{
          title: 'الإعدادات',
          tabBarIcon: ({ size, color }) => <Settings size={size} color={color} />,
        }}
      />
    </Tabs>
  );
}

const badgeStyles = StyleSheet.create({
  badge: {
    position: 'absolute',
    top: -4,
    right: -10,
    backgroundColor: '#EF4444',
    borderRadius: 10,
    minWidth: 18,
    height: 18,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 4,
  },
  badgeText: {
    color: '#FFFFFF',
    fontSize: 10,
    fontWeight: 'bold',
  },
});