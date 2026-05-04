import { useEffect } from 'react';
import * as SplashScreen from 'expo-splash-screen';

declare global {
  interface Window {
    frameworkReady?: () => void;
  }
}

// منع الإخفاء التلقائي عند تحميل الموديول.
// نلتقط الخطأ بصمت لأن هذه الدالة تُرفض إذا تم استدعاؤها أكثر من مرة
// (مثلاً عند Hot Reload في Expo Go).
SplashScreen.preventAutoHideAsync().catch(() => {});

export function useFrameworkReady() {
  useEffect(() => {
    const prepare = async () => {
      try {
        // window غير متاح على الجوال — هذه الحماية أصلاً موجودة بـ ?.
        if (typeof window !== 'undefined') {
          window.frameworkReady?.();
        }
      } catch (error) {
        console.warn('frameworkReady error:', error);
      } finally {
        // نخفي شاشة البداية دائماً حتى لا يعلق التطبيق على الـ splash.
        try {
          await SplashScreen.hideAsync();
        } catch {}
      }
    };

    prepare();
  }, []);
}