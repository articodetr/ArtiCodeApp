import { supabase } from '@/lib/supabase';
import * as ImagePicker from 'expo-image-picker';
import * as FileSystem from 'expo-file-system/legacy';
import { decode } from 'base64-arraybuffer';

const BUCKET_NAME = 'shop-logos';

export interface LetterheadSettings {
  id?: string;
  user_id?: string;
  logo_url: string | null;
  business_name: string;
  english_name: string;
  phone_number: string;
  address_ar: string;
  address_en: string;
  show_logo: boolean;
  show_phone: boolean;
  created_at?: string;
  updated_at?: string;
}

export const DEFAULT_LETTERHEAD_SETTINGS: LetterheadSettings = {
  logo_url: null,
  business_name: 'اسم الشركة',
  english_name: 'Company Name',
  phone_number: '',
  address_ar: '',
  address_en: '',
  show_logo: true,
  show_phone: true,
};

function normalizeText(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

export function normalizeLetterheadSettings(
  settings?: Partial<LetterheadSettings> | null
): LetterheadSettings {
  return {
    ...DEFAULT_LETTERHEAD_SETTINGS,
    ...(settings || {}),
    logo_url: typeof settings?.logo_url === 'string' ? settings.logo_url : null,
    business_name: normalizeText(settings?.business_name, DEFAULT_LETTERHEAD_SETTINGS.business_name),
    english_name: normalizeText(settings?.english_name, DEFAULT_LETTERHEAD_SETTINGS.english_name),
    phone_number: normalizeText(settings?.phone_number, ''),
    address_ar: normalizeText(settings?.address_ar, ''),
    address_en: normalizeText(settings?.address_en, ''),
    show_logo: settings?.show_logo ?? DEFAULT_LETTERHEAD_SETTINGS.show_logo,
    show_phone: settings?.show_phone ?? DEFAULT_LETTERHEAD_SETTINGS.show_phone,
  };
}

export async function getLetterheadSettings(userId: string): Promise<LetterheadSettings> {
  const { data, error } = await supabase
    .from('letterhead_settings')
    .select('*')
    .eq('user_id', userId)
    .maybeSingle();

  if (error) {
    console.error('[letterheadService] Error loading settings:', error);
    throw new Error('فشل تحميل إعدادات الترويسة');
  }

  return normalizeLetterheadSettings(data);
}

export async function saveLetterheadSettings(
  userId: string,
  settings: Partial<LetterheadSettings>
): Promise<LetterheadSettings> {
  const normalized = normalizeLetterheadSettings(settings);

  const payload = {
    user_id: userId,
    logo_url: normalized.logo_url,
    business_name: normalized.business_name.trim() || DEFAULT_LETTERHEAD_SETTINGS.business_name,
    english_name: normalized.english_name.trim() || DEFAULT_LETTERHEAD_SETTINGS.english_name,
    phone_number: normalized.phone_number.trim(),
    address_ar: normalized.address_ar.trim(),
    address_en: normalized.address_en.trim(),
    show_logo: normalized.show_logo,
    show_phone: normalized.show_phone,
    updated_at: new Date().toISOString(),
  };

  const { data, error } = await supabase
    .from('letterhead_settings')
    .upsert(payload, { onConflict: 'user_id' })
    .select('*')
    .single();

  if (error) {
    console.error('[letterheadService] Error saving settings:', error);
    throw new Error('فشل حفظ إعدادات الترويسة');
  }

  return normalizeLetterheadSettings(data);
}

export async function pickLetterheadLogoFromGallery(): Promise<string | null> {
  const permissionResult = await ImagePicker.requestMediaLibraryPermissionsAsync();

  if (!permissionResult.granted) {
    throw new Error('تم رفض صلاحية الوصول إلى المعرض');
  }

  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ImagePicker.MediaTypeOptions.Images,
    allowsEditing: true,
    aspect: [1, 1],
    quality: 0.9,
    base64: false,
  });

  if (!result.canceled && result.assets[0]) {
    return result.assets[0].uri;
  }

  return null;
}

export async function uploadLetterheadLogo(imageUri: string, userId: string): Promise<string> {
  const base64 = await FileSystem.readAsStringAsync(imageUri, {
    encoding: FileSystem.EncodingType.Base64,
  });

  const fileSizeInBytes = (base64.length * 3) / 4;
  const maxFileSize = 5 * 1024 * 1024;

  if (fileSizeInBytes > maxFileSize) {
    throw new Error('حجم الشعار كبير جدًا. الحد الأقصى 5 MB');
  }

  const rawExt = imageUri.split('.').pop()?.split('?')[0]?.toLowerCase() || 'jpg';
  const supportedFormats = ['jpg', 'jpeg', 'png', 'webp'];
  const fileExt = supportedFormats.includes(rawExt) ? rawExt : 'jpg';
  const normalizedExt = fileExt === 'jpg' ? 'jpeg' : fileExt;
  const filePath = `letterheads/${userId}_${Date.now()}.${fileExt}`;
  const arrayBuffer = decode(base64);

  const { error: uploadError } = await supabase.storage
    .from(BUCKET_NAME)
    .upload(filePath, arrayBuffer, {
      contentType: `image/${normalizedExt}`,
      upsert: true,
    });

  if (uploadError) {
    console.error('[letterheadService] Upload error:', uploadError);
    throw new Error(`فشل رفع الشعار: ${uploadError.message}`);
  }

  const { data } = supabase.storage.from(BUCKET_NAME).getPublicUrl(filePath);
  return data.publicUrl;
}

export async function deleteLetterheadLogo(logoUrl: string | null): Promise<void> {
  if (!logoUrl || !logoUrl.includes(BUCKET_NAME)) {
    return;
  }

  try {
    const publicMarker = `/storage/v1/object/public/${BUCKET_NAME}/`;
    const markerIndex = logoUrl.indexOf(publicMarker);
    if (markerIndex === -1) return;

    const filePath = decodeURIComponent(logoUrl.substring(markerIndex + publicMarker.length));
    await supabase.storage.from(BUCKET_NAME).remove([filePath]);
  } catch (error) {
    console.warn('[letterheadService] Could not delete old logo:', error);
  }
}