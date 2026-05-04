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
import { useAuth } from '@/contexts/AuthContext';
import { SearchUserResult } from '@/types/database';
import {
  generateRegularCustomerAccountNumber,
  isCustomerAccountNumberConflict,
} from '@/utils/customerAccountNumber';

type CustomerType = 'regular' | 'linked';

type FormDataState = {
  name: string;
  phone: string;
  email: string;
  address: string;
  notes: string;
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
        (user: SearchUserResult) => String(user.account_number ?? '').trim() === cleanedQuery,
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
    if (
      !editMode &&
      error &&
      typeof error === 'object' &&
      'code' in error &&
      (error as { code?: string }).code === '42883'
    ) {
      return 'يوجد خلل في دوال قاعدة البيانات الخاصة بتوليد رقم الحساب.\nبعد تطبيق آخر migrations ستعمل إضافة العميل المحلي بشكل طبيعي.';
    }

    return `حدث خطأ أثناء ${editMode ? 'تحديث' : 'إضافة'} العميل`;
  };

  const createRegularCustomer = async () => {
    const customerPayload = {
      name: formData.name.trim(),
      phone: formData.phone.trim(),
      email: formData.email.trim() || null,
      address: formData.address.trim() || null,
      notes: formData.notes.trim() || null,
      user_id: currentUser!.userId,
    };

    let lastError: unknown;

    for (let attempt = 0; attempt < 8; attempt += 1) {
      const { error } = await supabase.from('customers').insert([
        {
          ...customerPayload,
          account_number: generateRegularCustomerAccountNumber(),
        },
      ]);

      if (!error) {
        return;
      }

      if (!isCustomerAccountNumberConflict(error)) {
        throw error;
      }

      lastError = error;
    }

    throw lastError ?? new Error('Failed to generate a unique customer account number');
  };

  const notifyLinkedCustomerAdded = async (linkedUser: SearchUserResult) => {
    try {
      await supabase.rpc('notify_linked_customer_added', {
        p_owner_user_id: currentUser?.userId,
        p_linked_user_id: linkedUser.id,
        p_owner_name:
          (currentUser as any)?.fullName ||
          (currentUser as any)?.userName ||
          (currentUser as any)?.name ||
          'مستخدم',
        p_customer_name: formData.name.trim() || linkedUser.full_name || null,
      });
    } catch (notifyError) {
      console.error('Error creating linked-customer notification:', notifyError);
    }
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

        const result = data?.[0];

        if (result?.success) {
          await notifyLinkedCustomerAdded(selectedUser);

          Alert.alert('نجح', result.message, [
            {
              text: 'حسناً',
              onPress: () => router.back(),
            },
          ]);
        } else {
          Alert.alert('خطأ', result?.message || 'حدث خطأ أثناء ربط المستخدم');
        }
      } catch (error) {
        console.error('Error linking user:', error);
        Alert.alert('خطأ', 'حدث خطأ أثناء ربط المستخدم كعميل');
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
      Alert.alert('خطأ', getCustomerSaveErrorMessage(error, isEditMode));
    } finally {
      setIsLoading(false);
    }
  };

  if (isLoadingData) {
    return (
      <View style={styles.loadingContainer}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={22} color="#1F2937" />
        </TouchableOpacity>

        <ActivityIndicator size="large" color="#4F46E5" />
        <Text style={styles.loadingText}>{title}</Text>
        <Text style={styles.loadingSubtext}>جاري التحميل...</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <ArrowRight size={22} color="#1F2937" />
        </TouchableOpacity>

        <Text style={styles.headerTitle}>{title}</Text>

        <View style={styles.headerSpacer} />
      </View>

      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.contentContainer}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        {!isEditMode && (
          <View style={styles.typeSwitcherCard}>
            <Text style={styles.sectionTitle}>نوع العميل</Text>

            <View style={styles.typeButtonsRow}>
              <TouchableOpacity
                style={[
                  styles.typeButton,
                  customerType === 'regular' && styles.typeButtonActive,
                ]}
                onPress={switchToRegular}
                activeOpacity={0.85}
              >
                <User size={18} color={customerType === 'regular' ? '#FFFFFF' : '#4B5563'} />
                <Text
                  style={[
                    styles.typeButtonText,
                    customerType === 'regular' && styles.typeButtonTextActive,
                  ]}
                >
                  عميل عادي
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[
                  styles.typeButton,
                  customerType === 'linked' && styles.typeButtonActive,
                ]}
                onPress={switchToLinked}
                activeOpacity={0.85}
              >
                <LinkIcon size={18} color={customerType === 'linked' ? '#FFFFFF' : '#4B5563'} />
                <Text
                  style={[
                    styles.typeButtonText,
                    customerType === 'linked' && styles.typeButtonTextActive,
                  ]}
                >
                  ربط مستخدم
                </Text>
              </TouchableOpacity>
            </View>
          </View>
        )}

        {customerType === 'linked' && !isEditMode && (
          <View style={styles.card}>
            <Text style={styles.sectionTitle}>البحث برقم الحساب</Text>

            <View style={styles.searchBox}>
              <Search size={18} color="#6B7280" />
              <TextInput
                value={searchQuery}
                onChangeText={handleSearchQueryChange}
                placeholder={`أدخل رقم الحساب (${ACCOUNT_NUMBER_LENGTH} أرقام)`}
                keyboardType="number-pad"
                style={styles.searchInput}
                maxLength={ACCOUNT_NUMBER_LENGTH}
                textAlign="right"
              />
            </View>

            {isSearching ? (
              <View style={styles.inlineLoading}>
                <ActivityIndicator size="small" color="#4F46E5" />
                <Text style={styles.inlineLoadingText}>جاري البحث...</Text>
              </View>
            ) : null}

            {!isSearching && searchQuery.length > 0 && searchResults.length === 0 && !selectedUser ? (
              <View style={styles.emptySearchBox}>
                <Text style={styles.emptySearchText}>لم يتم العثور على مستخدم مطابق</Text>
              </View>
            ) : null}

            {searchResults.length > 0 && !selectedUser ? (
              <View style={styles.resultsList}>
                {searchResults.map((user) => (
                  <TouchableOpacity
                    key={user.id}
                    style={styles.resultItem}
                    onPress={() => handleSelectUser(user)}
                    activeOpacity={0.85}
                  >
                    <View style={styles.resultTextWrap}>
                      <Text style={styles.resultName}>{user.full_name || 'مستخدم'}</Text>
                      <Text style={styles.resultMeta}>
                        رقم الحساب: {user.account_number || '-'}
                      </Text>
                    </View>

                    <UserPlus size={18} color="#4F46E5" />
                  </TouchableOpacity>
                ))}
              </View>
            ) : null}

            {selectedUser ? (
              <View style={styles.selectedUserBox}>
                <Text style={styles.selectedUserTitle}>المستخدم المحدد</Text>
                <Text style={styles.selectedUserName}>{selectedUser.full_name || 'مستخدم'}</Text>
                <Text style={styles.selectedUserMeta}>
                  رقم الحساب: {selectedUser.account_number || '-'}
                </Text>

                <TouchableOpacity
                  style={styles.clearSelectionButton}
                  onPress={resetLinkedState}
                  activeOpacity={0.85}
                >
                  <Text style={styles.clearSelectionText}>إلغاء الاختيار</Text>
                </TouchableOpacity>
              </View>
            ) : null}
          </View>
        )}

        <View style={styles.card}>
          <Text style={styles.sectionTitle}>
            {customerType === 'linked' && !isEditMode ? 'بيانات الاسم الظاهر' : 'البيانات الأساسية'}
          </Text>

          <View style={styles.fieldGroup}>
            <Text style={styles.label}>الاسم</Text>
            <TextInput
              value={formData.name}
              onChangeText={(value) => updateField('name', value)}
              placeholder="أدخل الاسم"
              style={styles.input}
              textAlign="right"
            />
          </View>

          <View style={styles.fieldGroup}>
            <Text style={styles.label}>رقم الهاتف</Text>
            <TextInput
              value={formData.phone}
              onChangeText={(value) => updateField('phone', value)}
              placeholder="أدخل رقم الهاتف"
              keyboardType="phone-pad"
              style={styles.input}
              textAlign="right"
              editable={!(customerType === 'linked' && !isEditMode)}
            />
          </View>

          {!isEditMode && customerType === 'linked' ? (
            <Text style={styles.helperText}>
              عند ربط مستخدم، الاسم قابل للتخصيص، وسيتم استخدام بيانات الربط تلقائيًا.
            </Text>
          ) : null}
        </View>

        <View style={styles.card}>
          <TouchableOpacity
            style={styles.additionalHeader}
            onPress={() => setShowAdditionalFields((prev) => !prev)}
            activeOpacity={0.85}
          >
            <View style={styles.additionalHeaderLeft}>
              {showAdditionalFields ? (
                <ChevronUp size={18} color="#4B5563" />
              ) : (
                <ChevronDown size={18} color="#4B5563" />
              )}
            </View>

            <Text style={styles.sectionTitle}>بيانات إضافية</Text>
          </TouchableOpacity>

          {showAdditionalFields ? (
            <View style={styles.additionalContent}>
              <View style={styles.fieldGroup}>
                <Text style={styles.label}>البريد الإلكتروني</Text>
                <TextInput
                  value={formData.email}
                  onChangeText={(value) => updateField('email', value)}
                  placeholder="أدخل البريد الإلكتروني"
                  keyboardType="email-address"
                  autoCapitalize="none"
                  style={styles.input}
                  textAlign="right"
                />
              </View>

              <View style={styles.fieldGroup}>
                <Text style={styles.label}>العنوان</Text>
                <TextInput
                  value={formData.address}
                  onChangeText={(value) => updateField('address', value)}
                  placeholder="أدخل العنوان"
                  style={styles.input}
                  textAlign="right"
                />
              </View>

              <View style={styles.fieldGroup}>
                <Text style={styles.label}>ملاحظات</Text>
                <TextInput
                  value={formData.notes}
                  onChangeText={(value) => updateField('notes', value)}
                  placeholder="أدخل ملاحظات"
                  style={[styles.input, styles.textArea]}
                  textAlignVertical="top"
                  multiline
                />
              </View>
            </View>
          ) : null}
        </View>

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
            {isLoading
              ? 'جاري الحفظ...'
              : isEditMode
                ? 'حفظ التعديلات'
                : customerType === 'linked'
                  ? 'ربط المستخدم كعميل'
                  : 'إضافة العميل'}
          </Text>
        </TouchableOpacity>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F8FAFC',
  },

  loadingContainer: {
    flex: 1,
    backgroundColor: '#F8FAFC',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
  },

  loadingText: {
    marginTop: 16,
    fontSize: 18,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'center',
  },

  loadingSubtext: {
    marginTop: 6,
    fontSize: 13,
    color: '#6B7280',
    textAlign: 'center',
  },

  header: {
    paddingTop: 10,
    paddingHorizontal: 16,
    paddingBottom: 10,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'space-between',
    backgroundColor: '#FFFFFF',
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },

  backButton: {
    width: 40,
    height: 40,
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#F3F4F6',
  },

  headerTitle: {
    fontSize: 18,
    fontWeight: '900',
    color: '#111827',
  },

  headerSpacer: {
    width: 40,
  },

  scroll: {
    flex: 1,
  },

  contentContainer: {
    padding: 16,
    paddingBottom: 28,
  },

  typeSwitcherCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    padding: 16,
    marginBottom: 14,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },

  typeButtonsRow: {
    flexDirection: 'row-reverse',
    gap: 10,
    marginTop: 12,
  },

  typeButton: {
    flex: 1,
    height: 48,
    borderRadius: 14,
    backgroundColor: '#F3F4F6',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },

  typeButtonActive: {
    backgroundColor: '#4F46E5',
    borderColor: '#4F46E5',
  },

  typeButtonText: {
    fontSize: 14,
    fontWeight: '800',
    color: '#374151',
  },

  typeButtonTextActive: {
    color: '#FFFFFF',
  },

  card: {
    backgroundColor: '#FFFFFF',
    borderRadius: 18,
    padding: 16,
    marginBottom: 14,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },

  sectionTitle: {
    fontSize: 16,
    fontWeight: '900',
    color: '#111827',
    textAlign: 'right',
  },

  searchBox: {
    marginTop: 12,
    height: 50,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#D1D5DB',
    backgroundColor: '#F9FAFB',
    paddingHorizontal: 14,
    flexDirection: 'row-reverse',
    alignItems: 'center',
    gap: 10,
  },

  searchInput: {
    flex: 1,
    fontSize: 15,
    color: '#111827',
  },

  inlineLoading: {
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    paddingTop: 14,
  },

  inlineLoadingText: {
    fontSize: 13,
    color: '#6B7280',
  },

  emptySearchBox: {
    marginTop: 12,
    paddingVertical: 14,
    paddingHorizontal: 12,
    borderRadius: 14,
    backgroundColor: '#F9FAFB',
  },

  emptySearchText: {
    textAlign: 'center',
    color: '#6B7280',
    fontSize: 13,
    fontWeight: '600',
  },

  resultsList: {
    marginTop: 12,
    gap: 8,
  },

  resultItem: {
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 14,
    paddingVertical: 12,
    paddingHorizontal: 12,
    backgroundColor: '#F9FAFB',
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },

  resultTextWrap: {
    flex: 1,
    alignItems: 'flex-end',
  },

  resultName: {
    fontSize: 14,
    fontWeight: '800',
    color: '#111827',
    textAlign: 'right',
  },

  resultMeta: {
    marginTop: 4,
    fontSize: 12,
    color: '#6B7280',
    textAlign: 'right',
  },

  selectedUserBox: {
    marginTop: 14,
    borderWidth: 1,
    borderColor: '#C7D2FE',
    backgroundColor: '#EEF2FF',
    borderRadius: 16,
    padding: 14,
    alignItems: 'flex-end',
  },

  selectedUserTitle: {
    fontSize: 12,
    fontWeight: '700',
    color: '#4F46E5',
    marginBottom: 6,
  },

  selectedUserName: {
    fontSize: 16,
    fontWeight: '900',
    color: '#111827',
    textAlign: 'right',
  },

  selectedUserMeta: {
    marginTop: 4,
    fontSize: 12,
    color: '#4B5563',
    textAlign: 'right',
  },

  clearSelectionButton: {
    marginTop: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 12,
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#C7D2FE',
  },

  clearSelectionText: {
    fontSize: 12,
    fontWeight: '800',
    color: '#4F46E5',
  },

  fieldGroup: {
    marginTop: 12,
  },

  label: {
    fontSize: 13,
    fontWeight: '700',
    color: '#374151',
    textAlign: 'right',
    marginBottom: 8,
  },

  input: {
    minHeight: 48,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#D1D5DB',
    backgroundColor: '#F9FAFB',
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 15,
    color: '#111827',
  },

  textArea: {
    minHeight: 100,
  },

  helperText: {
    marginTop: 10,
    fontSize: 12,
    lineHeight: 18,
    color: '#6B7280',
    textAlign: 'right',
  },

  additionalHeader: {
    flexDirection: 'row-reverse',
    alignItems: 'center',
    justifyContent: 'space-between',
  },

  additionalHeaderLeft: {
    width: 24,
    alignItems: 'center',
  },

  additionalContent: {
    marginTop: 6,
  },

  submitButton: {
    height: 54,
    borderRadius: 16,
    backgroundColor: '#4F46E5',
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row-reverse',
    gap: 10,
    marginTop: 4,
  },

  submitButtonDisabled: {
    opacity: 0.75,
  },

  submitButtonText: {
    fontSize: 15,
    fontWeight: '900',
    color: '#FFFFFF',
  },
});