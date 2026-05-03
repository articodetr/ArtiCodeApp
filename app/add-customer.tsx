import { useEffect, useMemo, useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TextInput,
  TouchableOpacity,
  Alert,
  ActivityIndicator,
  ScrollView,
} from 'react-native';
import { useRouter, useLocalSearchParams } from 'expo-router';
import {
  ArrowRight,
  Save,
  Search,
  UserPlus,
  User,
  Link as LinkIcon,
  ChevronDown,
  ChevronUp,
} from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import { KeyboardAwareView } from '@/components/KeyboardAwareView';
import { useAuth } from '@/contexts/AuthContext';
import { SearchUserResult } from '@/types/database';
import {
  generateRegularCustomerAccountNumber,
  isCustomerAccountNumberConflict,
} from '@/utils/customerAccountNumber';
import { isCustomerLimitReachedMessage } from '@/utils/subscriptionUpgradeRequest';
import { SubscriptionLimitUpgradeModal } from '@/components/SubscriptionLimitUpgradeModal';

type CustomerType = 'regular' | 'linked';

type FormDataState = {
  name: string;
  phone: string;
  email: string;
  address: string;
  notes: string;
};

type CustomerLimitError = Error & {
  isCustomerLimitReached?: boolean;
  customerCount?: number | null;
  customerLimit?: number | null;
};

const EMPTY_FORM: FormDataState = {
  name: '',
  phone: '',
  email: '',
  address: '',
  notes: '',
};

const ACCOUNT_NUMBER_LENGTH = 7;

export default function AddCustomerScreen() {
  const router = useRouter();
  const params = useLocalSearchParams();
  const rawId = params.id;
  const customerId = Array.isArray(rawId) ? rawId[0] : rawId;
  const { currentUser } = useAuth();

  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingData, setIsLoadingData] = useState(!!customerId);
  const [isEditMode] = useState(!!customerId);
  const [customerType, setCustomerType] = useState<CustomerType>('regular');
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState<SearchUserResult[]>([]);
  const [isSearching, setIsSearching] = useState(false);
  const [selectedUser, setSelectedUser] = useState<SearchUserResult | null>(null);
  const [showAdditionalFields, setShowAdditionalFields] = useState(false);
  const [formData, setFormData] = useState<FormDataState>(EMPTY_FORM);
  const [limitUpgradeModal, setLimitUpgradeModal] = useState<{
    visible: boolean;
    quota: {
      customerCount?: number | null;
      customerLimit?: number | null;
      customer_count?: number | null;
      customer_limit?: number | null;
      message?: string | null;
    } | null;
  }>({ visible: false, quota: null });

  useEffect(() => {
    if (customerId) {
      loadCustomerData();
    }
  }, [customerId]);

  const title = useMemo(() => {
    return isEditMode ? 'تعديل العميل' : 'إضافة عميل جديد';
  }, [isEditMode]);

  const updateField = (key: keyof FormDataState, value: string) => {
    setFormData((prev) => ({ ...prev, [key]: value }));
  };

  const resetLinkedState = () => {
    setSelectedUser(null);
    setSearchQuery('');
    setSearchResults([]);
  };

  const switchToRegular = () => {
    setCustomerType('regular');
    resetLinkedState();
  };

  const switchToLinked = () => {
    setCustomerType('linked');
    setFormData((prev) => ({
      ...EMPTY_FORM,
      name: prev.name,
    }));
  };

  const loadCustomerData = async () => {
    try {
      setIsLoadingData(true);

      const { data, error } = await supabase
        .from('customers')
        .select('*')
        .eq('id', customerId)
        .maybeSingle();

      if (error || !data) {
        Alert.alert('خطأ', 'لم يتم العثور على العميل');
        router.back();
        return;
      }

      setFormData({
        name: data.name || '',
        phone: data.phone || '',
        email: data.email || '',
        address: data.address || '',
        notes: data.notes || '',
      });

      if (data.email || data.address || data.notes) {
        setShowAdditionalFields(true);
      }
    } catch (error) {
      console.error('Error loading customer:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء تحميل البيانات');
    } finally {
      setIsLoadingData(false);
    }
  };

  const searchUsers = async (query: string) => {
    const cleanedQuery = query.replace(/\D/g, '').trim();

    if (!cleanedQuery) {
      setSearchResults([]);
      setIsSearching(false);
      return;
    }

    setIsSearching(true);

    try {
      const { data, error } = await supabase.rpc('search_users_by_account_number', {
        p_account_number: cleanedQuery,
        p_current_user_id: currentUser?.userId,
      });

      if (error) throw error;

      const exactResults = (data || []).filter(
        (user: SearchUserResult) =>
          String(user.account_number ?? '').trim() === cleanedQuery
      );

      setSearchResults(exactResults);
    } catch (error) {
      console.error('Error searching users:', error);
      Alert.alert('خطأ', 'حدث خطأ أثناء البحث');
    } finally {
      setIsSearching(false);
    }
  };

  const handleSearchQueryChange = (text: string) => {
    const cleanedText = text.replace(/\D/g, '');

    setSearchQuery(cleanedText);
    setSelectedUser(null);

    if (cleanedText) {
      searchUsers(cleanedText);
    } else {
      setSearchResults([]);
      setIsSearching(false);
    }
  };

  const handleSelectUser = (user: SearchUserResult) => {
    if (user.is_already_linked) {
      Alert.alert('تنبيه', 'هذا المستخدم مربوط بالفعل في قائمة عملائك');
      return;
    }

    setSelectedUser(user);
    setFormData((prev) => ({
      ...prev,
      name: user.full_name || '',
    }));
    setSearchResults([]);
    setSearchQuery(user.account_number || '');
  };

  const getCustomerSaveErrorMessage = (error: unknown, editMode: boolean) => {
    if (error && typeof error === 'object') {
      const typed = error as { code?: string; message?: string; details?: string; hint?: string };
      const message = typed.message || typed.details || typed.hint || '';

      if (isCustomerLimitReachedMessage(message)) {
        return 'لقد بلغت الحد الأقصى المسموح لك من العملاء/المستخدمين. يرجى اختيار اشتراك شهري أو سنوي لإضافة المزيد.';
      }

      if (!editMode && typed.code === '42883') {
        return 'يوجد خلل في دوال قاعدة البيانات الخاصة بالاشتراكات وإضافة العملاء. طبق آخر migrations ثم حاول مرة أخرى.';
      }
    }

    return `حدث خطأ أثناء ${editMode ? 'تحديث' : 'إضافة'} العميل`;
  };

  const handleCustomerLimitReached = (errorOrResult?: unknown) => {
    const info = (errorOrResult || {}) as {
      customerCount?: number | null;
      customerLimit?: number | null;
      customer_count?: number | null;
      customer_limit?: number | null;
      message?: string | null;
    };

    setLimitUpgradeModal({
      visible: true,
      quota: {
        customerCount: info.customerCount ?? info.customer_count ?? null,
        customerLimit: info.customerLimit ?? info.customer_limit ?? null,
        message: info.message ?? null,
      },
    });
  };

  const createRegularCustomer = async () => {
    let lastError: unknown;

    for (let attempt = 0; attempt < 8; attempt += 1) {
      const { data, error } = await supabase.rpc('create_regular_customer_with_quota_check', {
        p_user_id: currentUser!.userId,
        p_name: formData.name.trim(),
        p_phone: formData.phone.trim(),
        p_email: formData.email.trim() || null,
        p_address: formData.address.trim() || null,
        p_notes: formData.notes.trim() || null,
        p_account_number: generateRegularCustomerAccountNumber(),
      });

      if (!error) {
        const result = Array.isArray(data) ? data[0] : data;
        if (result?.success === false) {
          const resultMessage = result.message || 'تعذر إضافة العميل';
          const resultError = new Error(resultMessage) as CustomerLimitError;

          if (isCustomerLimitReachedMessage(resultMessage)) {
            resultError.isCustomerLimitReached = true;
            resultError.customerCount = result.customer_count ?? null;
            resultError.customerLimit = result.customer_limit ?? null;
          }

          throw resultError;
        }
        return;
      }

      if (!isCustomerAccountNumberConflict(error)) {
        throw error;
      }

      lastError = error;
    }

    throw lastError ?? new Error('Failed to generate a unique customer account number');
  };

  const handleSubmit = async () => {
    if (!currentUser?.userId) {
      Alert.alert('خطأ', 'يجب تسجيل الدخول أولاً');
      return;
    }

    if (customerType === 'linked' && !isEditMode) {
      if (!selectedUser) {
        Alert.alert('خطأ', 'الرجاء اختيار مستخدم من نتائج البحث');
        return;
      }

      setIsLoading(true);

      try {
        const { data, error } = await supabase.rpc('create_linked_customer', {
          p_owner_user_id: currentUser.userId,
          p_linked_user_id: selectedUser.id,
          p_customer_name: formData.name.trim() || selectedUser.full_name,
        });

        if (error) throw error;

        const result = Array.isArray(data) ? data[0] : data;

        if (result?.success) {
          Alert.alert('نجح', result.message, [
            {
              text: 'حسناً',
              onPress: () => router.back(),
            },
          ]);
        } else if (isCustomerLimitReachedMessage(result?.message)) {
          handleCustomerLimitReached(result);
        } else {
          Alert.alert('خطأ', result?.message || 'حدث خطأ أثناء ربط المستخدم');
        }
      } catch (error) {
        console.error('Error linking user:', error);
        const message =
          error && typeof error === 'object'
            ? (error as { message?: string; details?: string; hint?: string }).message ||
              (error as { message?: string; details?: string; hint?: string }).details ||
              (error as { message?: string; details?: string; hint?: string }).hint
            : String(error || '');

        if (isCustomerLimitReachedMessage(message)) {
          handleCustomerLimitReached(error);
          return;
        }

        Alert.alert('خطأ', getCustomerSaveErrorMessage(error, false));
      } finally {
        setIsLoading(false);
      }

      return;
    }

    if (!formData.name.trim() || !formData.phone.trim()) {
      Alert.alert('خطأ', 'الرجاء إدخال الاسم ورقم الهاتف');
      return;
    }

    setIsLoading(true);

    try {
      if (isEditMode && customerId) {
        const { error } = await supabase
          .from('customers')
          .update({
            name: formData.name.trim(),
            phone: formData.phone.trim(),
            email: formData.email.trim() || null,
            address: formData.address.trim() || null,
            notes: formData.notes.trim() || null,
          })
          .eq('id', customerId);

        if (error) throw error;

        Alert.alert('نجح', 'تم تحديث بيانات العميل بنجاح', [
          {
            text: 'حسناً',
            onPress: () => router.back(),
          },
        ]);
      } else {
        await createRegularCustomer();
        Alert.alert('نجح', 'تم إضافة العميل بنجاح', [
          {
            text: 'حسناً',
            onPress: () => router.back(),
          },
        ]);
      }
    } catch (error) {
      console.error('Error saving customer:', error);

      const limitError = error as CustomerLimitError;
      const limitMessage =
        error && typeof error === 'object'
          ? (error as { message?: string; details?: string; hint?: string }).message ||
            (error as { message?: string; details?: string; hint?: string }).details ||
            (error as { message?: string; details?: string; hint?: string }).hint
          : String(error || '');

      if (!isEditMode && (limitError.isCustomerLimitReached || isCustomerLimitReachedMessage(limitMessage))) {
        handleCustomerLimitReached(limitError);
        return;
      }

      Alert.alert('خطأ', getCustomerSaveErrorMessage(error, isEditMode));
    } finally {
      setIsLoading(false);
    }
  };

  if (isLoadingData) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
            <ArrowRight size={24} color="#111827" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>{title}</Text>
          <View style={styles.headerSpacer} />
        </View>

        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color="#4F46E5" />
          <Text style={styles.loadingText}>جاري التحميل...</Text>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>{title}</Text>
        <View style={styles.headerSpacer} />
      </View>

      <KeyboardAwareView style={styles.keyboardView}>
        <ScrollView
          style={styles.content}
          contentContainerStyle={styles.contentContainer}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
        >
          {!isEditMode && (
            <View style={styles.sectionCard}>
              <Text style={styles.sectionTitle}>نوع العميل</Text>
              <Text style={styles.sectionHint}>اختر الطريقة المناسبة لإضافة العميل</Text>

              <View style={styles.segmentedControl}>
                <TouchableOpacity
                  style={[
                    styles.segmentButton,
                    customerType === 'regular' && styles.segmentButtonActive,
                  ]}
                  onPress={switchToRegular}
                  activeOpacity={0.85}
                >
                  <UserPlus
                    size={16}
                    color={customerType === 'regular' ? '#FFFFFF' : '#6B7280'}
                  />
                  <Text
                    style={[
                      styles.segmentButtonText,
                      customerType === 'regular' && styles.segmentButtonTextActive,
                    ]}
                  >
                    عميل محلي
                  </Text>
                </TouchableOpacity>

                <TouchableOpacity
                  style={[
                    styles.segmentButton,
                    customerType === 'linked' && styles.segmentButtonActive,
                  ]}
                  onPress={switchToLinked}
                  activeOpacity={0.85}
                >
                  <LinkIcon
                    size={16}
                    color={customerType === 'linked' ? '#FFFFFF' : '#6B7280'}
                  />
                  <Text
                    style={[
                      styles.segmentButtonText,
                      customerType === 'linked' && styles.segmentButtonTextActive,
                    ]}
                  >
                    ربط مستخدم
                  </Text>
                </TouchableOpacity>
              </View>
            </View>
          )}

          {!isEditMode && customerType === 'linked' && (
            <View style={styles.sectionCard}>
              <Text style={styles.sectionTitle}>ربط مستخدم موجود</Text>
              <Text style={styles.sectionHint}>ابحث برقم الحساب ثم اختر المستخدم المناسب</Text>

              <View style={styles.searchInputShell}>
                <Search size={18} color="#9CA3AF" />
                <TextInput
                  style={styles.searchInput}
                  value={searchQuery}
                  onChangeText={handleSearchQueryChange}
                  placeholder="أدخل رقم الحساب كاملًا"
                  placeholderTextColor="#9CA3AF"
                  textAlign="right"
          />
                {isSearching ? (
                  <ActivityIndicator size="small" color="#4F46E5" />
                ) : null}
              </View>

              {searchResults.length > 0 && (
                <View style={styles.resultsList}>
                  {searchResults.map((user, index) => (
                    <TouchableOpacity
                      key={user.id || `${user.account_number}-${index}`}
                      style={[
                        styles.resultItem,
                        user.is_already_linked && styles.resultItemDisabled,
                      ]}
                      onPress={() => handleSelectUser(user)}
                      disabled={!!user.is_already_linked}
                      activeOpacity={0.85}
                    >
                      <View style={styles.resultTextWrap}>
                        <Text style={styles.resultName}>{user.full_name}</Text>
                        <Text style={styles.resultMeta}>رقم الحساب: {user.account_number}</Text>
                        {user.is_already_linked ? (
                          <Text style={styles.resultWarning}>مربوط بالفعل</Text>
                        ) : null}
                      </View>
                      <View style={styles.resultAvatar}>
                        <User size={16} color="#6366F1" />
                      </View>
                    </TouchableOpacity>
                  ))}
                </View>
              )}

              {selectedUser && (
                <View style={styles.selectedUserCard}>
                  <View style={styles.selectedUserBadge}>
                    <LinkIcon size={14} color="#4F46E5" />
                  </View>
                  <View style={styles.selectedUserTextWrap}>
                    <Text style={styles.selectedUserLabel}>تم اختيار المستخدم</Text>
                    <Text style={styles.selectedUserName}>{selectedUser.full_name}</Text>
                    <Text style={styles.selectedUserMeta}>
                      رقم الحساب: {selectedUser.account_number}
                    </Text>
                  </View>
                </View>
              )}
            </View>
          )}

          {(isEditMode || customerType === 'regular' || selectedUser) && (
            <View style={styles.sectionCard}>
              <Text style={styles.sectionTitle}>البيانات الأساسية</Text>
              <Text style={styles.sectionHint}>الحقول المهمة أولًا لتكون الإضافة أسرع وأسهل</Text>

              <View style={styles.inputGroup}>
                <Text style={styles.label}>
                  الاسم <Text style={styles.required}>*</Text>
                </Text>
                <TextInput
                  style={styles.input}
                  value={formData.name}
                  onChangeText={(text) => updateField('name', text)}
                  placeholder={
                    customerType === 'linked' && !isEditMode
                      ? 'اسم العرض اختياري، وسيُستخدم اسم المستخدم تلقائيًا'
                      : 'أدخل اسم العميل'
                  }
                  placeholderTextColor="#9CA3AF"
                  textAlign="right"
                  editable={customerType === 'regular' || isEditMode || !!selectedUser}
                />
              </View>

              {(isEditMode || customerType === 'regular') && (
                <View style={styles.inputGroup}>
                  <Text style={styles.label}>
                    رقم الهاتف <Text style={styles.required}>*</Text>
                  </Text>
                  <TextInput
                    style={styles.input}
                    value={formData.phone}
                    onChangeText={(text) => updateField('phone', text)}
                    placeholder="أدخل رقم الهاتف"
                    placeholderTextColor="#9CA3AF"
                    keyboardType="phone-pad"
                    textAlign="right"
                  />
                </View>
              )}
            </View>
          )}

          {(isEditMode || customerType === 'regular') && (
            <View style={styles.sectionCard}>
              <TouchableOpacity
                style={styles.optionalHeader}
                onPress={() => setShowAdditionalFields((prev) => !prev)}
                activeOpacity={0.85}
              >
                <View style={styles.optionalHeaderTextWrap}>
                  <Text style={styles.sectionTitle}>معلومات إضافية</Text>
                  <Text style={styles.sectionHint}>البريد والعنوان والملاحظات عند الحاجة فقط</Text>
                </View>
                <View style={styles.optionalHeaderIconWrap}>
                  {showAdditionalFields ? (
                    <ChevronUp size={18} color="#6B7280" />
                  ) : (
                    <ChevronDown size={18} color="#6B7280" />
                  )}
                </View>
              </TouchableOpacity>

              {showAdditionalFields && (
                <>
                  <View style={styles.inputGroup}>
                    <Text style={styles.label}>البريد الإلكتروني</Text>
                    <TextInput
                      style={styles.input}
                      value={formData.email}
                      onChangeText={(text) => updateField('email', text)}
                      placeholder="أدخل البريد الإلكتروني"
                      placeholderTextColor="#9CA3AF"
                      keyboardType="email-address"
                      autoCapitalize="none"
                      textAlign="right"
                    />
                  </View>

                  <View style={styles.inputGroup}>
                    <Text style={styles.label}>العنوان</Text>
                    <TextInput
                      style={styles.input}
                      value={formData.address}
                      onChangeText={(text) => updateField('address', text)}
                      placeholder="أدخل العنوان"
                      placeholderTextColor="#9CA3AF"
                      textAlign="right"
                    />
                  </View>

                  <View style={styles.inputGroupLast}>
                    <Text style={styles.label}>ملاحظات</Text>
                    <TextInput
                      style={[styles.input, styles.textArea]}
                      value={formData.notes}
                      onChangeText={(text) => updateField('notes', text)}
                      placeholder="أدخل ملاحظات إضافية"
                      placeholderTextColor="#9CA3AF"
                      multiline
                      numberOfLines={4}
                      textAlign="right"
                      textAlignVertical="top"
                    />
                  </View>
                </>
              )}
            </View>
          )}

          <TouchableOpacity
            style={[styles.submitButton, isLoading && styles.submitButtonDisabled]}
            onPress={handleSubmit}
            disabled={isLoading}
            activeOpacity={0.9}
          >
            {isLoading ? (
              <ActivityIndicator size="small" color="#FFFFFF" />
            ) : (
              <Save size={18} color="#FFFFFF" />
            )}
            <Text style={styles.submitButtonText}>
              {isLoading ? 'جاري الحفظ...' : isEditMode ? 'حفظ التعديلات' : 'حفظ العميل'}
            </Text>
          </TouchableOpacity>
        </ScrollView>
      </KeyboardAwareView>

      <SubscriptionLimitUpgradeModal
        visible={limitUpgradeModal.visible}
        currentUser={currentUser}
        quota={limitUpgradeModal.quota}
        onClose={() => setLimitUpgradeModal({ visible: false, quota: null })}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F8FAFC',
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
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#F8FAFC',
  },
  headerTitle: {
    fontSize: 20,
    fontWeight: '800',
    color: '#111827',
  },
  headerSpacer: {
    width: 40,
    height: 40,
  },
  keyboardView: {
    flex: 1,
  },
  content: {
    flex: 1,
  },
  contentContainer: {
    padding: 16,
    paddingBottom: 36,
    gap: 14,
  },
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    gap: 12,
  },
  loadingText: {
    fontSize: 15,
    color: '#6B7280',
  },
  sectionCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 20,
    padding: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    shadowColor: '#0F172A',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.04,
    shadowRadius: 10,
    elevation: 2,
  },
  sectionTitle: {
    fontSize: 17,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'right',
  },
  sectionHint: {
    marginTop: 6,
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
    lineHeight: 20,
  },
  segmentedControl: {
    marginTop: 14,
    flexDirection: 'row-reverse',
    backgroundColor: '#F3F4F6',
    borderRadius: 16,
    padding: 4,
    gap: 6,
  },
  segmentButton: {
    flex: 1,
    minHeight: 48,
    borderRadius: 12,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },
  segmentButtonActive: {
    backgroundColor: '#4F46E5',
  },
  segmentButtonText: {
    fontSize: 14,
    fontWeight: '700',
    color: '#6B7280',
  },
  segmentButtonTextActive: {
    color: '#FFFFFF',
  },
  searchInputShell: {
    marginTop: 14,
    minHeight: 52,
    borderRadius: 16,
    backgroundColor: '#F8FAFC',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    paddingHorizontal: 14,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  searchInput: {
    flex: 1,
    fontSize: 15,
    color: '#111827',
    paddingVertical: 12,
  },
  resultsList: {
    marginTop: 12,
    gap: 10,
  },
  resultItem: {
    backgroundColor: '#F8FAFC',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 12,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    gap: 12,
  },
  resultItemDisabled: {
    opacity: 0.55,
  },
  resultTextWrap: {
    flex: 1,
  },
  resultName: {
    fontSize: 15,
    fontWeight: '700',
    color: '#111827',
    textAlign: 'right',
  },
  resultMeta: {
    marginTop: 4,
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
  },
  resultWarning: {
    marginTop: 4,
    fontSize: 12,
    color: '#DC2626',
    textAlign: 'right',
  },
  resultAvatar: {
    width: 38,
    height: 38,
    borderRadius: 19,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#EEF2FF',
  },
  selectedUserCard: {
    marginTop: 14,
    backgroundColor: '#EEF2FF',
    borderRadius: 18,
    padding: 14,
    borderWidth: 1,
    borderColor: '#C7D2FE',
    flexDirection: 'row-reverse',
    alignItems: 'center',
    gap: 12,
  },
  selectedUserBadge: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#FFFFFF',
  },
  selectedUserTextWrap: {
    flex: 1,
  },
  selectedUserLabel: {
    fontSize: 12,
    fontWeight: '700',
    color: '#4F46E5',
    textAlign: 'right',
  },
  selectedUserName: {
    marginTop: 4,
    fontSize: 15,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'right',
  },
  selectedUserMeta: {
    marginTop: 4,
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'right',
  },
  inputGroup: {
    marginTop: 14,
  },
  inputGroupLast: {
    marginTop: 14,
  },
  label: {
    fontSize: 14,
    fontWeight: '700',
    color: '#374151',
    marginBottom: 8,
    textAlign: 'right',
  },
  required: {
    color: '#DC2626',
  },
  input: {
    backgroundColor: '#F8FAFC',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 16,
    paddingHorizontal: 14,
    paddingVertical: 14,
    fontSize: 15,
    color: '#111827',
  },
  textArea: {
    minHeight: 110,
    paddingTop: 14,
  },
  optionalHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  optionalHeaderTextWrap: {
    flex: 1,
  },
  optionalHeaderIconWrap: {
    width: 34,
    height: 34,
    borderRadius: 17,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#F8FAFC',
    marginLeft: 12,
  },
  submitButton: {
    minHeight: 54,
    backgroundColor: '#4F46E5',
    borderRadius: 18,
    paddingHorizontal: 18,
    flexDirection: 'row-reverse',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 10,
    marginTop: 2,
  },
  submitButtonDisabled: {
    opacity: 0.7,
  },
  submitButtonText: {
    fontSize: 17,
    fontWeight: '800',
    color: '#FFFFFF',
  },
});
