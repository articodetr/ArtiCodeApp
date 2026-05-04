import { I18nManager, TextStyle, ViewStyle } from 'react-native';

export const ARABIC_DIRECTION = 'rtl' as const;

export function setupArabicRTL() {
  I18nManager.allowRTL(true);
  I18nManager.forceRTL(true);
}

export const rtlText: TextStyle = {
  textAlign: 'right',
  writingDirection: 'rtl',
};

export const rtlCenterText: TextStyle = {
  textAlign: 'center',
  writingDirection: 'rtl',
};

export const ltrNumberText: TextStyle = {
  textAlign: 'right',
  writingDirection: 'rtl',
};

export const rtlRow: ViewStyle = {
  flexDirection: 'row',
};

export const rtlScreen: ViewStyle = {
  direction: 'rtl',
};
