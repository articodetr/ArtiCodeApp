import React, { useState, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  Animated,
  Platform,
  TextInput,
  KeyboardAvoidingView,
} from 'react-native';
import { useRouter } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import * as Haptics from 'expo-haptics';
import * as Crypto from 'expo-crypto';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { usePin } from '@/contexts/PinContext';
import { Lock, LogIn } from 'lucide-react-native';

export default function PinEntry() {
  const router = useRouter();
  const { verifyPin: markPinAsVerified } = usePin();
  const insets = useSafeAreaInsets();
  const [pin, setPin] = useState<string>('');
  const [error, setError] = useState<string>('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const shakeAnimation = new Animated.Value(0);
  const inputRef = useRef<TextInput>(null);

  const handleSubmit = () => {
    if (pin.length < 8) {
      setError('رقم PIN يجب أن يكون 8 أحرف على الأقل');
      if (Platform.OS !== 'web') {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      }
      shakeError();
      return;
    }
    if (pin.length > 16) {
      setError('رقم PIN يجب أن لا يزيد عن 16 حرف');
      if (Platform.OS !== 'web') {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      }
      shakeError();
      return;
    }
    verifyEnteredPin(pin);
  };

  const verifyEnteredPin = async (enteredPin: string) => {
    if (isSubmitting) return;

    setIsSubmitting(true);
    try {
      const hashHex = await Crypto.digestStringAsync(
        Crypto.CryptoDigestAlgorithm.SHA256,
        enteredPin
      );

      const { supabase } = await import('@/lib/supabase');
      const { data: securityData, error: fetchError } = await supabase
        .from('app_security')
        .select('pin_hash')
        .maybeSingle();

      if (fetchError) throw fetchError;

      if (securityData && securityData.pin_hash === hashHex) {
        if (Platform.OS !== 'web') {
          Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        }
        markPinAsVerified();
        router.replace('/(tabs)');
      } else {
        setError('رقم PIN غير صحيح');
        setPin('');
        shakeError();

        if (Platform.OS !== 'web') {
          Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
        }
      }
    } catch (err) {
      console.error('Error verifying PIN:', err);
      setError('حدث خطأ أثناء التحقق');
      setPin('');
    } finally {
      setIsSubmitting(false);
    }
  };

  const shakeError = () => {
    Animated.sequence([
      Animated.timing(shakeAnimation, {
        toValue: 10,
        duration: 50,
        useNativeDriver: true,
      }),
      Animated.timing(shakeAnimation, {
        toValue: -10,
        duration: 50,
        useNativeDriver: true,
      }),
      Animated.timing(shakeAnimation, {
        toValue: 10,
        duration: 50,
        useNativeDriver: true,
      }),
      Animated.timing(shakeAnimation, {
        toValue: 0,
        duration: 50,
        useNativeDriver: true,
      }),
    ]).start();
  };

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
    >
      <StatusBar style="light" />

      <View
        style={[
          styles.content,
          { paddingBottom: Math.max(insets.bottom + 24, 32) },
        ]}
      >
        <View style={styles.iconContainer}>
          <Lock size={64} color="#10B981" />
        </View>

        <Text style={styles.title}>أدخل رقم PIN</Text>
        <Text style={styles.subtitle}>
          استخدم رقم PIN المكون من 8-16 حرف (أرقام، أحرف، رموز)
        </Text>

        <Animated.View
          style={[
            styles.inputContainer,
            { transform: [{ translateX: shakeAnimation }] },
          ]}
        >
          <Lock size={20} color="#9CA3AF" />
          <TextInput
            ref={inputRef}
            style={styles.input}
            placeholder="أدخل رقم PIN"
            placeholderTextColor="#6B7280"
            value={pin}
            onChangeText={(text) => {
              if (text.length <= 16) {
                setPin(text);
                setError('');
              }
            }}
            secureTextEntry
            autoFocus
            autoCapitalize="none"
            autoCorrect={false}
            textAlign="right"
            returnKeyType="go"
            onSubmitEditing={handleSubmit}
          />
        </Animated.View>

        {pin.length > 0 && (
          <View style={styles.lengthIndicator}>
            <Text style={[
              styles.lengthText,
              pin.length >= 8 && pin.length <= 16 ? styles.lengthTextValid : styles.lengthTextInvalid
            ]}>
              {pin.length} / 16 حرف
            </Text>
          </View>
        )}

        {error ? (
          <View style={styles.errorContainer}>
            <Text style={styles.errorText}>{error}</Text>
          </View>
        ) : null}

        <TouchableOpacity
          style={[
            styles.submitButton,
            (isSubmitting || pin.length < 8) && styles.submitButtonDisabled
          ]}
          onPress={handleSubmit}
          disabled={isSubmitting || pin.length < 8}
        >
          {isSubmitting ? (
            <Text style={styles.submitButtonText}>جاري التحقق...</Text>
          ) : (
            <>
              <LogIn size={20} color="#FFFFFF" />
              <Text style={styles.submitButtonText}>دخول</Text>
            </>
          )}
        </TouchableOpacity>
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#111827',
  },
  content: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 32,
  },
  iconContainer: {
    width: 120,
    height: 120,
    borderRadius: 60,
    backgroundColor: '#1F2937',
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 32,
    borderWidth: 2,
    borderColor: '#10B981',
  },
  title: {
    fontSize: 28,
    fontWeight: 'bold',
    color: '#FFFFFF',
    marginBottom: 12,
    textAlign: 'center',
  },
  subtitle: {
    fontSize: 15,
    color: '#9CA3AF',
    textAlign: 'center',
    marginBottom: 40,
    lineHeight: 22,
  },
  inputContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#1F2937',
    borderRadius: 16,
    borderWidth: 2,
    borderColor: '#374151',
    paddingHorizontal: 20,
    paddingVertical: 4,
    width: '100%',
    maxWidth: 400,
  },
  input: {
    flex: 1,
    fontSize: 18,
    color: '#FFFFFF',
    paddingVertical: 16,
    paddingHorizontal: 12,
  },
  lengthIndicator: {
    marginTop: 12,
    width: '100%',
    maxWidth: 400,
  },
  lengthText: {
    fontSize: 14,
    textAlign: 'right',
    fontWeight: '500',
  },
  lengthTextValid: {
    color: '#10B981',
  },
  lengthTextInvalid: {
    color: '#F59E0B',
  },
  errorContainer: {
    marginTop: 16,
    backgroundColor: '#7F1D1D',
    paddingVertical: 12,
    paddingHorizontal: 20,
    borderRadius: 12,
    width: '100%',
    maxWidth: 400,
  },
  errorText: {
    color: '#FEE2E2',
    fontSize: 15,
    textAlign: 'center',
    fontWeight: '500',
  },
  submitButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
    backgroundColor: '#10B981',
    paddingVertical: 18,
    paddingHorizontal: 32,
    borderRadius: 16,
    marginTop: 32,
    width: '100%',
    maxWidth: 400,
  },
  submitButtonDisabled: {
    opacity: 0.5,
  },
  submitButtonText: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
});
