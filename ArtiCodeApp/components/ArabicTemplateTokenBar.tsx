import React from 'react';
import { ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';

export type ArabicTemplateTokenItem = {
  label: string;
  value?: string;
  token?: string;
};

type ArabicTemplateTokenBarProps = {
  items?: ArabicTemplateTokenItem[];
  tokens?: ArabicTemplateTokenItem[];
  onInsert: (value: string) => void;
};

export function ArabicTemplateTokenBar({
  items,
  tokens,
  onInsert,
}: ArabicTemplateTokenBarProps) {
  const sourceItems = items ?? tokens ?? [];

  return (
    <View style={styles.wrapper}>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={styles.content}
      >
        {sourceItems.map((item, index) => {
          const insertValue = item.value ?? item.token ?? '';

          return (
            <TouchableOpacity
              key={item.label + '-' + insertValue + '-' + index}
              style={styles.tokenButton}
              onPress={() => onInsert(insertValue)}
              activeOpacity={0.85}
            >
              <Text style={styles.tokenText}>{item.label}</Text>
            </TouchableOpacity>
          );
        })}
      </ScrollView>
    </View>
  );
}

export default ArabicTemplateTokenBar;

const styles = StyleSheet.create({
  wrapper: {
    marginBottom: 12,
  },
  content: {
    flexDirection: 'row-reverse',
    paddingVertical: 4,
    paddingHorizontal: 2,
  },
  tokenButton: {
    backgroundColor: '#F2F4F7',
    borderRadius: 16,
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    marginLeft: 8,
  },
  tokenText: {
    fontSize: 14,
    color: '#111827',
    fontWeight: '600',
    textAlign: 'center',
  },
});
