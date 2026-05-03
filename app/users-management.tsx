import React, { useState, useEffect, useCallback } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ScrollView,
  Alert,
  RefreshControl,
  Modal,
  TextInput,
  ActivityIndicator,
  Platform,
} from 'react-native';
import { KeyboardAwareView } from '@/components/KeyboardAwareView';
import { useRouter } from 'expo-router';
import {
  ArrowRight,
  Users,
  Plus,
  Trash2,
  Edit3,
  Shield,
  User,
  Lock,
  Check,
  X,
} from 'lucide-react-native';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import * as Crypto from 'expo-crypto';
import * as Haptics from 'expo-haptics';
import { format } from 'date-fns';

// Helper function for password hashing using expo-crypto
async function hashPassword(password: string): Promise<string> {
  try {
    // Generate a random salt
    const salt = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      Math.random().toString(36) + Date.now().toString()
    );

    // Hash password with salt
    const hash = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      password + salt.substring(0, 16)
    );

    // Combine salt and hash (salt:hash format)
    return salt.substring(0, 16) + ':' + hash;
  } catch (error) {
    console.error('[hashPassword] Error:', error);
    throw new Error('فشل في تشفير كلمة المرور');
  }
}

interface UserData {
  id: string;
  user_name: string;
  full_name: string;
  account_number: string;
  role: string;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  last_login: string | null;
}

export default function UsersManagement() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const [users, setUsers] = useState<UserData[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [addModalVisible, setAddModalVisible] = useState(false);
  const [editModalVisible, setEditModalVisible] = useState(false);
  const [selectedUser, setSelectedUser] = useState<UserData | null>(null);

  const [newFullName, setNewFullName] = useState('');
  const [newUserName, setNewUserName] = useState('');
  const [newPin, setNewPin] = useState('');
  const [newPinConfirm, setNewPinConfirm] = useState('');
  const [editPin, setEditPin] = useState('');
  const [editPinConfirm, setEditPinConfirm] = useState('');
  const [saving, setSaving] = useState(false);

  const isAdmin = currentUser?.role === 'admin';

  useEffect(() => {
    loadUsers();
  }, []);

  const loadUsers = async () => {
    try {
      let query = supabase.from('app_security').select('*');

      // إذا لم يكن المستخدم admin، يحمل فقط بياناته
      if (!isAdmin && currentUser) {
        query = query.eq('id', currentUser.userId);
      }

      const { data, error } = await query.order('created_at', { ascending: false });

      if (error) throw error;
      setUsers(data || []);
    } catch (error) {
      console.error('Error loading users:', error);
      Alert.alert('خطأ', 'فشل تحميل المستخدمين');
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    loadUsers();
  }, []);

  const hashPin = async (pin: string): Promise<string> => {
    return await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      pin
    );
  };

  const handleAddUser = async () => {
    // فقط الـ admin يستطيع إضافة مستخدمين
    if (!isAdmin) {
      Alert.alert('غير مصرح', 'ليس لديك صلاحية إضافة مستخدمين');
      return;
    }

    if (!newFullName.trim()) {
      Alert.alert('خطأ', 'الرجاء إدخال الاسم الكامل');
      return;
    }

    if (newFullName.trim().length < 2) {
      Alert.alert('خطأ', 'الاسم الكامل يجب أن يكون حرفين على الأقل');
      return;
    }

    if (!newUserName.trim()) {
      Alert.alert('خطأ', 'الرجاء إدخال اسم المستخدم');
      return;
    }

    if (newUserName.trim().length < 3) {
      Alert.alert('خطأ', 'اسم المستخدم يجب أن يكون 3 أحرف على الأقل');
      return;
    }

    if (newPin.length < 6 || newPin.length > 20) {
      Alert.alert('خطأ', 'كلمة المرور يجب أن تكون بين 6-20 حرف');
      return;
    }

    if (newPin !== newPinConfirm) {
      Alert.alert('خطأ', 'كلمة المرور غير متطابقة');
      return;
    }

    const userExists = users.some(
      (u) => u.user_name.toLowerCase() === newUserName.trim().toLowerCase()
    );
    if (userExists) {
      Alert.alert('خطأ', 'اسم المستخدم موجود بالفعل');
      return;
    }

    setSaving(true);
    try {
      const pinHash = await hashPassword(newPin);
      const { data: newUser, error } = await supabase
        .from('app_security')
        .insert({
          user_name: newUserName.trim(),
          full_name: newFullName.trim(),
          pin_hash: pinHash,
          role: 'user',
          is_active: true,
        })
        .select('account_number')
        .single();

      if (error) throw error;

      if (Platform.OS !== 'web') {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      }

      Alert.alert(
        'نجح',
        `تم إضافة المستخدم بنجاح\n\nرقم الحساب: ${newUser?.account_number}`
      );
      setAddModalVisible(false);
      setNewFullName('');
      setNewUserName('');
      setNewPin('');
      setNewPinConfirm('');
      await loadUsers();
    } catch (error) {
      console.error('Error adding user:', error);
      Alert.alert('خطأ', 'فشل إضافة المستخدم');
    } finally {
      setSaving(false);
    }
  };

  const handleEditPin = async () => {
    if (!selectedUser) return;

    if (editPin.length < 6 || editPin.length > 20) {
      Alert.alert('خطأ', 'كلمة المرور يجب أن تكون بين 6-20 حرف');
      return;
    }

    if (editPin !== editPinConfirm) {
      Alert.alert('خطأ', 'كلمة المرور غير متطابقة');
      return;
    }

    setSaving(true);
    try {
      const pinHash = await hashPassword(editPin);
      const { error } = await supabase
        .from('app_security')
        .update({ pin_hash: pinHash, updated_at: new Date().toISOString() })
        .eq('id', selectedUser.id);

      if (error) throw error;

      if (Platform.OS !== 'web') {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      }

      Alert.alert('نجح', 'تم تحديث كلمة المرور بنجاح');
      setEditModalVisible(false);
      setEditPin('');
      setEditPinConfirm('');
      setSelectedUser(null);
      await loadUsers();
    } catch (error) {
      console.error('Error updating password:', error);
      Alert.alert('خطأ', 'فشل تحديث كلمة المرور');
    } finally {
      setSaving(false);
    }
  };

  const handleDeleteUser = (user: UserData) => {
    // منع حذف Ali
    if (user.user_name.toLowerCase() === 'ali') {
      Alert.alert('غير مسموح', 'لا يمكن حذف حساب Ali - هذا هو الحساب الرئيسي');
      return;
    }

    // فقط الـ admin يستطيع حذف المستخدمين
    if (!isAdmin) {
      Alert.alert('غير مصرح', 'ليس لديك صلاحية حذف المستخدمين');
      return;
    }

    Alert.alert(
      'تأكيد الحذف',
      `هل أنت متأكد من حذف المستخدم "${user.user_name}"؟\n\nهذا الإجراء لا يمكن التراجع عنه.`,
      [
        { text: 'إلغاء', style: 'cancel' },
        {
          text: 'حذف',
          style: 'destructive',
          onPress: async () => {
            try {
              const { error } = await supabase
                .from('app_security')
                .delete()
                .eq('id', user.id);

              if (error) throw error;

              if (Platform.OS !== 'web') {
                Haptics.notificationAsync(
                  Haptics.NotificationFeedbackType.Success
                );
              }

              Alert.alert('نجح', 'تم حذف المستخدم بنجاح');
              await loadUsers();
            } catch (error) {
              console.error('Error deleting user:', error);
              Alert.alert('خطأ', 'فشل حذف المستخدم');
            }
          },
        },
      ]
    );
  };

  const openEditModal = (user: UserData) => {
    // التحقق من الصلاحية: المستخدم يمكنه تعديل كلمة السر الخاصة به فقط
    // أو إذا كان admin يستطيع تعديل الجميع
    if (!isAdmin && currentUser?.userId !== user.id) {
      Alert.alert('غير مصرح', 'يمكنك تغيير كلمة السر الخاصة بك فقط');
      return;
    }

    setSelectedUser(user);
    setEditModalVisible(true);
  };

  const renderAddUserModal = () => (
    <Modal
      visible={addModalVisible}
      transparent
      animationType="slide"
      onRequestClose={() => setAddModalVisible(false)}
    >
      <KeyboardAwareView
        contentContainerStyle={styles.modalOverlay}
        useScrollView={false}
        keyboardVerticalOffset={0}
      >
        <View style={styles.modalContent}>
          <View style={styles.modalHeader}>
            <TouchableOpacity
              onPress={() => setAddModalVisible(false)}
              style={styles.modalCloseButton}
            >
              <X size={24} color="#6B7280" />
            </TouchableOpacity>
            <Text style={styles.modalTitle}>إضافة مستخدم جديد</Text>
          </View>

          <View style={styles.modalBody}>
            <View style={styles.inputGroup}>
              <Text style={styles.label}>الاسم الكامل</Text>
              <View style={styles.inputContainer}>
                <User size={20} color="#6B7280" />
                <TextInput
                  style={styles.input}
                  placeholder="أدخل الاسم الكامل"
                  placeholderTextColor="#9CA3AF"
                  value={newFullName}
                  onChangeText={setNewFullName}
                  textAlign="right"
                  autoCapitalize="words"
                />
              </View>
            </View>

            <View style={styles.inputGroup}>
              <Text style={styles.label}>اسم المستخدم (3 أحرف على الأقل)</Text>
              <View style={styles.inputContainer}>
                <User size={20} color="#6B7280" />
                <TextInput
                  style={styles.input}
                  placeholder="أدخل اسم المستخدم"
                  placeholderTextColor="#9CA3AF"
                  value={newUserName}
                  onChangeText={setNewUserName}
                  textAlign="right"
                  autoCapitalize="none"
                />
              </View>
            </View>

            <View style={styles.inputGroup}>
              <Text style={styles.label}>كلمة المرور (6-20 حرف)</Text>
              <View style={styles.inputContainer}>
                <Lock size={20} color="#6B7280" />
                <TextInput
                  style={styles.input}
                  placeholder="********"
                  placeholderTextColor="#9CA3AF"
                  value={newPin}
                  onChangeText={setNewPin}
                  keyboardType="default"
                  maxLength={20}
                  secureTextEntry
                  textAlign="right"
                />
              </View>
            </View>

            <View style={styles.inputGroup}>
              <Text style={styles.label}>تأكيد كلمة المرور</Text>
              <View style={styles.inputContainer}>
                <Lock size={20} color="#6B7280" />
                <TextInput
                  style={styles.input}
                  placeholder="********"
                  placeholderTextColor="#9CA3AF"
                  value={newPinConfirm}
                  onChangeText={setNewPinConfirm}
                  keyboardType="default"
                  maxLength={20}
                  secureTextEntry
                  textAlign="right"
                />
              </View>
            </View>

            <View style={styles.modalButtons}>
              <TouchableOpacity
                style={[styles.modalButton, styles.modalButtonCancel]}
                onPress={() => setAddModalVisible(false)}
              >
                <Text style={styles.modalButtonCancelText}>إلغاء</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[
                  styles.modalButton,
                  styles.modalButtonConfirm,
                  saving && styles.buttonDisabled,
                ]}
                onPress={handleAddUser}
                disabled={saving}
              >
                {saving ? (
                  <ActivityIndicator color="#FFFFFF" />
                ) : (
                  <>
                    <Check size={20} color="#FFFFFF" />
                    <Text style={styles.modalButtonConfirmText}>إضافة</Text>
                  </>
                )}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </KeyboardAwareView>
    </Modal>
  );

  const renderEditPinModal = () => (
    <Modal
      visible={editModalVisible}
      transparent
      animationType="slide"
      onRequestClose={() => setEditModalVisible(false)}
    >
      <KeyboardAwareView
        contentContainerStyle={styles.modalOverlay}
        useScrollView={false}
        keyboardVerticalOffset={0}
      >
        <View style={styles.modalContent}>
          <View style={styles.modalHeader}>
            <TouchableOpacity
              onPress={() => setEditModalVisible(false)}
              style={styles.modalCloseButton}
            >
              <X size={24} color="#6B7280" />
            </TouchableOpacity>
            <Text style={styles.modalTitle}>
              تعديل كلمة المرور - {selectedUser?.user_name}
            </Text>
          </View>

          <View style={styles.modalBody}>
            <View style={styles.inputGroup}>
              <Text style={styles.label}>كلمة المرور الجديدة (6-20 حرف)</Text>
              <View style={styles.inputContainer}>
                <Lock size={20} color="#6B7280" />
                <TextInput
                  style={styles.input}
                  placeholder="********"
                  placeholderTextColor="#9CA3AF"
                  value={editPin}
                  onChangeText={setEditPin}
                  keyboardType="default"
                  maxLength={20}
                  secureTextEntry
                  textAlign="right"
                />
              </View>
            </View>

            <View style={styles.inputGroup}>
              <Text style={styles.label}>تأكيد كلمة المرور</Text>
              <View style={styles.inputContainer}>
                <Lock size={20} color="#6B7280" />
                <TextInput
                  style={styles.input}
                  placeholder="********"
                  placeholderTextColor="#9CA3AF"
                  value={editPinConfirm}
                  onChangeText={setEditPinConfirm}
                  keyboardType="default"
                  maxLength={20}
                  secureTextEntry
                  textAlign="right"
                />
              </View>
            </View>

            <View style={styles.modalButtons}>
              <TouchableOpacity
                style={[styles.modalButton, styles.modalButtonCancel]}
                onPress={() => setEditModalVisible(false)}
              >
                <Text style={styles.modalButtonCancelText}>إلغاء</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[
                  styles.modalButton,
                  styles.modalButtonConfirm,
                  saving && styles.buttonDisabled,
                ]}
                onPress={handleEditPin}
                disabled={saving}
              >
                {saving ? (
                  <ActivityIndicator color="#FFFFFF" />
                ) : (
                  <>
                    <Check size={20} color="#FFFFFF" />
                    <Text style={styles.modalButtonConfirmText}>حفظ</Text>
                  </>
                )}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </KeyboardAwareView>
    </Modal>
  );

  const renderUserCard = (user: UserData) => {
    const isAli = user.user_name.toLowerCase() === 'ali';
    const canDelete = isAdmin && !isAli;
    const isOwnAccount = currentUser?.userId === user.id;

    return (
      <View key={user.id} style={styles.userCard}>
        <View style={styles.userCardHeader}>
          <View style={styles.userIconContainer}>
            {user.role === 'admin' ? (
              <Shield size={24} color="#10B981" />
            ) : (
              <User size={24} color="#6B7280" />
            )}
          </View>
          <View style={styles.userInfo}>
            <View style={styles.userNameRow}>
              <Text style={styles.userName}>{user.full_name}</Text>
              {user.role === 'admin' && (
                <View style={styles.adminBadge}>
                  <Text style={styles.adminBadgeText}>مدير</Text>
                </View>
              )}
              {isOwnAccount && (
                <View style={[styles.adminBadge, { backgroundColor: '#3B82F6' }]}>
                  <Text style={styles.adminBadgeText}>أنت</Text>
                </View>
              )}
            </View>
            <Text style={styles.userSubtitle}>
              {user.user_name} • رقم الحساب: {user.account_number}
            </Text>
            <Text style={styles.userDate}>
              تاريخ الإنشاء: {format(new Date(user.created_at), 'yyyy/MM/dd')}
            </Text>
            {user.last_login && (
              <Text style={styles.userDate}>
                آخر دخول: {format(new Date(user.last_login), 'yyyy/MM/dd HH:mm')}
              </Text>
            )}
          </View>
        </View>

        <View style={styles.userActions}>
          <TouchableOpacity
            style={[
              styles.actionButton,
              styles.editButton,
              !canDelete && { flex: 1 },
            ]}
            onPress={() => openEditModal(user)}
          >
            <Edit3 size={18} color="#3B82F6" />
            <Text style={styles.editButtonText}>تعديل كلمة المرور</Text>
          </TouchableOpacity>
          {canDelete && (
            <TouchableOpacity
              style={[styles.actionButton, styles.deleteButton]}
              onPress={() => handleDeleteUser(user)}
            >
              <Trash2 size={18} color="#EF4444" />
              <Text style={styles.deleteButtonText}>حذف</Text>
            </TouchableOpacity>
          )}
        </View>
      </View>
    );
  };

  if (loading) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity onPress={() => router.back()} style={styles.backButton}>
            <ArrowRight size={24} color="#111827" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>إدارة المستخدمين</Text>
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
        <TouchableOpacity onPress={() => router.back()} style={styles.backButton}>
          <ArrowRight size={24} color="#111827" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>إدارة المستخدمين</Text>
      </View>

      <ScrollView
        style={styles.content}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
        }
      >
        <View style={styles.statsCard}>
          <Users size={32} color="#4F46E5" />
          <Text style={styles.statsNumber}>{users.length}</Text>
          <Text style={styles.statsLabel}>
            {isAdmin ? 'مستخدم مسجل' : 'حسابي'}
          </Text>
        </View>

        {isAdmin && (
          <TouchableOpacity
            style={styles.addButton}
            onPress={() => setAddModalVisible(true)}
          >
            <Plus size={20} color="#FFFFFF" />
            <Text style={styles.addButtonText}>إضافة مستخدم جديد</Text>
          </TouchableOpacity>
        )}

        {users.length === 0 ? (
          <View style={styles.emptyContainer}>
            <Users size={64} color="#D1D5DB" />
            <Text style={styles.emptyText}>لا يوجد مستخدمين</Text>
            <Text style={styles.emptySubtext}>
              اضغط على "إضافة مستخدم جديد" للبدء
            </Text>
          </View>
        ) : (
          <View style={styles.usersContainer}>
            {users.map(renderUserCard)}
          </View>
        )}
      </ScrollView>

      {renderAddUserModal()}
      {renderEditPinModal()}
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
    gap: 16,
  },
  loadingText: {
    fontSize: 16,
    color: '#6B7280',
  },
  content: {
    flex: 1,
  },
  statsCard: {
    backgroundColor: '#FFFFFF',
    margin: 16,
    padding: 24,
    borderRadius: 16,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  statsNumber: {
    fontSize: 48,
    fontWeight: 'bold',
    color: '#111827',
    marginTop: 12,
  },
  statsLabel: {
    fontSize: 16,
    color: '#6B7280',
    marginTop: 4,
  },
  addButton: {
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
    backgroundColor: '#4F46E5',
    marginHorizontal: 16,
    marginBottom: 16,
    paddingVertical: 16,
    borderRadius: 12,
  },
  addButtonText: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  usersContainer: {
    paddingHorizontal: 16,
    paddingBottom: 16,
  },
  userCard: {
    backgroundColor: '#FFFFFF',
    borderRadius: 16,
    padding: 16,
    marginBottom: 12,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 2,
  },
  userCardHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 16,
  },
  userIconContainer: {
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: '#F3F4F6',
    justifyContent: 'center',
    alignItems: 'center',
    marginLeft: 12,
  },
  userInfo: {
    flex: 1,
  },
  userNameRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginBottom: 4,
  },
  userName: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#111827',
  },
  userSubtitle: {
    fontSize: 14,
    color: '#6B7280',
    marginBottom: 4,
    textAlign: 'right',
  },
  adminBadge: {
    backgroundColor: '#10B981',
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 6,
  },
  adminBadgeText: {
    fontSize: 12,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  userDate: {
    fontSize: 14,
    color: '#6B7280',
    textAlign: 'right',
  },
  userActions: {
    flexDirection: 'row',
    gap: 8,
  },
  actionButton: {
    flex: 1,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 6,
    paddingVertical: 12,
    borderRadius: 8,
  },
  editButton: {
    backgroundColor: '#EFF6FF',
  },
  editButtonText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#3B82F6',
  },
  deleteButton: {
    backgroundColor: '#FEE2E2',
  },
  deleteButtonText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#EF4444',
  },
  emptyContainer: {
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 60,
  },
  emptyText: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
    marginTop: 16,
  },
  emptySubtext: {
    fontSize: 14,
    color: '#6B7280',
    marginTop: 8,
    textAlign: 'center',
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    justifyContent: 'flex-end',
  },
  modalContent: {
    backgroundColor: '#FFFFFF',
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    paddingBottom: 32,
  },
  modalHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 20,
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  modalCloseButton: {
    padding: 4,
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
    flex: 1,
    textAlign: 'right',
    marginRight: 12,
  },
  modalBody: {
    padding: 20,
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
  modalButtons: {
    flexDirection: 'row',
    gap: 12,
    marginTop: 8,
  },
  modalButton: {
    flex: 1,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 14,
    borderRadius: 12,
  },
  modalButtonCancel: {
    backgroundColor: '#F3F4F6',
  },
  modalButtonCancelText: {
    fontSize: 16,
    fontWeight: '600',
    color: '#6B7280',
  },
  modalButtonConfirm: {
    backgroundColor: '#4F46E5',
  },
  modalButtonConfirmText: {
    fontSize: 16,
    fontWeight: '600',
    color: '#FFFFFF',
  },
  buttonDisabled: {
    opacity: 0.6,
  },
});
