import { Link, Stack } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';

export default function NotFoundScreen() {
  return (
    <>
      <Stack.Screen options={{ title: 'خطأ!' }} />
      <View style={styles.container}>
        <Text style={styles.text}>هذه الصفحة غير موجودة</Text>
        <Link href="/" style={styles.link}>
          <Text style={styles.linkText}>العودة للصفحة الرئيسية</Text>
        </Link>
      </View>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 20,
  },
  text: {
    fontSize: 20,
    fontWeight: '600' as any,
    textAlign: 'center',
  },
  link: {
    marginTop: 15,
    paddingVertical: 15,
  },
  linkText: {
    fontSize: 16,
    color: '#4F46E5',
    fontWeight: '600' as any,
  },
});
