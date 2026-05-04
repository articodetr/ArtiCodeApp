import { useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TextInput,
  TouchableOpacity,
  Alert,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, Send, MessageSquare } from 'lucide-react-native';
import { KeyboardAwareView } from '@/components/KeyboardAwareView';

interface Message {
  id: string;
  text: string;
  isUser: boolean;
  timestamp: Date;
}

export default function AIAssistantScreen() {
  const router = useRouter();
  const [messages, setMessages] = useState<Message[]>([
    {
      id: '1',
      text: 'مرحباً! أنا المساعد الذكي. يمكنني مساعدتك في:\n\n• البحث عن معلومات العملاء\n• عرض إحصائيات الحوالات\n• الاستعلام عن الديون\n• تحليل البيانات المالية\n\nكيف يمكنني مساعدتك اليوم؟',
      isUser: false,
      timestamp: new Date(),
    },
  ]);
  const [inputText, setInputText] = useState('');
  const [isProcessing, setIsProcessing] = useState(false);

  const suggestedQuestions = [
    'كم عدد الحوالات اليوم؟',
    'من هم العملاء الأكثر نشاطاً؟',
    'ما هو إجمالي الديون المستحقة؟',
    'عرض حوالات هذا الأسبوع',
  ];

  const handleSend = async () => {
    if (!inputText.trim()) return;

    const userMessage: Message = {
      id: Date.now().toString(),
      text: inputText,
      isUser: true,
      timestamp: new Date(),
    };

    setMessages((prev) => [...prev, userMessage]);
    setInputText('');
    setIsProcessing(true);

    setTimeout(() => {
      const aiResponse: Message = {
        id: (Date.now() + 1).toString(),
        text: 'عذراً، هذه الميزة قيد التطوير حالياً. سيتم دمج الذكاء الاصطناعي قريباً للإجابة على استفساراتك بشكل ذكي وتحليل بياناتك.\n\nيمكنك حالياً استخدام شاشات الإحصائيات والتقارير للحصول على معلومات مفصلة.',
        isUser: false,
        timestamp: new Date(),
      };
      setMessages((prev) => [...prev, aiResponse]);
      setIsProcessing(false);
    }, 1000);
  };

  const handleSuggestedQuestion = (question: string) => {
    setInputText(question);
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>المساعد الذكي</Text>
        <View style={{ width: 40 }} />
      </View>

      <KeyboardAwareView contentContainerStyle={styles.messagesContent}>
        {messages.map((message) => (
          <View
            key={message.id}
            style={[styles.messageBubble, message.isUser ? styles.userMessage : styles.aiMessage]}
          >
            {!message.isUser && (
              <View style={styles.aiIcon}>
                <MessageSquare size={20} color="#4F46E5" />
              </View>
            )}
            <View style={styles.messageContent}>
              <Text
                style={[styles.messageText, message.isUser ? styles.userText : styles.aiText]}
              >
                {message.text}
              </Text>
            </View>
          </View>
        ))}

        {isProcessing && (
          <View style={[styles.messageBubble, styles.aiMessage]}>
            <View style={styles.aiIcon}>
              <MessageSquare size={20} color="#4F46E5" />
            </View>
            <View style={styles.messageContent}>
              <Text style={styles.processingText}>جاري المعالجة...</Text>
            </View>
          </View>
        )}

        <View style={styles.suggestionsContainer}>
          <Text style={styles.suggestionsTitle}>أسئلة مقترحة:</Text>
          {suggestedQuestions.map((question, index) => (
            <TouchableOpacity
              key={index}
              style={styles.suggestionButton}
              onPress={() => handleSuggestedQuestion(question)}
            >
              <Text style={styles.suggestionText}>{question}</Text>
            </TouchableOpacity>
          ))}
        </View>
      </KeyboardAwareView>

      <View style={styles.inputContainer}>
        <TouchableOpacity
          style={[styles.sendButton, !inputText.trim() && styles.sendButtonDisabled]}
          onPress={handleSend}
          disabled={!inputText.trim() || isProcessing}
        >
          <Send size={24} color="#FFFFFF" />
        </TouchableOpacity>
        <TextInput
          style={styles.input}
          value={inputText}
          onChangeText={setInputText}
          placeholder="اكتب سؤالك هنا..."
          placeholderTextColor="#9CA3AF"
          multiline
          textAlign="right"
        />
      </View>
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
    justifyContent: 'space-between',
    alignItems: 'center',
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  backButton: {
    width: 40,
    height: 40,
    justifyContent: 'center',
    alignItems: 'center',
  },
  headerTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
  },
  messagesContent: {
    padding: 16,
  },
  messageBubble: {
    flexDirection: 'row',
    marginBottom: 16,
    alignItems: 'flex-start',
  },
  userMessage: {
    justifyContent: 'flex-end',
    flexDirection: 'row',
  },
  aiMessage: {
    justifyContent: 'flex-start',
  },
  aiIcon: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: '#EEF2FF',
    justifyContent: 'center',
    alignItems: 'center',
    marginLeft: 8,
  },
  messageContent: {
    flex: 1,
    maxWidth: '80%',
  },
  messageText: {
    fontSize: 16,
    lineHeight: 24,
    padding: 12,
    borderRadius: 12,
  },
  userText: {
    backgroundColor: '#4F46E5',
    color: '#FFFFFF',
    textAlign: 'right',
  },
  aiText: {
    backgroundColor: '#FFFFFF',
    color: '#111827',
    textAlign: 'right',
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  processingText: {
    fontSize: 16,
    color: '#6B7280',
    fontStyle: 'italic',
    padding: 12,
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  suggestionsContainer: {
    marginTop: 24,
  },
  suggestionsTitle: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 12,
    textAlign: 'right',
  },
  suggestionButton: {
    backgroundColor: '#FFFFFF',
    padding: 16,
    borderRadius: 12,
    marginBottom: 8,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  suggestionText: {
    fontSize: 14,
    color: '#4F46E5',
    textAlign: 'right',
  },
  inputContainer: {
    flexDirection: 'row',
    padding: 16,
    backgroundColor: '#FFFFFF',
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
    alignItems: 'flex-end',
  },
  input: {
    flex: 1,
    backgroundColor: '#F9FAFB',
    borderRadius: 24,
    paddingHorizontal: 20,
    paddingVertical: 12,
    fontSize: 16,
    maxHeight: 100,
    marginRight: 12,
  },
  sendButton: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: '#4F46E5',
    justifyContent: 'center',
    alignItems: 'center',
  },
  sendButtonDisabled: {
    opacity: 0.5,
  },
});
