import { useEffect, useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  TextInput,
  Alert,
  ActivityIndicator,
  Image,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { ArrowRight, Image as ImageIcon, Save, Upload, Palette } from 'lucide-react-native';
import { LinearGradient } from 'expo-linear-gradient';

import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { Customer } from '@/types/database';
import { buildReadableCustomerFilter } from '@/services/userScopeService';
import {
  CustomerReceiptHeaderMode,
  CUSTOMER_HEADER_BANNER_WIDTH,
  CUSTOMER_HEADER_BANNER_HEIGHT,
  pickCustomerHeaderBannerFile,
  pickCustomerHeaderLogo,
  uploadCustomerHeaderAsset,
} from '@/services/customerHeaderService';
import { clearLogoCache } from '@/utils/logoHelper';

const THEMES = [
  { primary: '#0F766E', secondary: '#115E59', text: '#FFFFFF' },
  { primary: '#1D4ED8', secondary: '#1E3A8A', text: '#FFFFFF' },
  { primary: '#7C3AED', secondary: '#4C1D95', text: '#FFFFFF' },
  { primary: '#B45309', secondary: '#78350F', text: '#FFFFFF' },
];

export default function CustomerHeaderSettingsScreen() {
  const router = useRouter();
  const params = useLocalSearchParams();
  const customerId = Array.isArray(params.customerId) ? params.customerId[0] : String(params.customerId || '');
  const customerNameParam = Array.isArray(params.customerName) ? params.customerName[0] : String(params.customerName || '');

  const { currentUser } = useAuth();

  const [customer, setCustomer] = useState<Customer | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  const [mode, setMode] = useState<CustomerReceiptHeaderMode>('default');
  const [bannerUri, setBannerUri] = useState<string | null>(null);
  const [logoUri, setLogoUri] = useState<string | null>(null);

  const [leftTitle, setLeftTitle] = useState('');
  const [leftSubtitle, setLeftSubtitle] = useState('');
  const [rightTitle, setRightTitle] = useState('');
  const [rightSubtitle, setRightSubtitle] = useState('');

  const [primaryColor, setPrimaryColor] = useState('#0F766E');
  const [secondaryColor, setSecondaryColor] = useState('#115E59');
  const [textColor, setTextColor] = useState('#FFFFFF');

  useEffect(() => {
    if (!customerId) {
      Alert.alert('خطأ', 'يجب اختيار عميل أولاً قبل فتح ترويسة العميل');
      router.back();
      return;
    }

    loadCustomer();
  }, [customerId, currentUser?.userId]);

  const loadCustomer = async () => {
    try {
      if (!customerId || !currentUser?.userId) return;

      setLoading(true);

      const { data, error } = await supabase
        .from('customers')
        .select('*')
        .eq('id', customerId)
        .or(buildReadableCustomerFilter(currentUser.userId, true))
        .maybeSingle();

      if (error || !data) {
        Alert.alert('خطأ', 'لم يتم العثور على العميل');
        router.back();
        return;
      }

      setCustomer(data);
      setMode((data.receipt_header_mode as CustomerReceiptHeaderMode) || 'default');

      setLeftTitle(data.receipt_header_left_title || data.name || '');
      setLeftSubtitle(data.receipt_header_left_subtitle || data.phone || '');
      setRightTitle(
        data.receipt_header_right_title || (data.account_number ? `رقم الحساب: ${data.account_number}` : '')
      );
      setRightSubtitle(data.receipt_header_right_subtitle || '');

      setPrimaryColor(data.receipt_header_primary_color || '#0F766E');
      setSecondaryColor(data.receipt_header_secondary_color || '#115E59');
      setTextColor(data.receipt_header_text_color || '#FFFFFF');
    } catch {
      Alert.alert('خطأ', 'حدث خطأ أثناء تحميل بيانات الترويسة');
    } finally {
      setLoading(false);
    }
  };

  const applyTheme = (theme: { primary: string; secondary: string; text: string }) => {
    setPrimaryColor(theme.primary);
    setSecondaryColor(theme.secondary);
    setTextColor(theme.text);
  };

  const handlePickBanner = async () => {
    try {
      const picked = await pickCustomerHeaderBannerFile();
      if (picked) {
        setBannerUri(picked);
      }
    } catch (error) {
      Alert.alert(
        'مقاس غير صحيح',
        error instanceof Error ? error.message : 'تعذر اختيار البانر'
      );
    }
  };

  const handlePickLogo = async () => {
    try {
      const picked = await pickCustomerHeaderLogo();
      if (picked) {
        setLogoUri(picked);
      }
    } catch (error) {
      Alert.alert('خطأ', error instanceof Error ? error.message : 'تعذر اختيار الشعار');
    }
  };

  const handleSave = async () => {
    try {
      if (!customerId) {
        throw new Error('يجب اختيار عميل أولاً قبل حفظ الترويسة');
      }

      if (!customer) {
        throw new Error('لم يتم تحميل بيانات العميل بعد');
      }

      if (!currentUser?.userId) {
        throw new Error('لم يتم العثور على بيانات الحساب الحالي');
      }

      setSaving(true);

      let uploadedBannerUrl = customer.receipt_header_banner_url || null;
      let uploadedLogoUrl = customer.receipt_header_logo_url || null;

      if (mode === 'full_banner') {
        if (bannerUri) {
          const result = await uploadCustomerHeaderAsset(bannerUri, 'customer-banners', customer.id);
          if (!result.success || !result.url) {
            throw new Error(result.error || 'فشل رفع البانر');
          }
          uploadedBannerUrl = result.url;
        }

        if (!uploadedBannerUrl) {
          throw new Error('يجب رفع بانر كامل أولاً');
        }
      }

      if (mode === 'generated') {
        if (logoUri) {
          const result = await uploadCustomerHeaderAsset(logoUri, 'customer-logos', customer.id);
          if (!result.success || !result.url) {
            throw new Error(result.error || 'فشل رفع الشعار');
          }
          uploadedLogoUrl = result.url;
        }

        if (!uploadedLogoUrl) {
          throw new Error('يجب رفع شعار الوسط أولاً');
        }
      }

      const payload: Partial<Customer> = {
        receipt_header_mode: mode,
        receipt_header_banner_url: mode === 'full_banner' ? uploadedBannerUrl : customer.receipt_header_banner_url || null,
        receipt_header_logo_url: mode === 'generated' ? uploadedLogoUrl : customer.receipt_header_logo_url || null,
        receipt_header_left_title: leftTitle.trim() || null,
        receipt_header_left_subtitle: leftSubtitle.trim() || null,
        receipt_header_right_title: rightTitle.trim() || null,
        receipt_header_right_subtitle: rightSubtitle.trim() || null,
        receipt_header_primary_color: primaryColor.trim() || '#0F766E',
        receipt_header_secondary_color: secondaryColor.trim() || '#115E59',
        receipt_header_text_color: textColor.trim() || '#FFFFFF',
      };

      const { data: updatedCustomer, error } = await supabase
      .from('customers')
      .update(payload)
      .eq('id', customer.id)
      .or(buildReadableCustomerFilter(currentUser.userId, true))
      .select('id')
      .maybeSingle();

    if (error) {
      throw error;
    }

    if (!updatedCustomer) {
      throw new Error('لا تملك صلاحية حفظ ترويسة هذا العميل من هذا الحساب');
    }

      if (error) {
        throw error;
      }

      await clearLogoCache();

      Alert.alert('نجح', 'تم حفظ ترويسة العميل بنجاح', [
        { text: 'حسناً', onPress: () => router.back() },
      ]);
    } catch (error) {
      Alert.alert('خطأ', error instanceof Error ? error.message : 'فشل حفظ الترويسة');
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return (
      <View style={styles.loadingWrap}>
        <ActivityIndicator size="large" color="#059669" />
        <Text style={styles.loadingText}>جاري تحميل إعدادات الترويسة...</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <LinearGradient colors={['#059669', '#10B981', '#34D399']} style={styles.header}>
        <TouchableOpacity onPress={() => router.back()} style={styles.backButton}>
          <ArrowRight size={24} color="#FFFFFF" />
        </TouchableOpacity>

        <Text style={styles.headerTitle}>ترويسة العميل</Text>
        <View style={{ width: 40 }} />
      </LinearGradient>

      <ScrollView contentContainerStyle={styles.content}>
        <View style={styles.card}>
          <Text style={styles.cardTitle}>العميل</Text>
          <Text style={styles.customerName}>{customer?.name || customerNameParam}</Text>
          <Text style={styles.helperText}>
            الترويسة الافتراضية الحالية ستبقى مستخدمة إذا تركت الوضع على "افتراضي".
          </Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>نوع الترويسة</Text>

          <TouchableOpacity
            style={[styles.modeButton, mode === 'default' && styles.modeButtonActive]}
            onPress={() => setMode('default')}
          >
            <Text style={[styles.modeButtonText, mode === 'default' && styles.modeButtonTextActive]}>
              الترويسة الافتراضية
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[styles.modeButton, mode === 'full_banner' && styles.modeButtonActive]}
            onPress={() => setMode('full_banner')}
          >
            <Text style={[styles.modeButtonText, mode === 'full_banner' && styles.modeButtonTextActive]}>
              بنر كامل مرفوع
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[styles.modeButton, mode === 'generated' && styles.modeButtonActive]}
            onPress={() => setMode('generated')}
          >
            <Text style={[styles.modeButtonText, mode === 'generated' && styles.modeButtonTextActive]}>
              شعار في الوسط + نصوص + ألوان
            </Text>
          </TouchableOpacity>
        </View>

        {mode === 'full_banner' && (
          <View style={styles.card}>
            <Text style={styles.cardTitle}>رفع البانر الكامل</Text>
            <Text style={styles.helperText}>
              يجب أن يكون المقاس {CUSTOMER_HEADER_BANNER_WIDTH}×{CUSTOMER_HEADER_BANNER_HEIGHT} بكسل بالضبط.
            </Text>

            <TouchableOpacity style={styles.actionButton} onPress={handlePickBanner}>
              <Upload size={18} color="#FFFFFF" />
              <Text style={styles.actionButtonText}>اختيار ملف البانر</Text>
            </TouchableOpacity>

            <Text style={styles.statusText}>
              {bannerUri
                ? 'تم اختيار بانر جديد وجاهز للحفظ'
                : customer?.receipt_header_banner_url
                ? 'يوجد بانر محفوظ لهذا العميل'
                : 'لا يوجد بانر خاص محفوظ'}
            </Text>

            {!!(bannerUri || customer?.receipt_header_banner_url) && (
              <Image
                source={{ uri: bannerUri || customer?.receipt_header_banner_url || '' }}
                style={styles.bannerPreview}
                resizeMode="cover"
              />
            )}
          </View>
        )}

        {mode === 'generated' && (
          <View style={styles.card}>
            <Text style={styles.cardTitle}>الترويسة المولدة</Text>

            <TouchableOpacity style={styles.secondaryButton} onPress={handlePickLogo}>
              <ImageIcon size={18} color="#065F46" />
              <Text style={styles.secondaryButtonText}>اختيار شعار الوسط</Text>
            </TouchableOpacity>

            <Text style={styles.statusText}>
              {logoUri
                ? 'تم اختيار شعار جديد'
                : customer?.receipt_header_logo_url
                ? 'يوجد شعار محفوظ'
                : 'لا يوجد شعار محفوظ'}
            </Text>

            <TextInput
              style={styles.input}
              value={leftTitle}
              onChangeText={setLeftTitle}
              placeholder="النص الرئيسي في اليسار"
              textAlign="right"
            />
            <TextInput
              style={styles.input}
              value={leftSubtitle}
              onChangeText={setLeftSubtitle}
              placeholder="النص الفرعي في اليسار"
              textAlign="right"
            />
            <TextInput
              style={styles.input}
              value={rightTitle}
              onChangeText={setRightTitle}
              placeholder="النص الرئيسي في اليمين"
              textAlign="right"
            />
            <TextInput
              style={styles.input}
              value={rightSubtitle}
              onChangeText={setRightSubtitle}
              placeholder="النص الفرعي في اليمين"
              textAlign="right"
            />

            <View style={styles.paletteRow}>
              {THEMES.map((theme, index) => (
                <TouchableOpacity
                  key={index}
                  style={[styles.themeSwatch, { backgroundColor: theme.primary }]}
                  onPress={() => applyTheme(theme)}
                />
              ))}
            </View>

            <TextInput
              style={styles.input}
              value={primaryColor}
              onChangeText={setPrimaryColor}
              placeholder="#0F766E"
              textAlign="right"
            />
            <TextInput
              style={styles.input}
              value={secondaryColor}
              onChangeText={setSecondaryColor}
              placeholder="#115E59"
              textAlign="right"
            />
            <TextInput
              style={styles.input}
              value={textColor}
              onChangeText={setTextColor}
              placeholder="#FFFFFF"
              textAlign="right"
            />

            <View
              style={[
                styles.generatedPreviewBox,
                { backgroundColor: primaryColor || '#0F766E' },
              ]}
            >
              <Palette size={18} color={textColor || '#FFFFFF'} />
              <Text style={[styles.generatedPreviewText, { color: textColor || '#FFFFFF' }]}>
                ستُنشأ الترويسة تلقائيًا عند الطباعة
              </Text>
            </View>
          </View>
        )}

        <TouchableOpacity style={styles.saveButton} onPress={handleSave} disabled={saving}>
          {saving ? (
            <ActivityIndicator size="small" color="#FFFFFF" />
          ) : (
            <>
              <Save size={18} color="#FFFFFF" />
              <Text style={styles.saveButtonText}>حفظ الترويسة</Text>
            </>
          )}
        </TouchableOpacity>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  loadingWrap: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#F8FAFC',
  },
  loadingText: {
    marginTop: 12,
    fontSize: 16,
    color: '#334155',
  },
  container: {
    flex: 1,
    backgroundColor: '#F8FAFC',
  },
  header: {
    paddingTop: 56,
    paddingBottom: 20,
    paddingHorizontal: 16,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  backButton: {
    width: 40,
    alignItems: 'flex-start',
  },
  headerTitle: {
    fontSize: 20,
    fontWeight: '800',
    color: '#FFFFFF',
  },
  content: {
    padding: 16,
    gap: 14,
  },
  card: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    padding: 16,
    gap: 12,
    borderWidth: 1,
    borderColor: '#E2E8F0',
  },
  cardTitle: {
    fontSize: 17,
    fontWeight: '800',
    color: '#0F172A',
    textAlign: 'right',
  },
  customerName: {
    fontSize: 18,
    fontWeight: '700',
    color: '#065F46',
    textAlign: 'right',
  },
  helperText: {
    fontSize: 13,
    color: '#64748B',
    textAlign: 'right',
    lineHeight: 20,
  },
  modeButton: {
    borderWidth: 1,
    borderColor: '#CBD5E1',
    borderRadius: 14,
    paddingVertical: 12,
    paddingHorizontal: 14,
    backgroundColor: '#FFFFFF',
  },
  modeButtonActive: {
    backgroundColor: '#ECFDF5',
    borderColor: '#10B981',
  },
  modeButtonText: {
    fontSize: 15,
    color: '#0F172A',
    textAlign: 'right',
    fontWeight: '700',
  },
  modeButtonTextActive: {
    color: '#047857',
  },
  actionButton: {
    backgroundColor: '#059669',
    borderRadius: 14,
    paddingVertical: 12,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 8,
  },
  actionButtonText: {
    color: '#FFFFFF',
    fontWeight: '800',
    fontSize: 15,
  },
  secondaryButton: {
    backgroundColor: '#ECFDF5',
    borderRadius: 14,
    paddingVertical: 12,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 8,
    borderWidth: 1,
    borderColor: '#A7F3D0',
  },
  secondaryButtonText: {
    color: '#065F46',
    fontWeight: '800',
    fontSize: 15,
  },
  statusText: {
    fontSize: 13,
    color: '#475569',
    textAlign: 'right',
  },
  bannerPreview: {
    width: '100%',
    height: 90,
    borderRadius: 12,
    backgroundColor: '#E2E8F0',
  },
  input: {
    borderWidth: 1,
    borderColor: '#CBD5E1',
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 12,
    backgroundColor: '#FFFFFF',
    fontSize: 14,
    color: '#0F172A',
  },
  paletteRow: {
    flexDirection: 'row',
    gap: 10,
    justifyContent: 'flex-end',
  },
  themeSwatch: {
    width: 34,
    height: 34,
    borderRadius: 17,
    borderWidth: 2,
    borderColor: '#FFFFFF',
    elevation: 2,
  },
  generatedPreviewBox: {
    minHeight: 56,
    borderRadius: 14,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 8,
  },
  generatedPreviewText: {
    fontWeight: '700',
    fontSize: 14,
  },
  saveButton: {
    backgroundColor: '#0F172A',
    borderRadius: 16,
    paddingVertical: 14,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 8,
    marginTop: 4,
    marginBottom: 22,
  },
  saveButtonText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '800',
  },
});
