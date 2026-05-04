import React from 'react';
import { View, Text, TextStyle, ViewStyle, StyleSheet } from 'react-native';
import { formatAmountArabic } from '../utils/arabicFormat';

interface CurrencyAmountProps {
  amount: number | string;
  currency: string;
  amountStyle?: TextStyle;
  currencyStyle?: TextStyle;
  containerStyle?: ViewStyle;
  showSign?: boolean;
}

export default function CurrencyAmount({
  amount,
  currency,
  amountStyle,
  currencyStyle,
  containerStyle,
  showSign = false,
}: CurrencyAmountProps) {
  const numericAmount = Number(amount);
  const safeAmount = Number.isFinite(numericAmount) ? numericAmount : 0;
  const signedAmount = showSign && safeAmount > 0 ? `+${safeAmount}` : safeAmount;

  return (
    <View style={[styles.container, containerStyle]}>
      <Text style={[styles.amount, currencyStyle, amountStyle]}>
        {formatAmountArabic(signedAmount, currency)}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    justifyContent: 'flex-start',
    alignItems: 'center',
    width: '100%',
  },
  amount: {
    writingDirection: 'rtl',
    textAlign: 'right',
    color: '#0F172A',
    fontWeight: '900',
  },
});
