import { Platform } from 'react-native';
import * as FileSystem from 'expo-file-system/legacy';
import { Asset } from 'expo-asset';
import { supabase } from '@/lib/supabase';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { Customer } from '@/types/database';

const BUCKET_NAME = 'shop-logos';
const FIXED_SETTINGS_ID = '00000000-0000-0000-0000-000000000000';
const USER_KEY = '@money_transfer_current_user';

async function getCurrentUserIdFromStorage(): Promise<string | null> {
  try {
    const raw = await AsyncStorage.getItem(USER_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    return parsed?.userId || null;
  } catch (error) {
    console.error('[logoHelper] Error reading current user:', error);
    return null;
  }
}
const DEFAULT_RECEIPT_HEADER = require('../assets/images/default-header.png');

type ReceiptHeaderContext = {
  userId?: string | null;
};

type StoredLetterheadSettings = {
  logo_url?: string | null;
  business_name?: string | null;
  english_name?: string | null;
  phone_number?: string | null;
  address_ar?: string | null;
  address_en?: string | null;
  show_logo?: boolean | null;
  show_phone?: boolean | null;
};

function escapeXml(value?: string | null): string {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

async function getBundledDefaultHeader(): Promise<string> {
  try {
    const asset = Asset.fromModule(DEFAULT_RECEIPT_HEADER);

    if (Platform.OS !== 'web' && !asset.localUri) {
      await asset.downloadAsync();
    }

    const assetUri = asset.localUri || asset.uri;
    if (!assetUri) return '';

    if (Platform.OS === 'web') {
      return assetUri;
    }

    const base64 = await FileSystem.readAsStringAsync(assetUri, {
      encoding: FileSystem.EncodingType.Base64,
    });

    if (!base64) return '';

    const mimeType = assetUri.toLowerCase().endsWith('.png')
      ? 'image/png'
      : 'image/jpeg';

    return `data:${mimeType};base64,${base64}`;
  } catch (error) {
    console.error('[logoHelper] Error loading bundled default header:', error);
    return '';
  }
}

async function urlToDataUrlOnWeb(url: string): Promise<string | null> {
  try {
    const response = await fetch(url);
    const blob = await response.blob();

    return await new Promise<string | null>((resolve) => {
      const reader = new FileReader();
      reader.onloadend = () => {
        resolve(typeof reader.result === 'string' ? reader.result : null);
      };
      reader.onerror = () => resolve(null);
      reader.readAsDataURL(blob);
    });
  } catch {
    return null;
  }
}

async function downloadAndConvertImageToBase64(imageUrl: string): Promise<string | null> {
  try {
    if (!imageUrl) return null;
    if (imageUrl.startsWith('data:image/')) return imageUrl;

    if (Platform.OS === 'web') {
      const dataUrl = await urlToDataUrlOnWeb(imageUrl);
      return dataUrl || imageUrl;
    }

    const tempPath = `${FileSystem.cacheDirectory}temp_image_${Date.now()}`;
    const downloadResult = await FileSystem.downloadAsync(imageUrl, tempPath);

    if (downloadResult.status !== 200) {
      return null;
    }

    const base64 = await FileSystem.readAsStringAsync(downloadResult.uri, {
      encoding: FileSystem.EncodingType.Base64,
    });

    if (!base64) return null;

    const lower = imageUrl.toLowerCase();
    const mimeType = lower.endsWith('.png')
      ? 'image/png'
      : lower.endsWith('.webp')
      ? 'image/webp'
      : 'image/jpeg';

    return `data:${mimeType};base64,${base64}`;
  } catch (error) {
    console.error('[logoHelper] Error converting image to base64:', error);
    return null;
  }
}

function buildGeneratedCustomerHeaderSvg(
  customer: Partial<Customer>,
  logoHref?: string | null
): string {
  const arabicName = escapeXml(customer.name || 'اسم العميل');
  const englishName = escapeXml(customer.name || 'Customer Name');
  const phoneNumber = escapeXml(customer.phone || '');
  const accountNumber = escapeXml(customer.account_number || '');
  const initials = escapeXml((customer.name?.trim()?.charAt(0) || 'C').toUpperCase());

  return `
  <svg xmlns="http://www.w3.org/2000/svg" width="2048" height="620" viewBox="0 0 2048 620">
    <rect width="2048" height="620" fill="#ffffff" />
    <text x="170" y="188" font-size="62" font-weight="800" fill="#111111">${englishName}</text>
    ${phoneNumber ? `<text x="170" y="282" font-size="36" font-weight="500" fill="#4B5563">${phoneNumber}</text>` : ``}
    ${accountNumber ? `<text x="170" y="366" font-size="34" font-weight="500" fill="#6B7280">Account: ${accountNumber}</text>` : ``}

    <text x="1878" y="150" text-anchor="end" font-size="62" font-weight="800" fill="#111111">${arabicName}</text>
    ${phoneNumber ? `<text x="1878" y="222" text-anchor="end" font-size="36" font-weight="500" fill="#4B5563">${phoneNumber}</text>` : ``}
    ${accountNumber ? `<text x="1878" y="286" text-anchor="end" font-size="34" font-weight="500" fill="#6B7280">${accountNumber}</text>` : ``}

    <circle cx="1024" cy="218" r="150" fill="#ffffff" stroke="#111111" stroke-width="6" />
    ${
      logoHref
        ? `<image href="${logoHref}" x="894" y="88" width="260" height="260" preserveAspectRatio="xMidYMid meet" />`
        : `<text x="1024" y="236" text-anchor="middle" font-size="118" font-weight="700" fill="#111111">${initials}</text>`
    }

    <line x1="150" y1="548" x2="1898" y2="548" stroke="#BDBDBD" stroke-width="3.5" />
  </svg>
  `;
}

function buildGeneratedCustomerHeaderDataUrl(
  customer: Partial<Customer>,
  logoHref?: string | null
): string {
  const svg = buildGeneratedCustomerHeaderSvg(customer, logoHref);
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

function buildStoredLetterheadHeaderSvg(
  settings: StoredLetterheadSettings,
  logoHref?: string | null
): string {
  const arabicName = escapeXml(settings.business_name?.trim() || 'اسم الشركة');
  const englishName = escapeXml(
    settings.english_name?.trim() || settings.business_name?.trim() || 'Company Name'
  );
  const phoneNumber = escapeXml(settings.phone_number?.trim() || '');
  const addressAr = escapeXml(settings.address_ar?.trim() || '');
  const addressEn = escapeXml(settings.address_en?.trim() || '');
  const showLogo = settings.show_logo ?? true;
  const showPhone = settings.show_phone ?? true;
  const initials = escapeXml((settings.business_name?.trim()?.charAt(0) || 'A').toUpperCase());

  return `
  <svg xmlns="http://www.w3.org/2000/svg" width="2048" height="620" viewBox="0 0 2048 620">
    <rect width="2048" height="620" fill="#ffffff" />
    <rect x="24" y="24" width="2000" height="572" rx="24" fill="#ffffff" stroke="#D4D4D4" stroke-width="2.5" />

    <text x="170" y="188" font-size="62" font-weight="800" fill="#111111">${englishName}</text>
    ${showPhone && phoneNumber ? `<text x="170" y="282" font-size="36" font-weight="500" fill="#4B5563">${phoneNumber}</text>` : ``}
    ${addressEn ? `<text x="170" y="366" font-size="34" font-weight="500" fill="#6B7280">${addressEn}</text>` : ``}

    <text x="1878" y="150" text-anchor="end" font-size="62" font-weight="800" fill="#111111">${arabicName}</text>
    ${showPhone && phoneNumber ? `<text x="1878" y="222" text-anchor="end" font-size="36" font-weight="500" fill="#4B5563">${phoneNumber}</text>` : ``}
    ${addressAr ? `<text x="1878" y="286" text-anchor="end" font-size="34" font-weight="500" fill="#6B7280">${addressAr}</text>` : ``}

    ${showLogo ? `
      <circle cx="1024" cy="218" r="150" fill="#ffffff" stroke="#111111" stroke-width="6" />
      ${logoHref
        ? `<image href="${logoHref}" x="894" y="88" width="260" height="260" preserveAspectRatio="xMidYMid meet" />`
        : `<text x="1024" y="236" text-anchor="middle" font-size="118" font-weight="700" fill="#111111">${initials}</text>`
      }
    ` : ``}

    <line x1="150" y1="548" x2="1898" y2="548" stroke="#BDBDBD" stroke-width="3.5" />
  </svg>
  `;
}

function buildStoredLetterheadHeaderDataUrl(
  settings: StoredLetterheadSettings,
  logoHref?: string | null
): string {
  const svg = buildStoredLetterheadHeaderSvg(settings, logoHref);
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

async function getStoredLetterheadHeaderBase64(
  userId?: string | null
): Promise<string | null> {
  if (!userId) return null;

  try {
    const { data, error } = await supabase
      .from('letterhead_settings')
      .select('logo_url, business_name, english_name, phone_number, address_ar, address_en, show_logo, show_phone')
      .eq('user_id', userId)
      .maybeSingle();

    if (error || !data) {
      return null;
    }

    const logoDataUrl = data.show_logo && data.logo_url
      ? await downloadAndConvertImageToBase64(data.logo_url)
      : null;

    return buildStoredLetterheadHeaderDataUrl(data, logoDataUrl);
  } catch (error) {
    console.error('[logoHelper] Error loading stored letterhead settings:', error);
    return null;
  }
}

async function getAppReceiptLogoBase64(forceRefresh = false, userId?: string | null): Promise<string> {
  try {
    const resolvedUserId = userId || await getCurrentUserIdFromStorage();
    const query = supabase
      .from('app_settings')
      .select('selected_receipt_logo, shop_logo')
      .limit(1);

    const { data: settings, error } = resolvedUserId
      ? await query.eq('user_id', resolvedUserId).maybeSingle()
      : await query.eq('id', FIXED_SETTINGS_ID).maybeSingle();

    if (error || !settings) {
      return await getBundledDefaultHeader();
    }

    if (settings.selected_receipt_logo === 'DEFAULT') {
      return await getBundledDefaultHeader();
    }

    const logoUrl = settings.selected_receipt_logo || settings.shop_logo;

    if (!logoUrl || logoUrl === 'DEFAULT') {
      return await getBundledDefaultHeader();
    }

    if (
      logoUrl.includes(BUCKET_NAME) ||
      logoUrl.startsWith('http://') ||
      logoUrl.startsWith('https://')
    ) {
      const converted = await downloadAndConvertImageToBase64(logoUrl);
      return converted || (await getBundledDefaultHeader());
    }

    return await getBundledDefaultHeader();
  } catch (error) {
    console.error('[logoHelper] Error in getAppReceiptLogoBase64:', error);
    return await getBundledDefaultHeader();
  }
}

export async function getCustomerReceiptHeaderBase64(
  customer?: Partial<Customer> | null,
  forceRefresh = false,
  context: ReceiptHeaderContext = {}
): Promise<string> {
  try {
    const mode = customer?.receipt_header_mode || 'default';

    if (!customer || mode === 'default') {
      const storedLetterhead = await getStoredLetterheadHeaderBase64(context.userId);

      if (storedLetterhead) {
        return storedLetterhead;
      }

      return await getAppReceiptLogoBase64(forceRefresh, context.userId);
    }

    if (mode === 'full_banner' && customer.receipt_header_banner_url) {
      const banner = await downloadAndConvertImageToBase64(customer.receipt_header_banner_url);
      return banner || (await getAppReceiptLogoBase64(forceRefresh, context.userId));
    }

    if (mode === 'generated') {
      let centerLogo: string | null = null;

      if (customer.receipt_header_logo_url) {
        centerLogo = await downloadAndConvertImageToBase64(customer.receipt_header_logo_url);
      }

      return buildGeneratedCustomerHeaderDataUrl(customer, centerLogo);
    }

    const storedLetterhead = await getStoredLetterheadHeaderBase64(context.userId);

    if (storedLetterhead) {
      return storedLetterhead;
    }

    return await getAppReceiptLogoBase64(forceRefresh, context.userId);
  } catch (error) {
    console.error('[logoHelper] Error in getCustomerReceiptHeaderBase64:', error);

    const storedLetterhead = await getStoredLetterheadHeaderBase64(context.userId);

    if (storedLetterhead) {
      return storedLetterhead;
    }

    return await getAppReceiptLogoBase64(forceRefresh, context.userId);
  }
}

export async function getReceiptLogoBase64(
  forceRefresh = false,
  customer?: Partial<Customer> | null,
  context: ReceiptHeaderContext = {}
): Promise<string> {
  return getCustomerReceiptHeaderBase64(customer, forceRefresh, context);
}

export async function getLogoBase64(
  forceRefresh = false,
  customer?: Partial<Customer> | null,
  context: ReceiptHeaderContext = {}
): Promise<string> {
  return getCustomerReceiptHeaderBase64(customer, forceRefresh, context);
}

export async function getLogoUrl(userId?: string): Promise<string> {
  try {
    const defaultAsset = Asset.fromModule(DEFAULT_RECEIPT_HEADER);
    const defaultUri = defaultAsset.uri || '';

    const resolvedUserId = userId || await getCurrentUserIdFromStorage();
    const query = supabase
      .from('app_settings')
      .select('shop_logo')
      .limit(1);

    const { data: settings, error } = resolvedUserId
      ? await query.eq('user_id', resolvedUserId).maybeSingle()
      : await query.eq('id', FIXED_SETTINGS_ID).maybeSingle();

    if (error || !settings?.shop_logo) {
      return defaultUri;
    }

    return settings.shop_logo;
  } catch (error) {
    console.error('[logoHelper] Error getting logo URL:', error);
    return Asset.fromModule(DEFAULT_RECEIPT_HEADER).uri || '';
  }
}

export async function clearLogoCache(): Promise<void> {
  try {
    if (Platform.OS !== 'web') {
      const cacheDir = FileSystem.cacheDirectory;
      if (!cacheDir) return;

      const files = await FileSystem.readDirectoryAsync(cacheDir);
      const imageFiles = files.filter(
        (file) => file.startsWith('temp_logo_') || file.startsWith('temp_image_')
      );

      for (const file of imageFiles) {
        await FileSystem.deleteAsync(`${cacheDir}${file}`, { idempotent: true });
      }
    }
  } catch (error) {
    console.error('[logoHelper] Error clearing logo cache:', error);
  }
}