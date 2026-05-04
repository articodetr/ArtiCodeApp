import { useState, useEffect, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ScrollView,
  Alert,
  ActivityIndicator,
  Platform,
  Image,
} from 'react-native';
import { useRouter, useLocalSearchParams } from 'expo-router';
import { ArrowRight, Share2, Download, RefreshCw } from 'lucide-react-native';
import { WebView } from 'react-native-webview';
import * as Sharing from 'expo-sharing';
import * as Print from 'expo-print';
import * as FileSystem from 'expo-file-system/legacy';
import { captureRef } from 'react-native-view-shot';
import QRCode from 'react-native-qrcode-svg';
import { supabase } from '@/lib/supabase';
import { AccountMovement } from '@/types/database';
import { generateReceiptHTML, generateQRCodeData } from '@/utils/receiptGenerator';
import { getCustomerReceiptHeaderBase64 } from '@/utils/logoHelper';
import { useAuth } from '@/contexts/AuthContext';
import { fetchAccessibleCustomerById } from '@/services/userScopeService';

export default function ReceiptPreviewScreen() {
  const router = useRouter();
  const { currentUser } = useAuth();
  const { movementId, customerName, customerAccountNumber } = useLocalSearchParams();
  const [isLoading, setIsLoading] = useState(true);
  const [movement, setMovement] = useState<AccountMovement | null>(null);
  const [htmlContent, setHtmlContent] = useState<string>('');
  const [pdfUri, setPdfUri] = useState<string>('');
  const [isPdfReady, setIsPdfReady] = useState(false);
  const [isSharing, setIsSharing] = useState(false);
  const [isDownloading, setIsDownloading] = useState(false);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const qrRef = useRef<any>(null);

  useEffect(() => {
    if (movementId && currentUser?.userId) {
      loadMovement();
    }
  }, [movementId, currentUser?.userId]);

  const loadMovement = async () => {
    try {
      console.log('[ReceiptPreview] Loading movement with ID:', movementId);
      setIsLoading(true);

      if (!currentUser?.userId) {
        return;
      }

      const { data: movementData, error: movementError } = await supabase
        .from('account_movements')
        .select('*, customers!customer_id(name, account_number, phone, receipt_header_mode, receipt_header_banner_url, receipt_header_logo_url, receipt_header_left_title, receipt_header_left_subtitle, receipt_header_right_title, receipt_header_right_subtitle, receipt_header_primary_color, receipt_header_secondary_color, receipt_header_text_color), commission_recipient:customers!commission_recipient_id(name)')
        .eq('id', movementId)
        .maybeSingle();

      if (movementError) {
        console.error('[ReceiptPreview] Error from Supabase:', movementError);
        Alert.alert(
          'خطأ في تحميل البيانات',
          `حدث خطأ أثناء الاتصال بقاعدة البيانات:\n${movementError?.message || 'خطأ غير معروف'}`,
          [{ text: 'حسناً', onPress: () => router.back() }]
        );
        return;
      }

      if (!movementData) {
        console.warn('[ReceiptPreview] No movement data found');
        Alert.alert(
          'السند غير موجود',
          'لم يتم العثور على السند المطلوب. ربما تم حذفه أو أنه غير متاح.',
          [{ text: 'رجوع', onPress: () => router.back() }]
        );
        return;
      }

      if (!movementData.receipt_number) {
        console.warn('[ReceiptPreview] Movement found but no receipt number');
        Alert.alert(
          'خطأ في السند',
          'السند موجود ولكن لم يتم توليد رقم السند له. يرجى الاتصال بالدعم الفني.',
          [{ text: 'رجوع', onPress: () => router.back() }]
        );
        return;
      }

      const accessibleCustomer = await fetchAccessibleCustomerById(
        currentUser.userId,
        movementData.customer_id,
        true,
      );

      if (!accessibleCustomer) {
        Alert.alert('غير مصرح', 'هذا السند غير متاح للحساب الحالي', [
          { text: 'رجوع', onPress: () => router.back() },
        ]);
        return;
      }

      console.log('[ReceiptPreview] Movement data loaded successfully');
      const scopedMovementData = {

  ...movementData,

  customers: {
    ...(accessibleCustomer || {}),
    ...((movementData.customers as any) || {}),
  },

  };

      setMovement(scopedMovementData);
      await generateReceipt(scopedMovementData);
    } catch (error: any) {
      console.error('[ReceiptPreview] Error loading movement:', error);
      Alert.alert(
        'خطأ غير متوقع',
        `حدث خطأ غير متوقع:\n${error?.message || 'خطأ غير معروف'}`,
        [{ text: 'رجوع', onPress: () => router.back() }]
      );
    } finally {
      setIsLoading(false);
    }
  };

  const generateReceipt = async (movementData: any, forceRefresh = false) => {
    try {
      console.log('[ReceiptPreview] Starting receipt generation...', forceRefresh ? 'with force refresh' : '');
      setIsPdfReady(false);
      const customerData = movementData.customers;
      const commissionRecipientData = movementData.commission_recipient;

      let linkedCustomerId = null;
      if (movementData.linked_movement_id) {
        const { data: linkedMovement } = await supabase
          .from('account_movements')
          .select('customer_id')
          .eq('id', movementData.linked_movement_id)
          .maybeSingle();
        linkedCustomerId = linkedMovement?.customer_id;
      }

      const receiptData = {
        ...movementData,
        customerName: customerData?.name || (customerName as string) || 'عميل غير محدد',
        customerAccountNumber: customerData?.account_number || (customerAccountNumber as string) || '0000000',
        customerPhone: customerData?.phone,
        commission_recipient_name: commissionRecipientData?.name,
        currentUserId: currentUser?.userId,
        linkedCustomerId,
      };

      console.log('[ReceiptPreview] Receipt data prepared:', receiptData);

      const qrData = generateQRCodeData(receiptData);
      console.log('[ReceiptPreview] QR data generated:', qrData);

      console.log('[ReceiptPreview] Waiting for QR code to render...');
      const qrCodeDataUrl = await new Promise<string>((resolve) => {
        setTimeout(async () => {
          if (qrRef.current) {
            console.log('[ReceiptPreview] QR ref found, converting to data URL...');
            try {
              qrRef.current.toDataURL((dataUrl: string) => {
                console.log('[ReceiptPreview] QR code converted successfully. Length:', dataUrl?.length);
                resolve(`data:image/png;base64,${dataUrl}`);
              });
            } catch (error) {
              console.error('[ReceiptPreview] Error converting QR code:', error);
              resolve('');
            }
          } else {
            console.warn('[ReceiptPreview] QR ref not found, skipping QR code');
            resolve('');
          }
        }, 500);
      });

      console.log('[ReceiptPreview] Loading receipt logo...');
      let logoDataUrl: string | undefined;
      try {
        logoDataUrl = await getCustomerReceiptHeaderBase64(
          customerData,
          forceRefresh,
          { userId: currentUser?.userId }
        );
        console.log('[ReceiptPreview] Receipt logo loaded successfully. Type:', logoDataUrl?.substring(0, 30));
      } catch (logoError) {
        console.warn('[ReceiptPreview] Could not load receipt logo, continuing without it:', logoError);
        logoDataUrl = undefined;
      }

      console.log('[ReceiptPreview] Generating HTML...');
      const html = generateReceiptHTML(receiptData, qrCodeDataUrl, logoDataUrl);
      console.log('[ReceiptPreview] HTML generated. Length:', html.length);

      setHtmlContent(html);

      console.log('[ReceiptPreview] Converting to PDF...');
      const { uri } = await Print.printToFileAsync({
        html: html,
        base64: false,
      });
      console.log('[ReceiptPreview] PDF created at:', uri);

      const pdfName = `receipt_${movementData.receipt_number || movementData.movement_number}.pdf`;
      const pdfPath = `${FileSystem.documentDirectory}${pdfName}`;

      console.log('[ReceiptPreview] Moving PDF to:', pdfPath);
      await FileSystem.moveAsync({
        from: uri,
        to: pdfPath,
      });

      console.log('[ReceiptPreview] PDF ready!');
      setPdfUri(pdfPath);
      setIsPdfReady(true);
    } catch (error: any) {
      console.error('[ReceiptPreview] Error generating receipt:', error);
      console.error('[ReceiptPreview] Error stack:', error?.stack);
      Alert.alert(
        'خطأ في إنشاء السند',
        `حدث خطأ أثناء إنشاء السند:\n${error?.message || 'خطأ غير معروف'}\n\nيرجى المحاولة مرة أخرى.`
      );
      setHtmlContent('');
      setIsPdfReady(false);
    }
  };

  const handleShare = async () => {
    if (!movement || !pdfUri) {
      Alert.alert('خطأ', 'لم يتم تحميل بيانات السند بعد');
      return;
    }

    try {
      console.log('[ReceiptPreview] Starting share process...');
      setIsSharing(true);

      const canShare = await Sharing.isAvailableAsync();
      console.log('[ReceiptPreview] Can share:', canShare);

      if (canShare) {
        console.log('[ReceiptPreview] Sharing PDF:', pdfUri);
        await Sharing.shareAsync(pdfUri, {
          mimeType: 'application/pdf',
          dialogTitle: 'مشاركة السند',
          UTI: 'com.adobe.pdf',
        });
        console.log('[ReceiptPreview] Share completed successfully');
      } else {
        Alert.alert('تنبيه', 'المشاركة غير متاحة على هذا الجهاز');
      }
    } catch (error: any) {
      console.error('[ReceiptPreview] Error sharing receipt:', error);
      Alert.alert(
        'خطأ في المشاركة',
        `حدث خطأ أثناء مشاركة السند:\n${error?.message || 'خطأ غير معروف'}`
      );
    } finally {
      setIsSharing(false);
    }
  };

  const handleDownload = async () => {
    if (!movement || !pdfUri) {
      Alert.alert('خطأ', 'لم يتم تحميل بيانات السند بعد');
      return;
    }

    try {
      console.log('[ReceiptPreview] Starting download process...');
      setIsDownloading(true);

      const pdfName = `receipt_${movement.receipt_number || movement.movement_number}.pdf`;
      console.log('[ReceiptPreview] PDF name:', pdfName);

      if (Platform.OS === 'web') {
        console.log('[ReceiptPreview] Platform is web, reading as base64...');
        const content = await FileSystem.readAsStringAsync(pdfUri, {
          encoding: FileSystem.EncodingType.Base64,
        });
        console.log('[ReceiptPreview] Creating download link...');
        const link = document.createElement('a');
        link.href = `data:application/pdf;base64,${content}`;
        link.download = pdfName;
        link.click();
        console.log('[ReceiptPreview] Download triggered');
      } else {
        console.log('[ReceiptPreview] File saved at:', pdfUri);
        Alert.alert('نجح', `تم حفظ الملف:\n${pdfName}\n\nالمسار:\n${pdfUri}`);
      }
    } catch (error: any) {
      console.error('[ReceiptPreview] Error downloading receipt:', error);
      Alert.alert(
        'خطأ في التنزيل',
        `حدث خطأ أثناء تنزيل السند:\n${error?.message || 'خطأ غير معروف'}`
      );
    } finally {
      setIsDownloading(false);
    }
  };

  const handleRefresh = async () => {
    if (!movement) {
      Alert.alert('خطأ', 'لم يتم تحميل بيانات السند بعد');
      return;
    }

    Alert.alert(
      'إعادة إنشاء السند',
      'سيتم إعادة إنشاء السند بالشعار الحالي. هل تريد المتابعة؟',
      [
        {
          text: 'إلغاء',
          style: 'cancel',
        },
        {
          text: 'إعادة إنشاء',
          onPress: async () => {
            try {
              console.log('[ReceiptPreview] Starting refresh process...');
              setIsRefreshing(true);
              await generateReceipt(movement, true);
              Alert.alert('نجح', 'تم إعادة إنشاء السند بنجاح');
            } catch (error: any) {
              console.error('[ReceiptPreview] Error refreshing receipt:', error);
              Alert.alert(
                'خطأ في إعادة الإنشاء',
                `حدث خطأ أثناء إعادة إنشاء السند:\n${error?.message || 'خطأ غير معروف'}`
              );
            } finally {
              setIsRefreshing(false);
            }
          },
        },
      ]
    );
  };

  if (isLoading || !isPdfReady) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
            <ArrowRight size={24} color="#111827" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>معاينة السند</Text>
          <View style={{ width: 40 }} />
        </View>
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color="#4F46E5" />
          <Text style={styles.loadingText}>
            {isLoading ? 'جاري تحميل البيانات...' : 'جاري إنشاء السند...'}
          </Text>
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
        <Text style={styles.headerTitle}>معاينة السند</Text>
        <View style={styles.headerActions}>
          <TouchableOpacity
            style={[styles.actionButton, isRefreshing && styles.actionButtonDisabled]}
            onPress={handleRefresh}
            disabled={isRefreshing}
          >
            {isRefreshing ? (
              <ActivityIndicator size="small" color="#10B981" />
            ) : (
              <RefreshCw size={20} color="#10B981" />
            )}
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.actionButton, isDownloading && styles.actionButtonDisabled]}
            onPress={handleDownload}
            disabled={isDownloading}
          >
            {isDownloading ? (
              <ActivityIndicator size="small" color="#4F46E5" />
            ) : (
              <Download size={20} color="#4F46E5" />
            )}
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.actionButton, isSharing && styles.actionButtonDisabled]}
            onPress={handleShare}
            disabled={isSharing}
          >
            {isSharing ? (
              <ActivityIndicator size="small" color="#4F46E5" />
            ) : (
              <Share2 size={20} color="#4F46E5" />
            )}
          </TouchableOpacity>
        </View>
      </View>

      <View style={styles.hidden}>
        {movement && (
          <QRCode
            value={generateQRCodeData({
              ...movement,
              customerName: (movement as any).customers?.name || (customerName as string) || 'عميل غير محدد',
              customerAccountNumber: (movement as any).customers?.account_number || (customerAccountNumber as string) || '0000000',
            })}
            size={120}
            getRef={(ref) => (qrRef.current = ref)}
          />
        )}
      </View>

      <View style={styles.content}>
        {pdfUri ? (
          <WebView
            style={styles.webView}
            source={{ uri: Platform.OS === 'android' ? `file://${pdfUri}` : pdfUri }}
            originWhitelist={['*']}
            scalesPageToFit={true}
            showsVerticalScrollIndicator={false}
            showsHorizontalScrollIndicator={false}
          />
        ) : htmlContent ? (
          <WebView
            style={styles.webView}
            source={{ html: htmlContent }}
            originWhitelist={['*']}
            scalesPageToFit={true}
            showsVerticalScrollIndicator={false}
            showsHorizontalScrollIndicator={false}
          />
        ) : (
          <View style={styles.errorContainer}>
            <Text style={styles.errorText}>لم يتم تحميل السند</Text>
          </View>
        )}
      </View>

      <View style={styles.footer}>
        <TouchableOpacity
          style={[styles.shareButton, isSharing && styles.shareButtonDisabled]}
          onPress={handleShare}
          disabled={isSharing}
        >
          <Share2 size={20} color="#FFFFFF" />
          <Text style={styles.shareButtonText}>
            {isSharing ? 'جاري المشاركة...' : 'مشاركة السند'}
          </Text>
        </TouchableOpacity>
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
  headerActions: {
    flexDirection: 'row',
    gap: 8,
  },
  actionButton: {
    width: 40,
    height: 40,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#EEF2FF',
    borderRadius: 8,
  },
  actionButtonDisabled: {
    opacity: 0.6,
  },
  content: {
    flex: 1,
  },
  webView: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    minHeight: 800,
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
    textAlign: 'center',
  },
  errorContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 20,
  },
  errorText: {
    fontSize: 16,
    color: '#EF4444',
    textAlign: 'center',
  },
  footer: {
    backgroundColor: '#FFFFFF',
    padding: 20,
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
  },
  shareButton: {
    backgroundColor: '#4F46E5',
    borderRadius: 12,
    paddingVertical: 16,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  shareButtonDisabled: {
    opacity: 0.6,
  },
  shareButtonText: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  hidden: {
    position: 'absolute',
    left: -1000,
    top: -1000,
    opacity: 0,
  },
});
