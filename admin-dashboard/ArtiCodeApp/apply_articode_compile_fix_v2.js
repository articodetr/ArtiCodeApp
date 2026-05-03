const fs = require('fs');
const path = require('path');

const root = process.cwd();
const backupDir = path.join(root, `.articode-compile-fix-v2-backup`, String(Date.now()));

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function backupFile(filePath) {
  ensureDir(backupDir);
  const rel = path.relative(root, filePath).replace(/[\\/]/g, '__');
  const dest = path.join(backupDir, rel);
  fs.copyFileSync(filePath, dest);
  console.log(`Backup created: ${dest}`);
}

function read(filePath) {
  if (!fs.existsSync(filePath)) throw new Error(`Missing file: ${filePath}`);
  return fs.readFileSync(filePath, 'utf8');
}

function write(filePath, content) {
  fs.writeFileSync(filePath, content, 'utf8');
  console.log(`Updated: ${path.relative(root, filePath)}`);
}

function replaceOrThrow(source, pattern, replacement, label) {
  const next = source.replace(pattern, replacement);
  if (next === source) throw new Error(`Could not patch: ${label}`);
  return next;
}

function patchAuthContext() {
  const filePath = path.join(root, 'contexts', 'AuthContext.tsx');
  backupFile(filePath);
  let content = read(filePath);

  const replacement = `const updateSettings = async (newSettings: Partial<AppSettings>): Promise<boolean> => {
    try {
      console.log('[AuthContext] updateSettings called with:', JSON.stringify(newSettings, null, 2));

      if (newSettings.shop_logo !== undefined && currentUser?.role !== 'admin') {
        console.error('[AuthContext] Non-admin user attempted to update shop logo');
        return false;
      }

      const activeUserId = currentUser?.userId;
      const fixedId = '00000000-0000-0000-0000-000000000000';
      const settingsToUpsert: Record<string, any> = activeUserId
        ? { user_id: activeUserId, ...newSettings }
        : { id: fixedId, ...newSettings };

      console.log('[AuthContext] Performing upsert with data:', JSON.stringify(settingsToUpsert, null, 2));

      const { data, error: upsertError } = await supabase
        .from('app_settings')
        .upsert(settingsToUpsert, {
          onConflict: activeUserId ? 'user_id' : 'id',
          ignoreDuplicates: false,
        })
        .select();

      if (upsertError) {
        console.error('[AuthContext] Upsert error:', upsertError);
        console.error('[AuthContext] Error code:', upsertError.code);
        console.error('[AuthContext] Error message:', upsertError.message);
        console.error('[AuthContext] Error details:', JSON.stringify(upsertError, null, 2));
        throw upsertError;
      }

      console.log('[AuthContext] Settings upserted successfully:', data);

      if (activeUserId) {
        await loadSettings(activeUserId);
      } else {
        await loadSettings();
      }

      console.log('[AuthContext] Settings reloaded');
      return true;
    } catch (error) {
      console.error('[AuthContext] Error updating settings:', error);
      if (error instanceof Error) {
        console.error('[AuthContext] Error name:', error.name);
        console.error('[AuthContext] Error message:', error.message);
        console.error('[AuthContext] Error stack:', error.stack);
      }
      return false;
    }
  };`;

  content = replaceOrThrow(
    content,
    /const updateSettings = async \(newSettings: Partial<AppSettings>\): Promise<boolean> => \{[\s\S]*?\n  \};/,
    replacement,
    'AuthContext updateSettings'
  );

  write(filePath, content);
}

function patchLogoService() {
  const filePath = path.join(root, 'services', 'logoService.ts');
  backupFile(filePath);
  let content = read(filePath);

  if (!content.includes("@react-native-async-storage/async-storage")) {
    content = content.replace(
      "import { decode } from 'base64-arraybuffer';",
      "import { decode } from 'base64-arraybuffer';\nimport AsyncStorage from '@react-native-async-storage/async-storage';"
    );
  }

  if (!content.includes("const USER_KEY = '@money_transfer_current_user';")) {
    content = content.replace(
      /const FIXED_SETTINGS_ID = '00000000-0000-0000-0000-000000000000';/,
      "const FIXED_SETTINGS_ID = '00000000-0000-0000-0000-000000000000';\nconst USER_KEY = '@money_transfer_current_user';"
    );
  }

  if (!content.includes('async function getCurrentUserIdFromStorage()')) {
    content = content.replace(
      /export interface UploadLogoResult \{[\s\S]*?\}\n/,
      (match) => `${match}\nasync function getCurrentUserIdFromStorage(): Promise<string | null> {\n  try {\n    const raw = await AsyncStorage.getItem(USER_KEY);\n    if (!raw) return null;\n    const parsed = JSON.parse(raw);\n    return parsed?.userId || null;\n  } catch (error) {\n    console.error('[logoService] Error reading current user from storage:', error);\n    return null;\n  }\n}\n`
    );
  }

  const updateShopLogoBlock = `export async function updateShopLogo(logoUrl: string | null): Promise<boolean> {
  try {
    console.log('[logoService] updateShopLogo called with logoUrl:', logoUrl);

    const userId = await getCurrentUserIdFromStorage();
    const query = supabase
      .from('app_settings')
      .select('id, shop_logo')
      .limit(1);

    const { data: settings, error: fetchError } = userId
      ? await query.eq('user_id', userId).maybeSingle()
      : await query.eq('id', FIXED_SETTINGS_ID).maybeSingle();

    if (fetchError) {
      console.error('[logoService] Fetch error:', fetchError);
    }

    if (settings?.shop_logo && logoUrl !== settings.shop_logo) {
      console.log('[logoService] Deleting old logo:', settings.shop_logo);
      await deleteLogo(settings.shop_logo);
    }

    const settingsToUpsert: Record<string, any> = userId
      ? { user_id: userId, shop_logo: logoUrl }
      : { id: FIXED_SETTINGS_ID, shop_logo: logoUrl };

    console.log('[logoService] Upserting settings:', settingsToUpsert);

    const { data, error: upsertError } = await supabase
      .from('app_settings')
      .upsert(settingsToUpsert, {
        onConflict: userId ? 'user_id' : 'id',
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
}`;

  const updateShopSettingsBlock = `export async function updateShopSettings(settings: {
  shop_name?: string;
  shop_phone?: string;
  shop_address?: string;
}): Promise<boolean> {
  try {
    console.log('[logoService] updateShopSettings called with:', settings);

    const userId = await getCurrentUserIdFromStorage();
    const settingsToUpsert: Record<string, any> = userId
      ? {
          user_id: userId,
          ...settings,
        }
      : {
          id: FIXED_SETTINGS_ID,
          ...settings,
        };

    const { data, error: upsertError } = await supabase
      .from('app_settings')
      .upsert(settingsToUpsert, {
        onConflict: userId ? 'user_id' : 'id',
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
}`;

  content = replaceOrThrow(
    content,
    /export async function updateShopLogo\(logoUrl: string \| null\): Promise<boolean> \{[\s\S]*?\n\}\n\nexport async function updateShopSettings/,
    `${updateShopLogoBlock}\n\nexport async function updateShopSettings`,
    'logoService updateShopLogo block'
  );

  content = replaceOrThrow(
    content,
    /export async function updateShopSettings\(settings: \{[\s\S]*$/,
    updateShopSettingsBlock + '\n',
    'logoService updateShopSettings block'
  );

  write(filePath, content);
}

function patchLogoHelper() {
  const filePath = path.join(root, 'utils', 'logoHelper.ts');
  backupFile(filePath);
  let content = read(filePath);

  content = replaceOrThrow(
    content,
    /async function getAppReceiptLogoBase64\(forceRefresh = false, userId\?: string\): Promise<string>/,
    'async function getAppReceiptLogoBase64(forceRefresh = false, userId?: string | null): Promise<string>',
    'logoHelper getAppReceiptLogoBase64 signature'
  );

  content = content.replace(
    /export async function getLogoUrl\(userId\?: string\): Promise<string>/,
    'export async function getLogoUrl(userId?: string | null): Promise<string>'
  );

  write(filePath, content);
}

try {
  patchAuthContext();
  patchLogoService();
  patchLogoHelper();
  console.log('Done successfully.');
  console.log(`Backup directory: ${backupDir}`);
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
}
