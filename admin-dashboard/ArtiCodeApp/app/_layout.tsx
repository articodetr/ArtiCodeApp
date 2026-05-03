import '@/utils/arabicRTL';
import { useEffect } from 'react';
import { Stack, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { useFrameworkReady } from '@/hooks/useFrameworkReady';
import { AuthProvider, useAuth } from '@/contexts/AuthContext';
import { DataRefreshProvider } from '@/contexts/DataRefreshContext';
import { setupArabicRTL } from '@/utils/rtl';

setupArabicRTL();

function RootLayoutNav() {
  const { isAuthenticated, isLoading } = useAuth();
  const segments = useSegments();
  const router = useRouter();

  useEffect(() => {
    if (isLoading) return;

    const inAuthGroup = segments[0] === '(auth)';

    if (!isAuthenticated && !inAuthGroup) {
      router.replace('/(auth)/login');
    } else if (isAuthenticated && inAuthGroup) {
      router.replace('/(tabs)');
    }
  }, [isAuthenticated, isLoading, segments]);

  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Screen name="index" />
      <Stack.Screen name="(auth)" />
      <Stack.Screen name="(tabs)" />
      <Stack.Screen name="pin-entry" />
      <Stack.Screen name="pin-settings" />
      <Stack.Screen name="add-customer" />
      <Stack.Screen name="customer-details" />
      <Stack.Screen name="customer-notifications" />
      <Stack.Screen name="new-transaction" />
      <Stack.Screen name="transaction-details" />
      <Stack.Screen name="new-movement" />
      <Stack.Screen name="edit-movement" />
      <Stack.Screen name="movement-details" />
      <Stack.Screen name="receipt-preview" />
      <Stack.Screen name="debt-summary" />
      <Stack.Screen name="shop-settings" />
      <Stack.Screen name="exchange-rates" />
      <Stack.Screen name="calculator" />
      <Stack.Screen name="debts" />
      <Stack.Screen name="statistics" />
      <Stack.Screen name="ai-assistant" />
      <Stack.Screen name="backup" />
      <Stack.Screen name="reports" />
      <Stack.Screen name="notification-detail" />
      <Stack.Screen name="+not-found" />
    </Stack>
  );
}

export default function RootLayout() {
  useFrameworkReady();

  return (
    <SafeAreaProvider>
      <AuthProvider>
        <DataRefreshProvider>
          <SafeAreaView style={{ flex: 1, direction: 'rtl' }} edges={['top']}>
            <RootLayoutNav />
            <StatusBar style="auto" />
          </SafeAreaView>
        </DataRefreshProvider>
      </AuthProvider>
    </SafeAreaProvider>
  );
}
