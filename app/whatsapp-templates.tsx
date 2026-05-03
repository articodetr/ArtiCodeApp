import { useEffect, useMemo, useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  TextInput,
  Alert,
  ActivityIndicator,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ChevronRight, Save, RotateCcw, Eye } from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import {
  APP_SETTINGS_FIXED_ID,
  DEFAULT_WHATSAPP_TEMPLATES,
  fetchWhatsAppTemplates,
  generatePreviewMessage,
  WhatsAppTemplates,
} from '@/utils/whatsappTemplates';
import { ArabicTemplateTokenBar } from '../components/ArabicTemplateTokenBar';

type TemplateKey = keyof WhatsAppTemplates;

type SelectionRange = {
  start: number;
  end: number;
};

export default function WhatsAppTemplatesScreen() {
  const router = useRouter();

  const [templates, setTemplates] = useState<WhatsAppTemplates>({
    account_statement: '',
    share_account: '',
  });
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [activeTemplate, setActiveTemplate] = useState<TemplateKey>('account_statement');
  const [selections, setSelections] = useState<Record<TemplateKey, SelectionRange>>({
    account_statement: { start: 0, end: 0 },
    share_account: { start: 0, end: 0 },
  });

  const accountToolbarItems = useMemo(
    () => [
      { label: 'الاسم', token: '{الاسم}' },
      { label: 'رقم الحساب', token: '{رقم_الحساب}' },
      { label: 'التاريخ', token: '{التاريخ}' },
      { label: 'الرصيد', token: '{الرصيد}' },
    ],
    []
  );

  const shareToolbarItems = useMemo(
    () => [
      { label: 'الاسم', token: '{الاسم}' },
      { label: 'رقم الحساب', token: '{رقم_الحساب}' },
      { label: 'التاريخ', token: '{التاريخ}' },
      { label: 'الأرصدة', token: '{الأرصدة}' },
      { label: 'الحركات المالية', token: '{الحركات المالية}' },
      { label: 'اسم المحل', token: '{اسم_المحل}' },
    ],
    []
  );

  useEffect(() => {
    loadTemplates();
  }, []);

  async function loadTemplates() {
    try {
      const loadedTemplates = await fetchWhatsAppTemplates();
      setTemplates(loadedTemplates);
      setSelections({
        account_statement: {
          start: loadedTemplates.account_statement.length,
          end: loadedTemplates.account_statement.length,
        },
        share_account: {
          start: loadedTemplates.share_account.length,
          end: loadedTemplates.share_account.length,
        },
      });
    } catch (error) {
      console.error('Error loading templates:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء تحميل القوالب');
    } finally {
      setIsLoading(false);
    }
  }

  function updateTemplate(key: TemplateKey, text: string) {
    setTemplates((prev) => ({
      ...prev,
      [key]: text,
    }));
  }

  function handleSelectionChange(key: TemplateKey, event: any) {
    const selection = event?.nativeEvent?.selection;
    if (!selection) return;

    setSelections((prev) => ({
      ...prev,
      [key]: {
        start: selection.start ?? 0,
        end: selection.end ?? selection.start ?? 0,
      },
    }));
  }

  function handleInsertToken(key: TemplateKey, token: string) {
    const currentText = templates[key] || '';
    const currentSelection = selections[key] || {
      start: currentText.length,
      end: currentText.length,
    };

    const start = Math.max(0, Math.min(currentSelection.start, currentText.length));
    const end = Math.max(0, Math.min(currentSelection.end, currentText.length));

    const nextValue =
      currentText.slice(0, start) + token + currentText.slice(end);

    const nextCursor = start + token.length;

    setTemplates((prev) => ({
      ...prev,
      [key]: nextValue,
    }));

    setSelections((prev) => ({
      ...prev,
      [key]: {
        start: nextCursor,
        end: nextCursor,
      },
    }));

    setActiveTemplate(key);
  }

  async function handleSave() {
    if (!templates.account_statement.trim() || !templates.share_account.trim()) {
      Alert.alert('تنبيه', 'يجب تعبئة القالبين قبل الحفظ');
      return;
    }

    setIsSaving(true);

    try {
      const { error } = await supabase.from('app_settings').upsert(
        {
          id: APP_SETTINGS_FIXED_ID,
          whatsapp_account_statement_template: templates.account_statement,
          whatsapp_share_account_template: templates.share_account,
        },
        { onConflict: 'id' }
      );

      if (error) throw error;

      Alert.alert('تم', 'تم حفظ القوالب بنجاح');
    } catch (error) {
      console.error('Error saving templates:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء حفظ القوالب');
    } finally {
      setIsSaving(false);
    }
  }

  function handleReset(key: TemplateKey) {
    const title =
      key === 'account_statement'
        ? 'استعادة القالب الافتراضي للرسالة السريعة'
        : 'استعادة القالب الافتراضي لكشف الحساب التفصيلي';

    Alert.alert('تأكيد', title, [
      { text: 'إلغاء', style: 'cancel' },
      {
        text: 'استعادة',
        style: 'destructive',
        onPress: () => {
          const defaultValue = DEFAULT_WHATSAPP_TEMPLATES[key];
          setTemplates((prev) => ({
            ...prev,
            [key]: defaultValue,
          }));
          setSelections((prev) => ({
            ...prev,
            [key]: {
              start: defaultValue.length,
              end: defaultValue.length,
            },
          }));
        },
      },
    ]);
  }

  function handlePreview(key: TemplateKey) {
    const preview = generatePreviewMessage(templates[key], key);
    Alert.alert('معاينة الرسالة', preview);
  }

  if (isLoading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color="#2563EB" />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ChevronRight size={22} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>قوالب رسائل الواتساب</Text>
        <View style={styles.headerSpacer} />
      </View>

      <ScrollView
        style={styles.content}
        contentContainerStyle={styles.contentContainer}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.card}>
          <Text style={styles.cardTitle}>الرسالة السريعة</Text>
          <Text style={styles.cardSubtitle}>
            رسالة مختصرة تُرسل من صفحة العميل.
          </Text>

          <ArabicTemplateTokenBar
            items={accountToolbarItems}
            onInsert={(token) => handleInsertToken('account_statement', token)}
          />

          <TextInput
            style={styles.textArea}
            multiline
            textAlignVertical="top"
            value={templates.account_statement}
            onChangeText={(text) => updateTemplate('account_statement', text)}
            onFocus={() => setActiveTemplate('account_statement')}
            onSelectionChange={(event) =>
              handleSelectionChange('account_statement', event)
            }
            placeholder="اكتب القالب هنا"
            placeholderTextColor="#9CA3AF"
          />

          <Text style={styles.helperText}>
            اضغط على أي عنصر في الأعلى وسيُضاف مباشرة داخل النص.
          </Text>

          <View style={styles.actionRow}>
            <TouchableOpacity
              style={[styles.secondaryButton, styles.previewButton]}
              onPress={() => handlePreview('account_statement')}
            >
              <Eye size={16} color="#2563EB" />
              <Text style={[styles.secondaryButtonText, styles.previewButtonText]}>
                معاينة
              </Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={[styles.secondaryButton, styles.resetButton]}
              onPress={() => handleReset('account_statement')}
            >
              <RotateCcw size={16} color="#DC2626" />
              <Text style={[styles.secondaryButtonText, styles.resetButtonText]}>
                إعادة الافتراضي
              </Text>
            </TouchableOpacity>
          </View>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>كشف الحساب التفصيلي</Text>
          <Text style={styles.cardSubtitle}>
            رسالة مفصلة مع الأرصدة والحركات المالية.
          </Text>

          <ArabicTemplateTokenBar
            items={shareToolbarItems}
            onInsert={(token) => handleInsertToken('share_account', token)}
          />

          <TextInput
            style={styles.textAreaLarge}
            multiline
            textAlignVertical="top"
            value={templates.share_account}
            onChangeText={(text) => updateTemplate('share_account', text)}
            onFocus={() => setActiveTemplate('share_account')}
            onSelectionChange={(event) =>
              handleSelectionChange('share_account', event)
            }
            placeholder="اكتب القالب هنا"
            placeholderTextColor="#9CA3AF"
          />

          <Text style={styles.helperText}>
            يفضّل أن تضع عنوانًا قبل الحركات مثل: الحركات المالية
          </Text>

          <View style={styles.actionRow}>
            <TouchableOpacity
              style={[styles.secondaryButton, styles.previewButton]}
              onPress={() => handlePreview('share_account')}
            >
              <Eye size={16} color="#2563EB" />
              <Text style={[styles.secondaryButtonText, styles.previewButtonText]}>
                معاينة
              </Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={[styles.secondaryButton, styles.resetButton]}
              onPress={() => handleReset('share_account')}
            >
              <RotateCcw size={16} color="#DC2626" />
              <Text style={[styles.secondaryButtonText, styles.resetButtonText]}>
                إعادة الافتراضي
              </Text>
            </TouchableOpacity>
          </View>
        </View>

        <View style={styles.smallInfoCard}>
          <Text style={styles.smallInfoTitle}>ملاحظة</Text>
          <Text style={styles.smallInfoText}>
            الأرقام ستظهر بدون فواصل عشرية إلا إذا كان هناك كسر فعلي.
          </Text>
          <Text style={styles.smallInfoText}>
            مثال: 500 دولار بدل 500.00 دولار
          </Text>
        </View>
      </ScrollView>

      <View style={styles.footer}>
        <TouchableOpacity
          style={[styles.saveButton, isSaving && styles.saveButtonDisabled]}
          onPress={handleSave}
          disabled={isSaving}
        >
          {isSaving ? (
            <ActivityIndicator size="small" color="#FFFFFF" />
          ) : (
            <>
              <Save size={18} color="#FFFFFF" />
              <Text style={styles.saveButtonText}>حفظ</Text>
            </>
          )}
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F3F4F6',
  },
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#F3F4F6',
  },
  header: {
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingTop: 16,
    paddingBottom: 14,
    backgroundColor: '#FFFFFF',
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  backButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: '#F3F4F6',
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerTitle: {
    flex: 1,
    fontSize: 18,
    fontWeight: '700',
    color: '#111827',
    textAlign: 'center',
  },
  headerSpacer: {
    width: 40,
    height: 40,
  },
  content: {
    flex: 1,
  },
  contentContainer: {
    padding: 16,
    paddingBottom: 120,
  },
  card: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    padding: 16,
    marginBottom: 14,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  cardTitle: {
    fontSize: 18,
    fontWeight: '700',
    color: '#111827',
    textAlign: 'right',
    marginBottom: 6,
  },
  cardSubtitle: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'right',
    marginBottom: 14,
    lineHeight: 20,
  },
  textArea: {
    minHeight: 150,
    borderWidth: 1,
    borderColor: '#D1D5DB',
    borderRadius: 14,
    backgroundColor: '#FAFAFA',
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 16,
    color: '#111827',
    textAlign: 'right',
  },
  textAreaLarge: {
    minHeight: 220,
    borderWidth: 1,
    borderColor: '#D1D5DB',
    borderRadius: 14,
    backgroundColor: '#FAFAFA',
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 16,
    color: '#111827',
    textAlign: 'right',
  },
  helperText: {
    marginTop: 10,
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
  },
  actionRow: {
    flexDirection: 'row-reverse',
    marginTop: 14,
  },
  secondaryButton: {
    flex: 1,
    minHeight: 44,
    borderRadius: 12,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row-reverse',
  },
  previewButton: {
    borderColor: '#BFDBFE',
    backgroundColor: '#EFF6FF',
    marginLeft: 8,
  },
  resetButton: {
    borderColor: '#FECACA',
    backgroundColor: '#FEF2F2',
  },
  secondaryButtonText: {
    fontSize: 14,
    fontWeight: '600',
    marginRight: 6,
  },
  previewButtonText: {
    color: '#2563EB',
  },
  resetButtonText: {
    color: '#DC2626',
  },
  smallInfoCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    padding: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  smallInfoTitle: {
    fontSize: 16,
    fontWeight: '700',
    color: '#111827',
    textAlign: 'right',
    marginBottom: 8,
  },
  smallInfoText: {
    fontSize: 14,
    color: '#4B5563',
    textAlign: 'right',
    lineHeight: 22,
  },
  footer: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 18,
    backgroundColor: '#FFFFFF',
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
  },
  saveButton: {
    minHeight: 52,
    borderRadius: 16,
    backgroundColor: '#16A34A',
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row-reverse',
  },
  saveButtonDisabled: {
    opacity: 0.7,
  },
  saveButtonText: {
    color: '#FFFFFF',
    fontSize: 17,
    fontWeight: '700',
    marginRight: 8,
  },
});
