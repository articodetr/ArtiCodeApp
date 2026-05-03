import { ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';

export interface ArabicTemplateTokenItem {
  label: string;
  token: string;
}

interface ArabicTemplateTokenBarProps {
  title?: string;
  items: ArabicTemplateTokenItem[];
  onInsert: (token: string) => void;
}

export function ArabicTemplateTokenBar({
  title = 'اضغط على العنصر لإضافته داخل الرسالة',
  items,
  onInsert,
}: ArabicTemplateTokenBarProps) {
  return (
    <View style={styles.wrapper}>
      <Text style={styles.title}>{title}</Text>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={styles.contentContainer}
      >
        {items.map((item) => (
          <TouchableOpacity
            key={`${item.label}-${item.token}`}
            style={styles.chip}
            onPress={() => onInsert(item.token)}
            activeOpacity={0.85}
          >
            <Text style={styles.chipText}>{item.label}</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  wrapper: {
    marginBottom: 14,
  },
  title: {
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
    marginBottom: 10,
  },
  contentContainer: {
    flexDirection: 'row-reverse',
    gap: 8,
    paddingLeft: 4,
  },
  chip: {
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderRadius: 999,
    backgroundColor: '#EEF2FF',
    borderWidth: 1,
    borderColor: '#C7D2FE',
  },
  chipText: {
    fontSize: 14,
    color: '#3730A3',
    fontWeight: '700',
  },
});
