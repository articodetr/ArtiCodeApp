import { supabase } from '@/lib/supabase';
import * as ImagePicker from 'expo-image-picker';
import * as DocumentPicker from 'expo-document-picker';
import * as FileSystem from 'expo-file-system/legacy';
import { decode } from 'base64-arraybuffer';

const BUCKET_NAME = 'shop-logos';
const FIXED_SETTINGS_ID = '00000000-0000-0000-0000-000000000000';

export interface UploadLogoResult {
  success: boolean;
  url?: string;
  error?: string;
}

export async function pickImageFromGallery(): Promise<string | null> {
  const permissionResult = await ImagePicker.requestMediaLibraryPermissionsAsync();

  if (!permissionResult.granted) {
    throw new Error('تم رفض الصلاحية للوصول إلى المعرض');
  }

  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ImagePicker.MediaTypeOptions.Images,
    allowsEditing: true,
    aspect: [1, 1],
    quality: 0.7,
    base64: false,
  });

  if (!result.canceled && result.assets[0]) {
    return result.assets[0].uri;
  }

  return null;
}

export async function pickImageFromCamera(): Promise<string | null> {
  const permissionResult = await ImagePicker.requestCameraPermissionsAsync();

  if (!permissionResult.granted) {
    throw new Error('تم رفض الصلاحية للوصول إلى الكاميرا');
  }

  const result = await ImagePicker.launchCameraAsync({
    allowsEditing: true,
    aspect: [1, 1],
    quality: 0.7,
  });

  if (!result.canceled && result.assets[0]) {
    return result.assets[0].uri;
  }

  return null;
}

export async function pickPngFile(): Promise<string | null> {
  try {
    const result = await DocumentPicker.getDocumentAsync({
      type: 'image/png',
      copyToCacheDirectory: true,
    });

    if (result.canceled) {
      return null;
    }

    if (!result.assets || result.assets.length === 0) {
      throw new Error('لم يتم اختيار أي ملف');
    }

    const file = result.assets[0];

    if (!file.mimeType || file.mimeType !== 'image/png') {
      throw new Error('يجب اختيار ملف PNG فقط');
    }

    if (!file.uri) {
      throw new Error('فشل قراءة الملف');
    }

    return file.uri;
  } catch (error) {
    if (error instanceof Error) {
      throw error;
    }
    throw new Error('فشل اختيار الملف');
  }
}

export async function uploadLogo(imageUri: string, userId: string = 'default'): Promise<UploadLogoResult> {
  try {
    console.log('[logoService] Starting upload for:', imageUri);

    const base64 = await FileSystem.readAsStringAsync(imageUri, {
      encoding: FileSystem.EncodingType.Base64,
    });

    const fileSizeInBytes = (base64.length * 3) / 4;
    const fileSizeInMB = fileSizeInBytes / (1024 * 1024);
    console.log('[logoService] File read successfully, size:', fileSizeInMB.toFixed(2), 'MB');

    const MAX_FILE_SIZE = 5 * 1024 * 1024;
    if (fileSizeInBytes > MAX_FILE_SIZE) {
      throw new Error(`حجم الملف كبير جداً (${fileSizeInMB.toFixed(2)} MB). الحد الأقصى هو 5 MB`);
    }

    const fileExt = imageUri.split('.').pop()?.toLowerCase() || 'jpg';

    const supportedFormats = ['jpg', 'jpeg', 'png', 'webp'];
    if (!supportedFormats.includes(fileExt)) {
      throw new Error('نوع الملف غير مدعوم. يرجى استخدام JPG، PNG، أو WEBP');
    }

    const normalizedExt = fileExt === 'jpg' ? 'jpeg' : fileExt;

    const fileName = `${userId}_${Date.now()}.${fileExt}`;
    const filePath = `logos/${fileName}`;

    console.log('[logoService] Uploading to path:', filePath);

    const arrayBuffer = decode(base64);

    console.log('[logoService] Array buffer created, uploading to storage...');

    const { data: uploadData, error: uploadError } = await supabase.storage
      .from(BUCKET_NAME)
      .upload(filePath, arrayBuffer, {
        contentType: `image/${normalizedExt}`,
        upsert: true,
      });

    if (uploadError) {
      console.error('[logoService] Upload error:', uploadError);
      throw new Error(`فشل رفع الصورة: ${uploadError.message}`);
    }

    console.log('[logoService] Upload successful:', uploadData);

    const { data: urlData } = supabase.storage
      .from(BUCKET_NAME)
      .getPublicUrl(filePath);

    console.log('[logoService] Public URL:', urlData.publicUrl);

    return {
      success: true,
      url: urlData.publicUrl,
    };
  } catch (error) {
    console.error('[logoService] Error uploading logo:', error);
    const errorMessage = error instanceof Error ? error.message : 'فشل رفع الشعار';
    return {
      success: false,
      error: errorMessage,
    };
  }
}

export async function deleteLogo(logoUrl: string): Promise<boolean> {
  try {
    if (!logoUrl || !logoUrl.includes(BUCKET_NAME)) {
      console.log('[logoService] Invalid logo URL or not in our bucket, skipping deletion');
      return true;
    }

    const urlParts = logoUrl.split('/');
    const fileName = urlParts[urlParts.length - 1];
    const filePath = `logos/${fileName}`;

    console.log('[logoService] Attempting to delete:', filePath);

    const { error } = await supabase.storage
      .from(BUCKET_NAME)
      .remove([filePath]);

    if (error) {
      console.error('[logoService] Delete error:', error);
      return true;
    }

    console.log('[logoService] Successfully deleted old logo');
    return true;
  } catch (error) {
    console.error('[logoService] Error deleting logo:', error);
    return true;
  }
}

export async function updateShopLogo(logoUrl: string | null): Promise<boolean> {
  try {
    console.log('[logoService] updateShopLogo called with logoUrl:', logoUrl);

    const { data: settings, error: fetchError } = await supabase
      .from('app_settings')
      .select('id, shop_logo')
      .eq('id', FIXED_SETTINGS_ID)
      .maybeSingle();

    if (fetchError) {
      console.error('[logoService] Fetch error:', fetchError);
    }

    if (settings?.shop_logo && logoUrl !== settings.shop_logo) {
      console.log('[logoService] Deleting old logo:', settings.shop_logo);
      await deleteLogo(settings.shop_logo);
    }

    const settingsToUpsert = {
      id: FIXED_SETTINGS_ID,
      shop_logo: logoUrl,
    };

    console.log('[logoService] Upserting settings:', settingsToUpsert);

    const { data, error: upsertError } = await supabase
      .from('app_settings')
      .upsert(settingsToUpsert, {
        onConflict: 'id',
        ignoreDuplicates: false,
      })
      .select();

    if (upsertError) {
      console.error('[logoService] Upsert error:', upsertError);
      console.error('[logoService] Error details:', JSON.stringify(upsertError, null, 2));
      return false;
    }

    console.log('[logoService] Settings upserted successfully:', data);
    return true;
  } catch (error) {
    console.error('[logoService] Error updating shop logo:', error);
    if (error instanceof Error) {
      console.error('[logoService] Error message:', error.message);
    }
    return false;
  }
}

export async function updateShopSettings(settings: {
  shop_name?: string;
  shop_phone?: string;
  shop_address?: string;
}): Promise<boolean> {
  try {
    console.log('[logoService] updateShopSettings called with:', settings);

    const settingsToUpsert = {
      id: FIXED_SETTINGS_ID,
      ...settings,
    };

    const { data, error: upsertError } = await supabase
      .from('app_settings')
      .upsert(settingsToUpsert, {
        onConflict: 'id',
        ignoreDuplicates: false,
      })
      .select();

    if (upsertError) {
      console.error('[logoService] Upsert error:', upsertError);
      throw upsertError;
    }

    console.log('[logoService] Settings upserted successfully:', data);
    return true;
  } catch (error) {
    console.error('[logoService] Error updating shop settings:', error);
    return false;
  }
}
