import { Image } from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import * as DocumentPicker from 'expo-document-picker';
import * as FileSystem from 'expo-file-system/legacy';
import { decode } from 'base64-arraybuffer';
import { supabase } from '@/lib/supabase';

export type CustomerReceiptHeaderMode = 'default' | 'full_banner' | 'generated';

export const CUSTOMER_HEADER_BANNER_WIDTH = 2048;
export const CUSTOMER_HEADER_BANNER_HEIGHT = 405;

const BUCKET_NAME = 'shop-logos';

function getFileExtension(uri: string): string {
  const cleanUri = uri.split('?')[0];
  const parts = cleanUri.split('.');
  const ext = parts[parts.length - 1]?.toLowerCase();

  if (!ext || ext.length > 5) return 'png';
  if (ext === 'jpg') return 'jpeg';
  if (ext === 'jpeg' || ext === 'png' || ext === 'webp') return ext;

  return 'png';
}

function getMimeType(ext: string): string {
  if (ext === 'jpeg') return 'image/jpeg';
  if (ext === 'webp') return 'image/webp';
  return 'image/png';
}

function getImageSize(uri: string): Promise<{ width: number; height: number }> {
  return new Promise((resolve, reject) => {
    Image.getSize(
      uri,
      (width, height) => resolve({ width, height }),
      reject
    );
  });
}

export async function ensureExactBannerSize(uri: string): Promise<void> {
  const { width, height } = await getImageSize(uri);

  if (width !== CUSTOMER_HEADER_BANNER_WIDTH || height !== CUSTOMER_HEADER_BANNER_HEIGHT) {
    throw new Error(
      `يجب أن يكون البانر بالمقاس ${CUSTOMER_HEADER_BANNER_WIDTH}×${CUSTOMER_HEADER_BANNER_HEIGHT} بكسل بالضبط. المقاس الحالي هو ${width}×${height}.`
    );
  }
}

export async function pickCustomerHeaderBannerFile(): Promise<string | null> {
  const result = await DocumentPicker.getDocumentAsync({
    type: ['image/png', 'image/jpeg', 'image/webp'],
    copyToCacheDirectory: true,
    multiple: false,
  });

  if (result.canceled || !result.assets?.[0]?.uri) {
    return null;
  }

  const uri = result.assets[0].uri;
  await ensureExactBannerSize(uri);
  return uri;
}

export async function pickCustomerHeaderLogo(): Promise<string | null> {
  const permissionResult = await ImagePicker.requestMediaLibraryPermissionsAsync();

  if (!permissionResult.granted) {
    throw new Error('تم رفض صلاحية الوصول إلى الصور');
  }

  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ImagePicker.MediaTypeOptions.Images,
    allowsEditing: true,
    aspect: [1, 1],
    quality: 1,
    base64: false,
  });

  if (result.canceled || !result.assets?.[0]?.uri) {
    return null;
  }

  return result.assets[0].uri;
}

export async function uploadCustomerHeaderAsset(
  imageUri: string,
  folder: 'customer-banners' | 'customer-logos',
  customerId: string
): Promise<{ success: boolean; url?: string; error?: string }> {
  try {
    const ext = getFileExtension(imageUri);
    const mimeType = getMimeType(ext);
    const base64 = await FileSystem.readAsStringAsync(imageUri, {
      encoding: FileSystem.EncodingType.Base64,
    });

    if (!base64) {
      throw new Error('فشل قراءة الصورة');
    }

    const fileName = `${customerId}_${Date.now()}.${ext}`;
    const filePath = `${folder}/${fileName}`;
    const arrayBuffer = decode(base64);

    const { error: uploadError } = await supabase.storage
      .from(BUCKET_NAME)
      .upload(filePath, arrayBuffer, {
        contentType: mimeType,
        upsert: true,
      });

    if (uploadError) {
      throw new Error(uploadError.message);
    }

    const { data } = supabase.storage.from(BUCKET_NAME).getPublicUrl(filePath);

    return {
      success: true,
      url: data.publicUrl,
    };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : 'فشل رفع الصورة',
    };
  }
}
