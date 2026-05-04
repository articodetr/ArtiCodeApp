import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Modal,
  TextInput,
  FlatList,
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
} from 'react-native';
import { Store, User, Search, X } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { supabase } from '@/lib/supabase';
import { Customer } from '@/types/database';
import { useAuth } from '@/contexts/AuthContext';
import { CustomerStatusBadge } from '@/components/customer/CustomerStatusBadge';
import { sortCustomersByDisplayPriority } from '@/utils/customerDisplay';
import { buildScopedCustomerFilter } from '@/services/userScopeService';

interface PartySelectorProps {
  label: string;
  selectedType: 'shop' | 'customer' | null;
  selectedCustomerId?: string;
  selectedCustomerName?: string;
  onSelect: (type: 'shop' | 'customer', customerId?: string, customerName?: string, accountNumber?: string) => void;
  excludeCustomerId?: string;
}

export default function PartySelector({
  label,
  selectedType,
  selectedCustomerId,
  selectedCustomerName,
  onSelect,
  excludeCustomerId,
}: PartySelectorProps) {
  const { currentUser } = useAuth();
  const insets = useSafeAreaInsets();
  const [showModal, setShowModal] = useState(false);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [filteredCustomers, setFilteredCustomers] = useState<Customer[]>([]);
  const [searchQuery, setSearchQuery] = useState('');
  const [loading, setLoading] = useState(false);
  const selectedCustomer =
    selectedType === 'customer'
      ? customers.find((customer) => customer.id === selectedCustomerId)
      : undefined;

  useEffect(() => {
    if (showModal) {
      loadCustomers();
    }
  }, [showModal]);

  useEffect(() => {
    if (searchQuery.trim() === '') {
      setFilteredCustomers(customers);
    } else {
      const filtered = customers.filter(
        (customer) =>
          customer.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
          customer.phone.includes(searchQuery) ||
          customer.account_number.includes(searchQuery)
      );
      setFilteredCustomers(filtered);
    }
  }, [searchQuery, customers]);

  const loadCustomers = async () => {
    setLoading(true);
    try {
      // التحقق من وجود المستخدم الحالي
      if (!currentUser?.userId) {
        console.warn('[PartySelector] No current user found');
        setCustomers([]);
        setFilteredCustomers([]);
        setLoading(false);
        return;
      }

      const { data, error } = await supabase
        .from('customers')
        .select('*')
        .or(buildScopedCustomerFilter(currentUser.userId, true))
        .order('name');

      if (error) {
        console.error('Supabase error:', error);
        throw error;
      }

      console.log('Loaded customers:', data?.length || 0);
      const filteredData = data?.filter(c => c.id !== excludeCustomerId) || [];
      console.log('Filtered customers:', filteredData.length);
      const sortedData = sortCustomersByDisplayPriority(filteredData);
      setCustomers(sortedData);
      setFilteredCustomers(sortedData);
    } catch (error) {
      console.error('Error loading customers:', error);
    } finally {
      setLoading(false);
    }
  };

  const handleSelectShop = () => {
    onSelect('shop');
    setShowModal(false);
  };

  const handleSelectCustomer = (customer: Customer) => {
    onSelect('customer', customer.id, customer.name, customer.account_number);
    setShowModal(false);
  };

  const getDisplayText = () => {
    if (!selectedType) return 'اختر الطرف';
    if (selectedType === 'shop') return 'المحل (حسابي)';
    return selectedCustomerName || 'عميل';
  };

  const getDisplayIcon = () => {
    if (!selectedType) return null;
    if (selectedType === 'shop') {
      return <Store size={20} color="#10B981" />;
    }
    return <User size={20} color="#3B82F6" />;
  };

  return (
    <View style={styles.container}>
      <Text style={styles.label}>{label}</Text>

      <TouchableOpacity
        style={[
          styles.selectButton,
          selectedType && styles.selectButtonActive,
        ]}
        onPress={() => setShowModal(true)}
      >
        <View style={styles.selectButtonContent}>
          {getDisplayIcon()}
          {selectedType === 'customer' ? (
            <View style={styles.selectedCustomerInfo}>
              <View style={styles.selectedCustomerHeader}>
                <CustomerStatusBadge customer={selectedCustomer} />
                <Text
                  style={[
                    styles.selectButtonText,
                    selectedType && styles.selectButtonTextActive,
                  ]}
                >
                  {getDisplayText()}
                </Text>
              </View>
              {selectedCustomer?.account_number ? (
                <Text style={styles.selectedCustomerSubtext}>
                  رقم الحساب: {selectedCustomer.account_number}
                </Text>
              ) : null}
            </View>
          ) : (
            <Text
              style={[
                styles.selectButtonText,
                selectedType && styles.selectButtonTextActive,
              ]}
            >
              {getDisplayText()}
            </Text>
          )}
        </View>
      </TouchableOpacity>

      <Modal
        visible={showModal}
        animationType="slide"
        transparent={true}
        onRequestClose={() => setShowModal(false)}
      >
        <KeyboardAvoidingView
          style={styles.modalOverlay}
          behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
          keyboardVerticalOffset={Platform.OS === 'ios' ? insets.top : 0}
        >
          <View
            style={[
              styles.modalContent,
              { paddingBottom: Math.max(insets.bottom, 16) },
            ]}
          >
            <View style={styles.modalHeader}>
              <Text style={styles.modalTitle}>اختر {label}</Text>
              <TouchableOpacity
                onPress={() => setShowModal(false)}
                style={styles.closeButton}
              >
                <X size={24} color="#6B7280" />
              </TouchableOpacity>
            </View>

            <TouchableOpacity
              style={styles.shopOption}
              onPress={handleSelectShop}
            >
              <Store size={24} color="#10B981" />
              <View style={styles.shopOptionText}>
                <Text style={styles.shopOptionName}>المحل (حسابي)</Text>
                <Text style={styles.shopOptionDescription}>
                  حساب المحل الرئيسي
                </Text>
              </View>
            </TouchableOpacity>

            <View style={styles.divider} />

            <View style={styles.searchContainer}>
              <Search size={20} color="#9CA3AF" />
              <TextInput
                style={styles.searchInput}
                placeholder="ابحث عن عميل..."
                value={searchQuery}
                onChangeText={setSearchQuery}
                placeholderTextColor="#9CA3AF"
              />
            </View>

            {loading ? (
              <View style={styles.loadingContainer}>
                <ActivityIndicator size="large" color="#3B82F6" />
              </View>
            ) : (
              <FlatList
                data={filteredCustomers}
                keyExtractor={(item) => item.id}
                renderItem={({ item }) => (
                  <TouchableOpacity
                    style={styles.customerItem}
                    onPress={() => handleSelectCustomer(item)}
                  >
                    <User size={20} color="#3B82F6" />
                    <View style={styles.customerInfo}>
                      <View style={styles.customerHeader}>
                        <CustomerStatusBadge customer={item} />
                        <Text style={styles.customerName}>{item.name}</Text>
                      </View>
                      <Text style={styles.customerDetails}>
                        {item.account_number} • {item.phone}
                      </Text>
                    </View>
                  </TouchableOpacity>
                )}
                ListEmptyComponent={
                  <View style={styles.emptyContainer}>
                    <Text style={styles.emptyText}>
                      {searchQuery ? 'لا توجد نتائج' : 'لا يوجد عملاء'}
                    </Text>
                  </View>
                }
                style={styles.customerList}
                contentContainerStyle={[
                  styles.customerListContent,
                  { paddingBottom: Math.max(insets.bottom + 12, 20) },
                ]}
                keyboardShouldPersistTaps="handled"
              />
            )}
          </View>
        </KeyboardAvoidingView>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    marginBottom: 20,
  },
  label: {
    fontSize: 16,
    fontWeight: '600',
    color: '#1F2937',
    marginBottom: 8,
    textAlign: 'right',
  },
  selectButton: {
    backgroundColor: '#F3F4F6',
    padding: 16,
    borderRadius: 12,
    borderWidth: 2,
    borderColor: '#E5E7EB',
  },
  selectButtonActive: {
    borderColor: '#3B82F6',
    backgroundColor: '#EFF6FF',
  },
  selectButtonContent: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'flex-end',
    gap: 8,
  },
  selectedCustomerInfo: {
    flex: 1,
    alignItems: 'flex-end',
  },
  selectedCustomerHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  selectButtonText: {
    fontSize: 16,
    color: '#9CA3AF',
    textAlign: 'right',
  },
  selectButtonTextActive: {
    color: '#1F2937',
    fontWeight: '700',
  },
  selectedCustomerSubtext: {
    marginTop: 6,
    fontSize: 12,
    color: '#64748B',
    textAlign: 'right',
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
    paddingTop: 20,
    maxHeight: '80%',
  },
  modalHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 20,
    paddingBottom: 16,
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#1F2937',
  },
  closeButton: {
    padding: 4,
  },
  shopOption: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 16,
    marginHorizontal: 20,
    backgroundColor: '#ECFDF5',
    borderRadius: 12,
    gap: 12,
  },
  shopOptionText: {
    flex: 1,
    alignItems: 'flex-end',
  },
  shopOptionName: {
    fontSize: 16,
    fontWeight: '600',
    color: '#065F46',
  },
  shopOptionDescription: {
    fontSize: 14,
    color: '#059669',
    marginTop: 2,
  },
  divider: {
    height: 1,
    backgroundColor: '#E5E7EB',
    marginVertical: 16,
  },
  searchContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#F3F4F6',
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 12,
    marginHorizontal: 20,
    marginBottom: 16,
    gap: 8,
  },
  searchInput: {
    flex: 1,
    fontSize: 16,
    color: '#1F2937',
    textAlign: 'right',
  },
  loadingContainer: {
    padding: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  customerList: {
    flex: 1,
  },
  customerListContent: {
    flexGrow: 1,
  },
  customerItem: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 16,
    marginHorizontal: 20,
    marginBottom: 8,
    backgroundColor: '#F9FAFB',
    borderRadius: 12,
    gap: 12,
  },
  customerInfo: {
    flex: 1,
    alignItems: 'flex-end',
  },
  customerHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginBottom: 4,
  },
  customerName: {
    fontSize: 16,
    fontWeight: '700',
    color: '#1F2937',
    textAlign: 'right',
  },
  customerDetails: {
    fontSize: 14,
    color: '#6B7280',
    marginTop: 2,
  },
  emptyContainer: {
    padding: 40,
    alignItems: 'center',
  },
  emptyText: {
    fontSize: 16,
    color: '#9CA3AF',
  },
});
