import React from 'react';
import {
  StyleProp,
  StyleSheet,
  Text,
  View,
  ViewStyle,
} from 'react-native';
import { Link as LinkIcon, User, Wallet } from 'lucide-react-native';
import {
  CustomerDisplaySource,
  getCustomerStatusMeta,
} from '@/utils/customerDisplay';

type BadgeSize = 'sm' | 'md';

interface CustomerStatusBadgeProps {
  customer?: CustomerDisplaySource | null;
  linkedUserId?: string | null;
  isProfitLossAccount?: boolean | null;
  size?: BadgeSize;
  style?: StyleProp<ViewStyle>;
  hideSystem?: boolean;
}

export function CustomerStatusBadge({
  customer,
  linkedUserId,
  isProfitLossAccount,
  size = 'sm',
  style,
  hideSystem = true,
}: CustomerStatusBadgeProps) {
  const source = customer || {
    linked_user_id: linkedUserId,
    is_profit_loss_account: isProfitLossAccount,
  };
  const meta = getCustomerStatusMeta(source);

  if (hideSystem && meta.status === 'system') {
    return null;
  }

  const isMedium = size === 'md';
  const Icon = meta.status === 'linked' ? LinkIcon : meta.status === 'system' ? Wallet : User;

  return (
    <View
      style={[
        styles.badge,
        isMedium ? styles.badgeMedium : styles.badgeSmall,
        {
          backgroundColor: meta.backgroundColor,
          borderColor: meta.borderColor,
        },
        style,
      ]}
    >
      <Icon size={isMedium ? 14 : 12} color={meta.iconColor} />
      <Text
        style={[
          styles.text,
          isMedium ? styles.textMedium : styles.textSmall,
          { color: meta.textColor },
        ]}
      >
        {meta.label}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    borderRadius: 999,
    borderWidth: 1,
    gap: 6,
  },
  badgeSmall: {
    paddingHorizontal: 8,
    paddingVertical: 4,
  },
  badgeMedium: {
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  text: {
    fontWeight: '700',
    textAlign: 'right',
  },
  textSmall: {
    fontSize: 11,
  },
  textMedium: {
    fontSize: 12,
  },
});
