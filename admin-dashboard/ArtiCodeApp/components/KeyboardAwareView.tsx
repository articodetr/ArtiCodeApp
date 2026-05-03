import React from 'react';
import {
  KeyboardAvoidingView,
  ScrollView,
  Platform,
  StyleProp,
  ViewStyle,
  Keyboard,
  TouchableWithoutFeedback,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

interface KeyboardAwareViewProps {
  style?: StyleProp<ViewStyle>;
  children: React.ReactNode;
  contentContainerStyle?: StyleProp<ViewStyle>;
  enableAutomaticScroll?: boolean;
  extraScrollHeight?: number;
  keyboardVerticalOffset?: number;
  useScrollView?: boolean;
}

export function KeyboardAwareView({
  children,
  style,
  contentContainerStyle,
  enableAutomaticScroll = true,
  extraScrollHeight = 150,
  keyboardVerticalOffset,
  useScrollView = true,
}: KeyboardAwareViewProps) {
  const insets = useSafeAreaInsets();
  const defaultOffset = Platform.OS === 'ios' ? insets.top + 24 : 20;
  const offset = keyboardVerticalOffset !== undefined ? keyboardVerticalOffset : defaultOffset;

  if (!useScrollView) {
    return (
      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
        keyboardVerticalOffset={offset}
        enabled={enableAutomaticScroll}
      >
        <TouchableWithoutFeedback onPress={Keyboard.dismiss} accessible={false}>
          <View style={[{ flex: 1 }, contentContainerStyle]}>
            {children}
          </View>
        </TouchableWithoutFeedback>
      </KeyboardAvoidingView>
    );
  }

  return (
    <KeyboardAvoidingView
      style={{ flex: 1 }}
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
      keyboardVerticalOffset={offset}
      enabled={enableAutomaticScroll}
    >
      <TouchableWithoutFeedback onPress={Keyboard.dismiss} accessible={false}>
        <ScrollView
          contentContainerStyle={[
            { flexGrow: 1, paddingBottom: extraScrollHeight + insets.bottom },
            contentContainerStyle
          ]}
          contentInsetAdjustmentBehavior="automatic"
          automaticallyAdjustKeyboardInsets={Platform.OS === 'ios'}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
          bounces={true}
          nestedScrollEnabled={true}
          scrollEventThrottle={16}
        >
          {children}
        </ScrollView>
      </TouchableWithoutFeedback>
    </KeyboardAvoidingView>
  );
}
