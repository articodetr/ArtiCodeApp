import { useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Dimensions,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowRight, ImageIcon, Save, Trash2, Upload } from 'lucide-react-native';
import { useAuth } from '@/contexts/AuthContext';
import { LetterheadPreview } from '@/components/LetterheadPreview';
import {
  DEFAULT_LETTERHEAD_SETTINGS,
  LetterheadSettings,
  deleteLetterheadLogo,
  getLetterheadSettings,
  normalizeLetterheadSettings,
  pickLetterheadLogoFromGallery,
  saveLetterheadSettings,
  uploadLetterheadLogo,
} from '@/services/letterheadService';

const screenWidth = Dimensions.get('window').width;
const previewWidth = Math.min(screenWidth - 32, 534);

export default function LetterheadSettingsScreen() {
  const router = useRouter();
  const { currentUser, settings: appSettings } = useAuth();

  const [letterhead, setLetterhead] = useState<LetterheadSettings>(
    normalizeLetterheadSettings({
      ...DEFAULT_LETTERHEAD_SETTINGS,
      business_name: appSettings?.shop_name || DEFAULT_LETTERHEAD_SETTINGS.business_name,
      english_name: 'Company Name',
      phone_number: appSettings?.shop_phone || '',
    })
  );
  const [savedLogoUrl, setSavedLogoUrl] = useState<string | null>(null);
  const [pendingLogoUri, setPendingLogoUri] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);

  const previewSettings = useMemo(
    () =>
      normalizeLetterheadSettings({
        ...letterhead,
        logo_url: pendingLogoUri || letterhead.logo_url,
      }),
    [letterhead, pendingLogoUri]
  );

  useEffect(() => {
    loadLetterhead();
  }, [currentUser?.userId]);

  const loadLetterhead = async () => {
    if (!currentUser?.userId) {
      setIsLoading(false);
      return;
    }

    try {
      setIsLoading(true);
      const data = await getLetterheadSettings(currentUser.userId);
      const next = normalizeLetterheadSettings({
        ...data,
        business_name:
          data.business_name === DEFAULT_LETTERHEAD_SETTINGS.business_name && appSettings?.shop_name
            ? appSettings.shop_name
            : data.business_name,
        phone_number: data.phone_number || appSettings?.shop_phone || '',
      });
      setLetterhead(next);
      setSavedLogoUrl(next.logo_url);
      setPendingLogoUri(null);
    } catch (error) {
      console.error('[LetterheadSettings] Load error:', error);
      Alert.alert('خطأ', error instanceof Error ? error.message : 'فشل تحميل إعدادات الترويسة');
    } finally {
      setIsLoading(false);
    }
  };

  const updateField = <K extends keyof LetterheadSettings>(key: K, value: LetterheadSettings[K]) => {
    setLetterhead((current) => ({ ...current, [key]: value }));
  };

  const handlePickLogo = async () => {
    try {
      const uri = await pickLetterheadLogoFromGallery();
      if (uri) {
        setPendingLogoUri(uri);
        updateField('show_logo', true);
      }
    } catch (error) {
      Alert.alert('خطأ', error instanceof Error ? error.message : 'فشل اختيار الشعار');
    }
  };

  const handleRemoveLogo = () => {
    Alert.alert('إزالة الشعار', 'سيتم إزالة الشعار من الترويسة بعد الضغط على حفظ. هل تريد المتابعة؟', [
      { text: 'إلغاء', style: 'cancel' },
      {
        text: 'إزالة',
        style: 'destructive',
        onPress: () => {
          setPendingLogoUri(null);
          updateField('logo_url', null);
          updateField('show_logo', false);
        },
      },
    ]);
  };

  const handleSave = async () => {
    if (!currentUser?.userId) {
      Alert.alert('خطأ', 'لم يتم العثور على المستخدم الحالي');
      return;
    }

    if (!letterhead.business_name.trim()) {
      Alert.alert('تنبيه', 'الرجاء إدخال الاسم العربي');
      return;
    }

    if (!letterhead.english_name.trim()) {
      Alert.alert('تنبيه', 'الرجاء إدخال الاسم الإنجليزي');
      return;
    }

    try {
      setIsSaving(true);
      let logoUrl = letterhead.logo_url;

      if (pendingLogoUri) {
        logoUrl = await uploadLetterheadLogo(pendingLogoUri, currentUser.userId);
      }

      const saved = await saveLetterheadSettings(currentUser.userId, {
        ...letterhead,
        logo_url: logoUrl,
      });

      if (savedLogoUrl && savedLogoUrl !== saved.logo_url) {
        await deleteLetterheadLogo(savedLogoUrl);
      }

      setLetterhead(saved);
      setSavedLogoUrl(saved.logo_url);
      setPendingLogoUri(null);
      Alert.alert('تم الحفظ', 'تم حفظ الترويسة بنجاح');
    } catch (error) {
      console.error('[LetterheadSettings] Save error:', error);
      Alert.alert('خطأ', error instanceof Error ? error.message : 'فشل حفظ إعدادات الترويسة');
    } finally {
      setIsSaving(false);
    }
  };

  if (isLoading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color="#111111" />
        <Text style={styles.loadingText}>جاري تحميل إعدادات الترويسة...</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111111" />
        </TouchableOpacity>
        <View style={styles.headerTextBox}>
          <Text style={styles.headerTitle}>ترويسة السندات</Text>
          <Text style={styles.headerSubtitle}>يمين عربي، وسط شعار، يسار إنجليزي</Text>
        </View>
      </View>

      <ScrollView style={styles.content} contentContainerStyle={styles.contentContainer}>
        <View style={styles.previewCard}>
          <Text style={styles.sectionTitle}>المعاينة</Text>
          <Text style={styles.sectionSubtitle}>الشعار في الوسط بحجم أكبر وترويسة أحادية اللون</Text>
          <LetterheadPreview settings={previewSettings} previewWidth={previewWidth} showSizeLabel />
        </View>

        <View style={styles.card}>
          <Text style={styles.sectionTitle}>البيانات العربية</Text>

          <View style={styles.inputGroup}>
            <Text style={styles.inputLabel}>الاسم العربي</Text>
            <TextInput
              value={letterhead.business_name}
              onChangeText={(value) => updateField('business_name', value)}
              placeholder="اسم الشركة"
              style={styles.input}
              textAlign="right"
            />
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.inputLabel}>الهاتف</Text>
            <TextInput
              value={letterhead.phone_number}
              onChangeText={(value) => updateField('phone_number', value)}
              placeholder="+90 500 000 0000"
              keyboardType="phone-pad"
              style={styles.input}
              textAlign="right"
            />
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.inputLabel}>العنوان العربي</Text>
            <TextInput
              value={letterhead.address_ar}
              onChangeText={(value) => updateField('address_ar', value)}
              placeholder="إسطنبول - تركيا"
              style={styles.input}
              textAlign="right"
            />
          </View>
        </View>

        <View style={styles.card}>
          <Text style={styles.sectionTitle}>English side</Text>

          <View style={styles.inputGroup}>
            <Text style={styles.inputLabelLeft}>English name</Text>
            <TextInput
              value={letterhead.english_name}
              onChangeText={(value) => updateField('english_name', value)}
              placeholder="Company Name"
              style={[styles.input, styles.inputLeft]}
              textAlign="left"
            />
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.inputLabelLeft}>English address</Text>
            <TextInput
              value={letterhead.address_en}
              onChangeText={(value) => updateField('address_en', value)}
              placeholder="Istanbul - Türkiye"
              style={[styles.input, styles.inputLeft]}
              textAlign="left"
            />
          </View>
        </View>

        <View style={styles.card}>
          <View style={styles.cardHeaderRow}>
            <View style={styles.cardHeaderText}>
              <Text style={styles.sectionTitle}>الشعار</Text>
              <Text style={styles.sectionSubtitle}>يظهر في الوسط وبحجم أكبر</Text>
            </View>
            <ImageIcon size={24} color="#111111" />
          </View>

          <TouchableOpacity style={styles.uploadButton} onPress={handlePickLogo} disabled={isSaving}>
            <Upload size={20} color="#FFFFFF" />
            <Text style={styles.uploadButtonText}>اختيار شعار</Text>
          </TouchableOpacity>

          {(letterhead.logo_url || pendingLogoUri) && (
            <TouchableOpacity style={styles.removeButton} onPress={handleRemoveLogo} disabled={isSaving}>
              <Trash2 size={18} color="#111111" />
              <Text style={styles.removeButtonText}>إزالة الشعار</Text>
            </TouchableOpacity>
          )}

          <View style={styles.switchRow}>
            <Text style={styles.switchLabel}>إظهار الشعار</Text>
            <Switch
              value={letterhead.show_logo}
              onValueChange={(value) => updateField('show_logo', value)}
              trackColor={{ false: '#D1D5DB', true: '#D1D5DB' }}
              thumbColor="#111111"
            />
          </View>

          <View style={styles.switchRow}>
            <Text style={styles.switchLabel}>إظهار الهاتف</Text>
            <Switch
              value={letterhead.show_phone}
              onValueChange={(value) => updateField('show_phone', value)}
              trackColor={{ false: '#D1D5DB', true: '#D1D5DB' }}
              thumbColor="#111111"
            />
          </View>
        </View>

        <TouchableOpacity style={styles.saveButton} onPress={handleSave} disabled={isSaving}>
          {isSaving ? <ActivityIndicator color="#FFFFFF" /> : <Save size={20} color="#FFFFFF" />}
          <Text style={styles.saveButtonText}>{isSaving ? 'جاري الحفظ...' : 'حفظ الترويسة'}</Text>
        </TouchableOpacity>
      </ScrollView>
    </View>
  );
}

const cardShadow = {
  shadowColor: '#000',
  shadowOffset: { width: 0, height: 2 },
  shadowOpacity: 0.05,
  shadowRadius: 8,
  elevation: 2,
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F5F5F5',
  },
  loadingContainer: {
    flex: 1,
    backgroundColor: '#F5F5F5',
    alignItems: 'center',
    justifyContent: 'center',
  },
  loadingText: {
    marginTop: 12,
    fontSize: 15,
    color: '#4B5563',
  },
  header: {
    backgroundColor: '#FFFFFF',
    paddingTop: 16,
    paddingHorizontal: 20,
    paddingBottom: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
    flexDirection: 'row',
    alignItems: 'center',
  },
  backButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: '#F3F4F6',
    alignItems: 'center',
    justifyContent: 'center',
    marginLeft: 12,
  },
  headerTextBox: {
    flex: 1,
    alignItems: 'flex-end',
  },
  headerTitle: {
    fontSize: 24,
    fontWeight: '800',
    color: '#111111',
    textAlign: 'right',
  },
  headerSubtitle: {
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
    marginTop: 2,
  },
  content: {
    flex: 1,
  },
  contentContainer: {
    padding: 16,
    paddingBottom: 32,
  },
  previewCard: {
    backgroundColor: '#FFFFFF',
    padding: 16,
    borderRadius: 18,
    marginBottom: 14,
    ...cardShadow,
  },
  card: {
    backgroundColor: '#FFFFFF',
    padding: 16,
    borderRadius: 18,
    marginBottom: 14,
    ...cardShadow,
  },
  cardHeaderRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 12,
  },
  cardHeaderText: {
    flex: 1,
    alignItems: 'flex-end',
    marginLeft: 10,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: '800',
    color: '#111111',
    textAlign: 'right',
    marginBottom: 4,
  },
  sectionSubtitle: {
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
    marginBottom: 14,
  },
  inputGroup: {
    marginBottom: 14,
  },
  inputLabel: {
    fontSize: 14,
    fontWeight: '700',
    color: '#374151',
    textAlign: 'right',
    marginBottom: 8,
  },
  inputLabelLeft: {
    fontSize: 14,
    fontWeight: '700',
    color: '#374151',
    textAlign: 'left',
    marginBottom: 8,
  },
  input: {
    backgroundColor: '#FAFAFA',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 16,
    color: '#111111',
    writingDirection: 'rtl',
  },
  inputLeft: {
    writingDirection: 'ltr',
  },
  uploadButton: {
    backgroundColor: '#111111',
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 8,
  },
  uploadButtonText: {
    fontSize: 16,
    fontWeight: '800',
    color: '#FFFFFF',
  },
  removeButton: {
    marginTop: 12,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#D1D5DB',
    paddingVertical: 12,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 8,
    backgroundColor: '#FFFFFF',
  },
  removeButtonText: {
    fontSize: 15,
    fontWeight: '700',
    color: '#111111',
  },
  switchRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 14,
    borderTopWidth: 1,
    borderTopColor: '#F3F4F6',
    marginTop: 8,
  },
  switchLabel: {
    fontSize: 15,
    fontWeight: '700',
    color: '#374151',
  },
  saveButton: {
    backgroundColor: '#111111',
    borderRadius: 14,
    minHeight: 54,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 10,
    marginTop: 4,
  },
  saveButtonText: {
    fontSize: 16,
    fontWeight: '800',
    color: '#FFFFFF',
  },
});