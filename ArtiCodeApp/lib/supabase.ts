import 'react-native-url-polyfill/auto';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';
import Constants from 'expo-constants';
import { Platform } from 'react-native';

// نقرأ المفاتيح من EXPO_PUBLIC_* أولاً (المعتمد في Expo)،
// ثم من extra كاحتياط حتى لا ينكسر الإصدار التجريبي إذا غاب ملف .env.
const supabaseUrl =
  process.env.EXPO_PUBLIC_SUPABASE_URL ||
  (Constants.expoConfig?.extra as any)?.EXPO_PUBLIC_SUPABASE_URL ||
  '';

const supabaseAnonKey =
  process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY ||
  (Constants.expoConfig?.extra as any)?.EXPO_PUBLIC_SUPABASE_ANON_KEY ||
  '';

if (!supabaseUrl || !supabaseAnonKey) {
  // رسالة واضحة إذا لم يتم تعيين متغيرات البيئة (تظهر في Metro/Expo Go)
  console.warn(
    '[supabase] EXPO_PUBLIC_SUPABASE_URL أو EXPO_PUBLIC_SUPABASE_ANON_KEY غير معرّف. ' +
      'تأكد من وجود ملف .env في جذر المشروع وأعد تشغيل expo start بـ -c'
  );
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    // استخدم AsyncStorage على الجوال (iOS / Android) فقط — على الويب
    // اترك المكتبة تستخدم localStorage الافتراضي.
    storage: Platform.OS === 'web' ? undefined : AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});