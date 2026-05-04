import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  TextInput,
  Alert,
  Platform,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, Lock, User, Check } from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import * as Haptics from 'expo-haptics';
import * as Crypto from 'expo-crypto';
import { KeyboardAwareView } from '@/components/KeyboardAwareView';

export default function PinSettings() {
  const router = useRouter();
  const [pinExists, setPinExists] = useState(false);
  const [userName, setUserName] = useState('');
  const [currentUserName, setCurrentUserName] = useState('');
  const [pin, setPin] = useState('');
  const [loading, setLoading] = useState(false);
  const [checkingPin, setCheckingPin] = useState(true);

  useEffect(() => {
    checkPinStatus();
  }, []);

  const checkPinStatus = async () => {
    try {
      const { data, error } = await supabase
        .from('app_security')
        .select('user_name')
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (error) throw error;

      if (data) {
        setPinExists(true);
        setCurrentUserName(data.user_name);
      }
    } catch (error) {
      console.error('Error checking PIN status:', error);
    } finally {
      setCheckingPin(false);
    }
  };

  const hashPin = async (pinValue: string): Promise<string> => {
    const hash = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      pinValue
    );
    return hash;
  };

  const handleSetPin = async () => {
    if (!userName.trim()) {
      Alert.alert('خطأ', 'الرجاء إدخال اسم المستخدم');
      return;
    }

    if (pin.length < 8) {
      Alert.alert('خطأ', 'رقم PIN يجب أن يكون 8 أحرف على الأقل');
      return;
    }

    if (pin.length > 16) {
      Alert.alert('خطأ', 'رقم PIN يجب أن لا يزيد عن 16 حرف');
      return;
    }

    setLoading(true);

    try {
      const pinHash = await hashPin(pin);

      const { error } = await supabase.from('app_security').insert({
        user_name: userName.trim(),
        pin_hash: pinHash,
        role: 'user',
        is_active: true,
      });

      if (error) throw error;

      if (Platform.OS !== 'web') {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      }

      Alert.alert('نجح', 'تم إضافة المستخدم بنجاح', [
        {
          text: 'حسناً',
          onPress: () => router.back(),
        },
      ]);

      setPin('');
      setUserName('');
      await checkPinStatus();
    } catch (error: any) {
      console.error('Error setting PIN:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء حفظ رقم PIN');
    } finally {
      setLoading(false);
    }
  };


  if (checkingPin) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity onPress={() => router.back()} style={styles.backButton}>
            <ArrowRight size={24} color="#111827" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>إعدادات PIN</Text>
        </View>
        <View style={styles.loadingContainer}>
          <Text style={styles.loadingText}>جاري التحميل...</Text>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => router.back()} style={styles.backButton}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>إعدادات PIN</Text>
      </View>

      <KeyboardAwareView contentContainerStyle={styles.contentContainer}>
        <View style={styles.infoCard}>
          <Lock size={32} color="#4F46E5" />
          <Text style={styles.infoTitle}>إضافة مستخدم جديد</Text>
          <Text style={styles.infoSubtitle}>
            استخدم صفحة "إدارة المستخدمين" لتعديل أو حذف المستخدمين الموجودين
          </Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>معلومات المستخدم الجديد</Text>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>اسم المستخدم</Text>
            <View style={styles.inputContainer}>
              <User size={20} color="#6B7280" />
              <TextInput
                style={styles.input}
                placeholder="أدخل اسم المستخدم"
                placeholderTextColor="#9CA3AF"
                value={userName}
                onChangeText={setUserName}
                textAlign="right"
              />
            </View>
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>رقم PIN (8-16 حرف: أرقام، أحرف، رموز)</Text>
            <View style={styles.inputContainer}>
              <Lock size={20} color="#6B7280" />
              <TextInput
                style={styles.input}
                placeholder="أدخل رقم PIN"
                placeholderTextColor="#9CA3AF"
                value={pin}
                onChangeText={(text) => {
                  if (text.length <= 16) {
                    setPin(text);
                  }
                }}
                maxLength={16}
                secureTextEntry
                autoCapitalize="none"
                autoCorrect={false}
                textAlign="right"
              />
            </View>
            {pin.length > 0 && (
              <Text style={[
                styles.lengthIndicator,
                pin.length >= 8 && pin.length <= 16 ? styles.lengthIndicatorValid : styles.lengthIndicatorInvalid
              ]}>
                {pin.length} / 16 حرف
              </Text>
            )}
          </View>

          <TouchableOpacity
            style={[styles.button, loading && styles.buttonDisabled]}
            onPress={handleSetPin}
            disabled={loading}
          >
            <Check size={20} color="#FFFFFF" />
            <Text style={styles.buttonText}>
              {loading ? 'جاري الحفظ...' : 'إضافة مستخدم'}
            </Text>
          </TouchableOpacity>
        </View>

        <View style={styles.infoSection}>
          <Text style={styles.infoSectionTitle}>معلومات مهمة</Text>
          <Text style={styles.infoSectionText}>
            • رقم PIN يجب أن يكون 8 أحرف على الأقل{'\n'}
            • الحد الأقصى 16 حرف{'\n'}
            • يمكن استخدام الأرقام والأحرف والرموز{'\n'}
            • احفظ رقم PIN في مكان آمن{'\n'}
            • سيتم طلب رقم PIN عند فتح التطبيق{'\n'}
            • لتعديل أو حذف المستخدمين، استخدم صفحة "إدارة المستخدمين"
          </Text>
        </View>
      </KeyboardAwareView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F9FAFB',
  },
  header: {
    backgroundColor: '#FFFFFF',
    paddingTop: 16,
    paddingHorizontal: 20,
    paddingBottom: 16,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  backButton: {
    padding: 4,
  },
  headerTitle: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#111827',
    flex: 1,
    textAlign: 'right',
  },
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {
    fontSize: 16,
    color: '#6B7280',
  },
  contentContainer: {
    padding: 0,
  },
  infoCard: {
    backgroundColor: '#EEF2FF',
    margin: 16,
    padding: 20,
    borderRadius: 16,
    alignItems: 'center',
    borderWidth: 1,
    borderColor: '#4F46E5',
  },
  infoTitle: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#312E81',
    marginTop: 12,
  },
  infoSubtitle: {
    fontSize: 14,
    color: '#4338CA',
    marginTop: 4,
    textAlign: 'center',
  },
  card: {
    backgroundColor: '#FFFFFF',
    margin: 16,
    padding: 20,
    borderRadius: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  cardTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 20,
    textAlign: 'right',
  },
  inputGroup: {
    marginBottom: 20,
  },
  label: {
    fontSize: 14,
    fontWeight: '600',
    color: '#374151',
    marginBottom: 8,
    textAlign: 'right',
  },
  inputContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    backgroundColor: '#F9FAFB',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 12,
    paddingHorizontal: 16,
  },
  input: {
    flex: 1,
    paddingVertical: 14,
    fontSize: 16,
    color: '#111827',
  },
  button: {
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
    backgroundColor: '#10B981',
    paddingVertical: 16,
    borderRadius: 12,
    marginTop: 8,
  },
  buttonDisabled: {
    opacity: 0.6,
  },
  buttonText: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  infoSection: {
    backgroundColor: '#FFFFFF',
    margin: 16,
    padding: 20,
    borderRadius: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  infoSectionTitle: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 12,
    textAlign: 'right',
  },
  infoSectionText: {
    fontSize: 14,
    color: '#6B7280',
    lineHeight: 22,
    textAlign: 'right',
  },
  lengthIndicator: {
    fontSize: 13,
    marginTop: 6,
    textAlign: 'right',
    fontWeight: '500',
  },
  lengthIndicatorValid: {
    color: '#10B981',
  },
  lengthIndicatorInvalid: {
    color: '#F59E0B',
  },
});
