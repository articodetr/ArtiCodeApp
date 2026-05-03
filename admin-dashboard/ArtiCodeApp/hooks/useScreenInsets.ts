import { Platform, StatusBar } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

export function useScreenInsets() {
  const insets = useSafeAreaInsets();
  const androidStatusBar = Platform.OS === 'android' ? StatusBar.currentHeight ?? 0 : 0;
  const topInset = Math.max(insets.top, androidStatusBar);
  const bottomInset = insets.bottom;

  return {
    topInset,
    bottomInset,
    headerStyle: {
      paddingTop: topInset + 12,
    },
    scrollContentStyle: {
      paddingBottom: Math.max(bottomInset + 16, 24),
    },
    listContentStyle: {
      paddingBottom: Math.max(bottomInset + 16, 24),
    },
  };
}
