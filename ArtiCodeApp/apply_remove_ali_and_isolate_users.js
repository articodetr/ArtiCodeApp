const fs = require('fs');
const path = require('path');

const root = process.cwd();
const timestamp = Date.now().toString();
const backupDir = path.join(root, '.articode-remove-ali-backup', timestamp);

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function read(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function backupFile(filePath) {
  ensureDir(backupDir);
  const rel = path.relative(root, filePath);
  const backupPath = path.join(backupDir, rel.replace(/[\\/]/g, '__'));
  ensureDir(path.dirname(backupPath));
  fs.copyFileSync(filePath, backupPath);
  console.log(`Backup created: ${backupPath}`);
}

function write(filePath, content) {
  backupFile(filePath);
  fs.writeFileSync(filePath, content, 'utf8');
  console.log(`Updated: ${path.relative(root, filePath)}`);
}

function replaceOrThrow(source, searchValue, replaceValue, label) {
  if (!source.includes(searchValue)) {
    throw new Error(`Could not find pattern for: ${label}`);
  }
  return source.replace(searchValue, replaceValue);
}

function replaceRegexOrThrow(source, regex, replaceValue, label) {
  if (!regex.test(source)) {
    throw new Error(`Could not find regex pattern for: ${label}`);
  }
  return source.replace(regex, replaceValue);
}

function patchTypesDatabase() {
  const filePath = path.join(root, 'types', 'database.ts');
  let content = read(filePath);

  const before = `export interface AppSettings {\n  id: string;\n  shop_name: string;\n  shop_logo?: string | null;\n  shop_phone?: string | null;\n  shop_address?: string | null;\n  selected_receipt_logo?: string | null;\n  header_layout?: string;\n  header_primary_color?: string;\n  shop_name_en?: string;\n  shop_phone_en?: string;\n  shop_address_en?: string;\n  created_at?: string;\n  updated_at?: string;\n}`;

  const after = `export interface AppSettings {\n  id: string;\n  user_id?: string | null;\n  shop_name: string;\n  shop_logo?: string | null;\n  shop_phone?: string | null;\n  shop_address?: string | null;\n  selected_receipt_logo?: string | null;\n  header_layout?: string;\n  header_primary_color?: string;\n  shop_name_en?: string | null;\n  shop_phone_en?: string | null;\n  shop_address_en?: string | null;\n  whatsapp_account_statement_template?: string | null;\n  whatsapp_share_account_template?: string | null;\n  created_at?: string;\n  updated_at?: string;\n}`;

  content = replaceOrThrow(content, before, after, 'AppSettings interface');
  write(filePath, content);
}

function patchAuthContext() {
  const filePath = path.join(root, 'contexts', 'AuthContext.tsx');
  let content = read(filePath);

  const oldLoadBlock = `  const loadSettings = async () => {\n    try {\n      const FIXED_SETTINGS_ID = '00000000-0000-0000-0000-000000000000';\n      const { data, error } = await supabase\n        .from('app_settings')\n        .select('*')\n        .eq('id', FIXED_SETTINGS_ID)\n        .maybeSingle();\n\n      if (!error && data) {\n        setSettings(data);\n        return;\n      }\n\n      if (!error && !data) {\n        // Create default settings if none exist\n        const defaultSettings = {\n          shop_name: 'ArtiCode',\n          shop_phone: '',\n          shop_address: '',\n        };\n\n        const { data: newSettings } = await supabase\n          .from('app_settings')\n          .insert(defaultSettings)\n          .select()\n          .single();\n\n        if (newSettings) {\n          setSettings(newSettings);\n          return;\n        }\n      }\n\n      // If we get here, set default settings\n      setSettings({\n        id: '',\n        shop_name: 'ArtiCode',\n        shop_phone: '',\n        shop_address: '',\n        created_at: new Date().toISOString(),\n        updated_at: new Date().toISOString(),\n        selected_receipt_logo: null,\n      } as any);\n    } catch (error) {\n      console.error('Error loading settings:', error);\n      // Set default settings on error\n      setSettings({\n        id: '',\n        shop_name: 'ArtiCode',\n        shop_phone: '',\n        shop_address: '',\n        created_at: new Date().toISOString(),\n        updated_at: new Date().toISOString(),\n        selected_receipt_logo: null,\n      } as any);\n    }\n  };\n\n  useEffect(() => {\n    checkAuth();\n    loadSettings();\n  }, []);`;

  const newLoadBlock = `  const buildDefaultSettings = (userId?: string | null): AppSettings => ({\n    id: '',\n    user_id: userId || null,\n    shop_name: 'ArtiCode',\n    shop_phone: '',\n    shop_address: '',\n    shop_logo: null,\n    selected_receipt_logo: null,\n    header_layout: 'centered',\n    header_primary_color: '#4F46E5',\n    shop_name_en: '',\n    shop_phone_en: '',\n    shop_address_en: '',\n    whatsapp_account_statement_template: null,\n    whatsapp_share_account_template: null,\n    created_at: new Date().toISOString(),\n    updated_at: new Date().toISOString(),\n  });\n\n  const loadSettings = async (userId?: string | null) => {\n    const activeUserId = userId || currentUser?.userId || null;\n\n    if (!activeUserId) {\n      setSettings(buildDefaultSettings(null));\n      return;\n    }\n\n    try {\n      const { data: rpcData, error: rpcError } = await supabase.rpc('get_or_create_user_settings', {\n        p_user_id: activeUserId,\n      });\n\n      if (!rpcError && rpcData) {\n        setSettings(rpcData);\n        return;\n      }\n\n      const { data, error } = await supabase\n        .from('app_settings')\n        .select('*')\n        .eq('user_id', activeUserId)\n        .maybeSingle();\n\n      if (!error && data) {\n        setSettings(data);\n        return;\n      }\n\n      setSettings(buildDefaultSettings(activeUserId));\n    } catch (error) {\n      console.error('Error loading settings:', error);\n      setSettings(buildDefaultSettings(activeUserId));\n    }\n  };\n\n  useEffect(() => {\n    checkAuth();\n  }, []);\n\n  useEffect(() => {\n    loadSettings(currentUser?.userId);\n  }, [currentUser?.userId]);`;

  content = replaceOrThrow(content, oldLoadBlock, newLoadBlock, 'loadSettings block');

  content = replaceOrThrow(
    content,
    `        setCurrentUser(user);\n        setIsAuthenticated(true);\n        return { success: true };`,
    `        setCurrentUser(user);\n        setIsAuthenticated(true);\n        await loadSettings(data.id);\n        return { success: true };`,
    'login success block'
  );

  content = replaceOrThrow(
    content,
    `  const logout = async () => {\n    try {\n      await AsyncStorage.removeItem(AUTH_KEY);\n      await AsyncStorage.removeItem(USER_KEY);\n      setIsAuthenticated(false);\n      setCurrentUser(null);\n    } catch (error) {\n      console.error('Error during logout:', error);\n    }\n  };\n\n  const refreshSettings = async () => {\n    await loadSettings();\n  };`,
    `  const logout = async () => {\n    try {\n      await AsyncStorage.removeItem(AUTH_KEY);\n      await AsyncStorage.removeItem(USER_KEY);\n      setIsAuthenticated(false);\n      setCurrentUser(null);\n      setSettings(buildDefaultSettings(null));\n    } catch (error) {\n      console.error('Error during logout:', error);\n    }\n  };\n\n  const refreshSettings = async () => {\n    await loadSettings(currentUser?.userId);\n  };`,
    'logout and refreshSettings block'
  );

  const oldUpdateBlock = `  const updateSettings = async (newSettings: Partial<AppSettings>): Promise<boolean> => {\n    try {\n      console.log('[AuthContext] updateSettings called with:', JSON.stringify(newSettings, null, 2));\n\n      if (newSettings.shop_logo !== undefined && currentUser?.role !== 'admin') {\n        console.error('[AuthContext] Non-admin user attempted to update shop logo');\n        return false;\n      }\n\n      const FIXED_ID = '00000000-0000-0000-0000-000000000000';\n\n      const settingsToUpsert = {\n        id: FIXED_ID,\n        ...newSettings,\n      };\n\n      console.log('[AuthContext] Performing upsert with data:', JSON.stringify(settingsToUpsert, null, 2));\n\n      const { data, error: upsertError } = await supabase\n        .from('app_settings')\n        .upsert(settingsToUpsert, {\n          onConflict: 'id',\n          ignoreDuplicates: false,\n        })\n        .select();\n\n      if (upsertError) {\n        console.error('[AuthContext] Upsert error:', upsertError);\n        console.error('[AuthContext] Error code:', upsertError.code);\n        console.error('[AuthContext] Error message:', upsertError.message);\n        console.error('[AuthContext] Error details:', JSON.stringify(upsertError, null, 2));\n        throw upsertError;\n      }\n\n      console.log('[AuthContext] Settings upserted successfully:', data);\n\n      await loadSettings();\n      console.log('[AuthContext] Settings reloaded');\n      return true;\n    } catch (error) {\n      console.error('[AuthContext] Error updating settings:', error);\n      if (error instanceof Error) {\n        console.error('[AuthContext] Error name:', error.name);\n        console.error('[AuthContext] Error message:', error.message);\n        console.error('[AuthContext] Error stack:', error.stack);\n      }\n      return false;\n    }\n  };`;

  const newUpdateBlock = `  const updateSettings = async (newSettings: Partial<AppSettings>): Promise<boolean> => {\n    try {\n      const activeUserId = currentUser?.userId;\n\n      if (!activeUserId) {\n        console.error('[AuthContext] Cannot update settings without current user');\n        return false;\n      }\n\n      console.log('[AuthContext] updateSettings called with:', JSON.stringify(newSettings, null, 2));\n\n      const settingsToUpsert = {\n        user_id: activeUserId,\n        ...newSettings,\n      };\n\n      console.log('[AuthContext] Performing upsert with data:', JSON.stringify(settingsToUpsert, null, 2));\n\n      const { data, error: upsertError } = await supabase\n        .from('app_settings')\n        .upsert(settingsToUpsert, {\n          onConflict: 'user_id',\n          ignoreDuplicates: false,\n        })\n        .select();\n\n      if (upsertError) {\n        console.error('[AuthContext] Upsert error:', upsertError);\n        console.error('[AuthContext] Error code:', upsertError.code);\n        console.error('[AuthContext] Error message:', upsertError.message);\n        console.error('[AuthContext] Error details:', JSON.stringify(upsertError, null, 2));\n        throw upsertError;\n      }\n\n      console.log('[AuthContext] Settings upserted successfully:', data);\n\n      await loadSettings(activeUserId);\n      console.log('[AuthContext] Settings reloaded');\n      return true;\n    } catch (error) {\n      console.error('[AuthContext] Error updating settings:', error);\n      if (error instanceof Error) {\n        console.error('[AuthContext] Error name:', error.name);\n        console.error('[AuthContext] Error message:', error.message);\n        console.error('[AuthContext] Error stack:', error.stack);\n      }\n      return false;\n    }\n  };`;

  content = replaceOrThrow(content, oldUpdateBlock, newUpdateBlock, 'updateSettings block');
  write(filePath, content);
}

function patchLogoService() {
  const filePath = path.join(root, 'services', 'logoService.ts');
  let content = read(filePath);

  content = replaceOrThrow(
    content,
    `import { supabase } from '@/lib/supabase';`,
    `import { supabase } from '@/lib/supabase';\nimport AsyncStorage from '@react-native-async-storage/async-storage';`,
    'logoService AsyncStorage import'
  );

  content = replaceOrThrow(
    content,
    `const BUCKET_NAME = 'shop-logos';\nconst FIXED_SETTINGS_ID = '00000000-0000-0000-0000-000000000000';`,
    `const BUCKET_NAME = 'shop-logos';\nconst USER_KEY = '@money_transfer_current_user';`,
    'logoService constants'
  );

  content = replaceOrThrow(
    content,
    `export async function updateShopLogo(logoUrl: string | null): Promise<boolean> {`,
    `async function getCurrentUserId(): Promise<string | null> {\n  try {\n    const rawUser = await AsyncStorage.getItem(USER_KEY);\n    if (!rawUser) return null;\n\n    const parsed = JSON.parse(rawUser);\n    return parsed?.userId || null;\n  } catch (error) {\n    console.error('[logoService] Error reading current user:', error);\n    return null;\n  }\n}\n\nexport async function updateShopLogo(logoUrl: string | null): Promise<boolean> {`,
    'insert getCurrentUserId helper'
  );

  const oldUpdateShopLogo = `export async function updateShopLogo(logoUrl: string | null): Promise<boolean> {\n  try {\n    console.log('[logoService] updateShopLogo called with logoUrl:', logoUrl);\n\n    const { data: settings, error: fetchError } = await supabase\n      .from('app_settings')\n      .select('id, shop_logo')\n      .eq('id', FIXED_SETTINGS_ID)\n      .maybeSingle();\n\n    if (fetchError) {\n      console.error('[logoService] Fetch error:', fetchError);\n    }\n\n    if (settings?.shop_logo && logoUrl !== settings.shop_logo) {\n      console.log('[logoService] Deleting old logo:', settings.shop_logo);\n      await deleteLogo(settings.shop_logo);\n    }\n\n    const settingsToUpsert = {\n      id: FIXED_SETTINGS_ID,\n      shop_logo: logoUrl,\n    };\n\n    console.log('[logoService] Upserting settings:', settingsToUpsert);\n\n    const { data, error: upsertError } = await supabase\n      .from('app_settings')\n      .upsert(settingsToUpsert, {\n        onConflict: 'id',\n        ignoreDuplicates: false,\n      })\n      .select();\n\n    if (upsertError) {\n      console.error('[logoService] Upsert error:', upsertError);\n      console.error('[logoService] Error details:', JSON.stringify(upsertError, null, 2));\n      return false;\n    }\n\n    console.log('[logoService] Settings upserted successfully:', data);\n    return true;\n  } catch (error) {\n    console.error('[logoService] Error updating shop logo:', error);\n    if (error instanceof Error) {\n      console.error('[logoService] Error message:', error.message);\n    }\n    return false;\n  }\n}`;

  const newUpdateShopLogo = `export async function updateShopLogo(logoUrl: string | null): Promise<boolean> {\n  try {\n    console.log('[logoService] updateShopLogo called with logoUrl:', logoUrl);\n\n    const userId = await getCurrentUserId();\n    if (!userId) {\n      console.error('[logoService] Cannot update logo without current user');\n      return false;\n    }\n\n    const { data: settings, error: fetchError } = await supabase\n      .from('app_settings')\n      .select('id, user_id, shop_logo')\n      .eq('user_id', userId)\n      .maybeSingle();\n\n    if (fetchError) {\n      console.error('[logoService] Fetch error:', fetchError);\n    }\n\n    if (settings?.shop_logo && logoUrl !== settings.shop_logo) {\n      console.log('[logoService] Deleting old logo:', settings.shop_logo);\n      await deleteLogo(settings.shop_logo);\n    }\n\n    const settingsToUpsert = {\n      user_id: userId,\n      shop_logo: logoUrl,\n    };\n\n    console.log('[logoService] Upserting settings:', settingsToUpsert);\n\n    const { data, error: upsertError } = await supabase\n      .from('app_settings')\n      .upsert(settingsToUpsert, {\n        onConflict: 'user_id',\n        ignoreDuplicates: false,\n      })\n      .select();\n\n    if (upsertError) {\n      console.error('[logoService] Upsert error:', upsertError);\n      console.error('[logoService] Error details:', JSON.stringify(upsertError, null, 2));\n      return false;\n    }\n\n    console.log('[logoService] Settings upserted successfully:', data);\n    return true;\n  } catch (error) {\n    console.error('[logoService] Error updating shop logo:', error);\n    if (error instanceof Error) {\n      console.error('[logoService] Error message:', error.message);\n    }\n    return false;\n  }\n}`;

  content = replaceOrThrow(content, oldUpdateShopLogo, newUpdateShopLogo, 'updateShopLogo function');

  const oldUpdateShopSettings = `export async function updateShopSettings(settings: {\n  shop_name?: string;\n  shop_phone?: string;\n  shop_address?: string;\n}): Promise<boolean> {\n  try {\n    console.log('[logoService] updateShopSettings called with:', settings);\n\n    const settingsToUpsert = {\n      id: FIXED_SETTINGS_ID,\n      ...settings,\n    };\n\n    const { data, error: upsertError } = await supabase\n      .from('app_settings')\n      .upsert(settingsToUpsert, {\n        onConflict: 'id',\n        ignoreDuplicates: false,\n      })\n      .select();\n\n    if (upsertError) {\n      console.error('[logoService] Upsert error:', upsertError);\n      throw upsertError;\n    }\n\n    console.log('[logoService] Settings upserted successfully:', data);\n    return true;\n  } catch (error) {\n    console.error('[logoService] Error updating shop settings:', error);\n    return false;\n  }\n}`;

  const newUpdateShopSettings = `export async function updateShopSettings(settings: {\n  shop_name?: string;\n  shop_phone?: string;\n  shop_address?: string;\n}): Promise<boolean> {\n  try {\n    console.log('[logoService] updateShopSettings called with:', settings);\n\n    const userId = await getCurrentUserId();\n    if (!userId) {\n      console.error('[logoService] Cannot update settings without current user');\n      return false;\n    }\n\n    const settingsToUpsert = {\n      user_id: userId,\n      ...settings,\n    };\n\n    const { data, error: upsertError } = await supabase\n      .from('app_settings')\n      .upsert(settingsToUpsert, {\n        onConflict: 'user_id',\n        ignoreDuplicates: false,\n      })\n      .select();\n\n    if (upsertError) {\n      console.error('[logoService] Upsert error:', upsertError);\n      throw upsertError;\n    }\n\n    console.log('[logoService] Settings upserted successfully:', data);\n    return true;\n  } catch (error) {\n    console.error('[logoService] Error updating shop settings:', error);\n    return false;\n  }\n}`;

  content = replaceOrThrow(content, oldUpdateShopSettings, newUpdateShopSettings, 'updateShopSettings function');
  write(filePath, content);
}

function patchLogoHelper() {
  const filePath = path.join(root, 'utils', 'logoHelper.ts');
  let content = read(filePath);

  content = replaceOrThrow(
    content,
    `const BUCKET_NAME = 'shop-logos';\nconst FIXED_SETTINGS_ID = '00000000-0000-0000-0000-000000000000';\nconst DEFAULT_RECEIPT_HEADER = require('../assets/images/default-header.png');`,
    `const BUCKET_NAME = 'shop-logos';\nconst DEFAULT_RECEIPT_HEADER = require('../assets/images/default-header.png');`,
    'logoHelper fixed settings constant'
  );

  const oldGetAppReceipt = `async function getAppReceiptLogoBase64(forceRefresh = false): Promise<string> {\n  try {\n    const { data: settings, error } = await supabase\n      .from('app_settings')\n      .select('selected_receipt_logo, shop_logo')\n      .eq('id', FIXED_SETTINGS_ID)\n      .maybeSingle();\n\n    if (error || !settings) {\n      return await getBundledDefaultHeader();\n    }\n\n    if (settings.selected_receipt_logo === 'DEFAULT') {\n      return await getBundledDefaultHeader();\n    }\n\n    const logoUrl = settings.selected_receipt_logo || settings.shop_logo;\n\n    if (!logoUrl || logoUrl === 'DEFAULT') {\n      return await getBundledDefaultHeader();\n    }\n\n    if (\n      logoUrl.includes(BUCKET_NAME) ||\n      logoUrl.startsWith('http://') ||\n      logoUrl.startsWith('https://')\n    ) {\n      const converted = await downloadAndConvertImageToBase64(logoUrl);\n      return converted || (await getBundledDefaultHeader());\n    }\n\n    return await getBundledDefaultHeader();\n  } catch (error) {\n    console.error('[logoHelper] Error in getAppReceiptLogoBase64:', error);\n    return await getBundledDefaultHeader();\n  }\n}`;

  const newGetAppReceipt = `async function getAppReceiptLogoBase64(\n  forceRefresh = false,\n  userId?: string | null\n): Promise<string> {\n  try {\n    if (!userId) {\n      return await getBundledDefaultHeader();\n    }\n\n    const { data: settings, error } = await supabase\n      .from('app_settings')\n      .select('selected_receipt_logo, shop_logo')\n      .eq('user_id', userId)\n      .maybeSingle();\n\n    if (error || !settings) {\n      return await getBundledDefaultHeader();\n    }\n\n    if (settings.selected_receipt_logo === 'DEFAULT') {\n      return await getBundledDefaultHeader();\n    }\n\n    const logoUrl = settings.selected_receipt_logo || settings.shop_logo;\n\n    if (!logoUrl || logoUrl === 'DEFAULT') {\n      return await getBundledDefaultHeader();\n    }\n\n    if (\n      logoUrl.includes(BUCKET_NAME) ||\n      logoUrl.startsWith('http://') ||\n      logoUrl.startsWith('https://')\n    ) {\n      const converted = await downloadAndConvertImageToBase64(logoUrl);\n      return converted || (await getBundledDefaultHeader());\n    }\n\n    return await getBundledDefaultHeader();\n  } catch (error) {\n    console.error('[logoHelper] Error in getAppReceiptLogoBase64:', error);\n    return await getBundledDefaultHeader();\n  }\n}`;

  content = replaceOrThrow(content, oldGetAppReceipt, newGetAppReceipt, 'getAppReceiptLogoBase64 function');

  content = replaceOrThrow(content, `      return await getAppReceiptLogoBase64(forceRefresh);`, `      return await getAppReceiptLogoBase64(forceRefresh, context.userId);`, 'default receipt logo call');
  content = replaceOrThrow(content, `      return banner || (await getAppReceiptLogoBase64(forceRefresh));`, `      return banner || (await getAppReceiptLogoBase64(forceRefresh, context.userId));`, 'banner fallback receipt logo call');
  content = replaceOrThrow(content, `    return await getAppReceiptLogoBase64(forceRefresh);`, `    return await getAppReceiptLogoBase64(forceRefresh, context.userId);`, 'receipt logo fallback call #1');
  content = replaceOrThrow(content, `    return await getAppReceiptLogoBase64(forceRefresh);`, `    return await getAppReceiptLogoBase64(forceRefresh, context.userId);`, 'receipt logo fallback call #2');

  const oldGetLogoUrl = `export async function getLogoUrl(): Promise<string> {\n  try {\n    const defaultAsset = Asset.fromModule(DEFAULT_RECEIPT_HEADER);\n    const defaultUri = defaultAsset.uri || '';\n\n    const { data: settings, error } = await supabase\n      .from('app_settings')\n      .select('shop_logo')\n      .eq('id', FIXED_SETTINGS_ID)\n      .maybeSingle();\n\n    if (error || !settings?.shop_logo) {\n      return defaultUri;\n    }\n\n    return settings.shop_logo;\n  } catch (error) {\n    console.error('[logoHelper] Error getting logo URL:', error);\n    return Asset.fromModule(DEFAULT_RECEIPT_HEADER).uri || '';\n  }\n}`;

  const newGetLogoUrl = `export async function getLogoUrl(userId?: string | null): Promise<string> {\n  try {\n    const defaultAsset = Asset.fromModule(DEFAULT_RECEIPT_HEADER);\n    const defaultUri = defaultAsset.uri || '';\n\n    if (!userId) {\n      return defaultUri;\n    }\n\n    const { data: settings, error } = await supabase\n      .from('app_settings')\n      .select('shop_logo')\n      .eq('user_id', userId)\n      .maybeSingle();\n\n    if (error || !settings?.shop_logo) {\n      return defaultUri;\n    }\n\n    return settings.shop_logo;\n  } catch (error) {\n    console.error('[logoHelper] Error getting logo URL:', error);\n    return Asset.fromModule(DEFAULT_RECEIPT_HEADER).uri || '';\n  }\n}`;

  content = replaceOrThrow(content, oldGetLogoUrl, newGetLogoUrl, 'getLogoUrl function');
  write(filePath, content);
}

function patchWhatsAppTemplatesUtil() {
  const filePath = path.join(root, 'utils', 'whatsappTemplates.ts');
  let content = read(filePath);

  const oldFetch = `export async function fetchWhatsAppTemplates(): Promise<WhatsAppTemplates> {\n  try {\n    const { data, error } = await supabase\n      .from('app_settings')\n      .select('whatsapp_account_statement_template, whatsapp_share_account_template')\n      .eq('id', APP_SETTINGS_FIXED_ID)\n      .maybeSingle();\n\n    if (error) {\n      console.error('Error fetching WhatsApp templates:', error);\n      return DEFAULT_WHATSAPP_TEMPLATES;\n    }\n\n    if (!data) {\n      return DEFAULT_WHATSAPP_TEMPLATES;\n    }\n\n    return {\n      account_statement:\n        data.whatsapp_account_statement_template ||\n        DEFAULT_WHATSAPP_TEMPLATES.account_statement,\n      share_account:\n        data.whatsapp_share_account_template ||\n        DEFAULT_WHATSAPP_TEMPLATES.share_account,\n    };\n  } catch (error) {\n    console.error('Error fetching WhatsApp templates:', error);\n    return DEFAULT_WHATSAPP_TEMPLATES;\n  }\n}`;

  const newFetch = `export async function fetchWhatsAppTemplates(\n  userId?: string | null\n): Promise<WhatsAppTemplates> {\n  try {\n    if (!userId) {\n      return DEFAULT_WHATSAPP_TEMPLATES;\n    }\n\n    const { data, error } = await supabase\n      .from('app_settings')\n      .select('whatsapp_account_statement_template, whatsapp_share_account_template')\n      .eq('user_id', userId)\n      .maybeSingle();\n\n    if (error) {\n      console.error('Error fetching WhatsApp templates:', error);\n      return DEFAULT_WHATSAPP_TEMPLATES;\n    }\n\n    if (!data) {\n      return DEFAULT_WHATSAPP_TEMPLATES;\n    }\n\n    return {\n      account_statement:\n        data.whatsapp_account_statement_template ||\n        DEFAULT_WHATSAPP_TEMPLATES.account_statement,\n      share_account:\n        data.whatsapp_share_account_template ||\n        DEFAULT_WHATSAPP_TEMPLATES.share_account,\n    };\n  } catch (error) {\n    console.error('Error fetching WhatsApp templates:', error);\n    return DEFAULT_WHATSAPP_TEMPLATES;\n  }\n}`;

  content = replaceOrThrow(content, oldFetch, newFetch, 'fetchWhatsAppTemplates function');
  write(filePath, content);
}

function patchWhatsAppTemplatesPage() {
  const filePath = path.join(root, 'app', 'whatsapp-templates.tsx');
  let content = read(filePath);

  content = replaceOrThrow(
    content,
    `import { supabase } from '@/lib/supabase';`,
    `import { supabase } from '@/lib/supabase';\nimport { useAuth } from '@/contexts/AuthContext';`,
    'whatsapp page useAuth import'
  );

  content = replaceOrThrow(
    content,
    `  APP_SETTINGS_FIXED_ID,\n  DEFAULT_WHATSAPP_TEMPLATES,`,
    `  DEFAULT_WHATSAPP_TEMPLATES,`,
    'remove fixed id import'
  );

  content = replaceOrThrow(
    content,
    `export default function WhatsAppTemplatesScreen() {\n  const router = useRouter();`,
    `export default function WhatsAppTemplatesScreen() {\n  const router = useRouter();\n  const { currentUser } = useAuth();`,
    'whatsapp page currentUser hook'
  );

  content = replaceOrThrow(
    content,
    `  useEffect(() => {\n    loadTemplates();\n  }, []);\n\n  async function loadTemplates() {\n    try {\n      const loadedTemplates = await fetchWhatsAppTemplates();`,
    `  useEffect(() => {\n    loadTemplates(currentUser?.userId);\n  }, [currentUser?.userId]);\n\n  async function loadTemplates(userId?: string | null) {\n    try {\n      const loadedTemplates = await fetchWhatsAppTemplates(userId);`,
    'whatsapp page loadTemplates'
  );

  const oldSave = `  async function handleSave() {\n    if (!templates.account_statement.trim() || !templates.share_account.trim()) {\n      Alert.alert('تنبيه', 'يجب تعبئة القالبين قبل الحفظ');\n      return;\n    }\n\n    setIsSaving(true);\n\n    try {\n      const { error } = await supabase.from('app_settings').upsert(\n        {\n          id: APP_SETTINGS_FIXED_ID,\n          whatsapp_account_statement_template: templates.account_statement,\n          whatsapp_share_account_template: templates.share_account,\n        },\n        { onConflict: 'id' }\n      );\n\n      if (error) throw error;\n\n      Alert.alert('تم', 'تم حفظ القوالب بنجاح');\n    } catch (error) {\n      console.error('Error saving templates:', error);\n      Alert.alert('خطأ', 'حدث خطأ أثناء حفظ القوالب');\n    } finally {\n      setIsSaving(false);\n    }\n  }`;

  const newSave = `  async function handleSave() {\n    if (!templates.account_statement.trim() || !templates.share_account.trim()) {\n      Alert.alert('تنبيه', 'يجب تعبئة القالبين قبل الحفظ');\n      return;\n    }\n\n    if (!currentUser?.userId) {\n      Alert.alert('خطأ', 'يجب تسجيل الدخول أولاً');\n      return;\n    }\n\n    setIsSaving(true);\n\n    try {\n      const { error } = await supabase.from('app_settings').upsert(\n        {\n          user_id: currentUser.userId,\n          whatsapp_account_statement_template: templates.account_statement,\n          whatsapp_share_account_template: templates.share_account,\n        },\n        { onConflict: 'user_id' }\n      );\n\n      if (error) throw error;\n\n      Alert.alert('تم', 'تم حفظ القوالب بنجاح');\n    } catch (error) {\n      console.error('Error saving templates:', error);\n      Alert.alert('خطأ', 'حدث خطأ أثناء حفظ القوالب');\n    } finally {\n      setIsSaving(false);\n    }\n  }`;

  content = replaceOrThrow(content, oldSave, newSave, 'whatsapp page save handler');
  write(filePath, content);
}

function patchUsersManagement() {
  const filePath = path.join(root, 'app', 'users-management.tsx');
  let content = read(filePath);

  content = replaceOrThrow(
    content,
    `  const handleDeleteUser = (user: UserData) => {\n    // منع حذف Ali\n    if (user.user_name.toLowerCase() === 'ali') {\n      Alert.alert('غير مسموح', 'لا يمكن حذف حساب Ali - هذا هو الحساب الرئيسي');\n      return;\n    }\n\n    // فقط الـ admin يستطيع حذف المستخدمين`,
    `  const handleDeleteUser = (user: UserData) => {\n    if (currentUser?.userId === user.id) {\n      Alert.alert('غير مسموح', 'لا يمكن حذف حسابك الحالي أثناء تسجيل الدخول');\n      return;\n    }\n\n    // فقط الـ admin يستطيع حذف المستخدمين`,
    'users-management delete Ali guard'
  );

  content = replaceOrThrow(
    content,
    `  const renderUserCard = (user: UserData) => {\n    const isAli = user.user_name.toLowerCase() === 'ali';\n    const canDelete = isAdmin && !isAli;\n    const isOwnAccount = currentUser?.userId === user.id;`,
    `  const renderUserCard = (user: UserData) => {\n    const canDelete = isAdmin && currentUser?.userId !== user.id;\n    const isOwnAccount = currentUser?.userId === user.id;`,
    'users-management renderUserCard Ali logic'
  );

  write(filePath, content);
}

function patchQuickAddMovementSheet() {
  const filePath = path.join(root, 'components', 'QuickAddMovementSheet.tsx');
  let content = read(filePath);

  content = replaceOrThrow(
    content,
    `      const actualAmount = parseFloat(amount);\n\n      const { data: insertedData, error } = await supabase.rpc('insert_movement_with_user', {`,
    `      const actualAmount = parseFloat(amount);\n      const shopActorName = currentUser.fullName || currentUser.userName || 'المحل';\n\n      const { data: insertedData, error } = await supabase.rpc('insert_movement_with_user', {`,
    'quick add shopActorName'
  );

  content = replaceOrThrow(
    content,
    `        p_sender_name: movementType === 'outgoing' ? customerName : 'علي هادي علي الرازحي',\n        p_beneficiary_name: movementType === 'outgoing' ? 'علي هادي علي الرازحي' : customerName,`,
    `        p_sender_name: movementType === 'outgoing' ? customerName : shopActorName,\n        p_beneficiary_name: movementType === 'outgoing' ? shopActorName : customerName,`,
    'quick add hardcoded Ali names'
  );

  write(filePath, content);
}

function writeMigration() {
  const migrationsDir = path.join(root, 'supabase', 'migrations');
  ensureDir(migrationsDir);
  const filePath = path.join(migrationsDir, '20260502030000_remove_ali_and_isolate_user_settings.sql');
  const sql = `begin;\n\n-- 1) Remove old fixed-owner protection tied to Ali/A\ndrop trigger if exists prevent_ali_deletion_trigger on public.app_security;\ndrop function if exists public.prevent_ali_deletion();\n\n-- 2) Ensure app_settings has the current schema used by the app\nalter table public.app_settings\n  add column if not exists user_id uuid references public.app_security(id) on delete cascade,\n  add column if not exists shop_logo text,\n  add column if not exists header_layout text default 'centered',\n  add column if not exists header_primary_color text default '#4F46E5',\n  add column if not exists shop_name_en text,\n  add column if not exists shop_phone_en text,\n  add column if not exists shop_address_en text,\n  add column if not exists selected_receipt_logo text,\n  add column if not exists whatsapp_account_statement_template text,\n  add column if not exists whatsapp_share_account_template text,\n  add column if not exists created_at timestamptz default now(),\n  add column if not exists updated_at timestamptz default now();\n\ncreate unique index if not exists app_settings_user_id_unique_idx\n  on public.app_settings(user_id)\n  where user_id is not null;\n\n-- 3) Copy any old shared settings row into per-user settings rows\ndo $$\ndeclare\n  v_shared record;\nbegin\n  select *\n  into v_shared\n  from public.app_settings\n  where user_id is null\n  order by updated_at desc nulls last, id\n  limit 1;\n\n  if v_shared is null then\n    insert into public.app_settings (id, shop_name, created_at, updated_at)\n    values ('00000000-0000-0000-0000-000000000000', 'ArtiCode', now(), now())\n    on conflict (id) do nothing;\n\n    select *\n    into v_shared\n    from public.app_settings\n    where id = '00000000-0000-0000-0000-000000000000'\n    limit 1;\n  end if;\n\n  insert into public.app_settings (\n    id,\n    user_id,\n    shop_name,\n    shop_logo,\n    shop_phone,\n    shop_address,\n    selected_receipt_logo,\n    header_layout,\n    header_primary_color,\n    shop_name_en,\n    shop_phone_en,\n    shop_address_en,\n    whatsapp_account_statement_template,\n    whatsapp_share_account_template,\n    created_at,\n    updated_at\n  )\n  select\n    gen_random_uuid(),\n    u.id,\n    coalesce(v_shared.shop_name, 'ArtiCode'),\n    v_shared.shop_logo,\n    v_shared.shop_phone,\n    v_shared.shop_address,\n    v_shared.selected_receipt_logo,\n    coalesce(v_shared.header_layout, 'centered'),\n    coalesce(v_shared.header_primary_color, '#4F46E5'),\n    v_shared.shop_name_en,\n    v_shared.shop_phone_en,\n    v_shared.shop_address_en,\n    v_shared.whatsapp_account_statement_template,\n    v_shared.whatsapp_share_account_template,\n    coalesce(v_shared.created_at, now()),\n    now()\n  from public.app_security u\n  where not exists (\n    select 1 from public.app_settings s where s.user_id = u.id\n  );\nend $$;\n\n-- 4) Helper function used by the app to fetch/create current-user settings\ncreate or replace function public.get_or_create_user_settings(p_user_id uuid)\nreturns public.app_settings\nlanguage plpgsql\nsecurity definer\nset search_path = public\nas $$\ndeclare\n  v_settings public.app_settings;\nbegin\n  select *\n  into v_settings\n  from public.app_settings\n  where user_id = p_user_id\n  limit 1;\n\n  if found then\n    return v_settings;\n  end if;\n\n  insert into public.app_settings (\n    user_id,\n    shop_name,\n    header_layout,\n    header_primary_color,\n    created_at,\n    updated_at\n  ) values (\n    p_user_id,\n    'ArtiCode',\n    'centered',\n    '#4F46E5',\n    now(),\n    now()\n  )\n  returning * into v_settings;\n\n  return v_settings;\nend;\n$$;\n\n-- 5) Make app_settings private per user instead of globally shared\nalter table public.app_settings enable row level security;\n\ndrop policy if exists \"Allow all operations on app_settings\" on public.app_settings;\ndrop policy if exists \"Allow anon and authenticated users full access to app_settings\" on public.app_settings;\ndrop policy if exists \"Allow read access to app_settings\" on public.app_settings;\ndrop policy if exists \"Allow update access to app_settings\" on public.app_settings;\ndrop policy if exists \"Allow insert access to app_settings\" on public.app_settings;\ndrop policy if exists \"Allow app settings read\" on public.app_settings;\ndrop policy if exists \"Allow app settings update\" on public.app_settings;\ndrop policy if exists \"Users can read own app settings\" on public.app_settings;\ndrop policy if exists \"Users can insert own app settings\" on public.app_settings;\ndrop policy if exists \"Users can update own app settings\" on public.app_settings;\n\ncreate policy \"Users can read own app settings\"\n  on public.app_settings for select\n  to anon, authenticated\n  using (\n    user_id = (\n      select id\n      from public.app_security\n      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))\n      limit 1\n    )\n    or exists (\n      select 1\n      from public.app_security\n      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))\n        and role = 'admin'\n    )\n  );\n\ncreate policy \"Users can insert own app settings\"\n  on public.app_settings for insert\n  to anon, authenticated\n  with check (\n    user_id = (\n      select id\n      from public.app_security\n      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))\n      limit 1\n    )\n    or exists (\n      select 1\n      from public.app_security\n      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))\n        and role = 'admin'\n    )\n  );\n\ncreate policy \"Users can update own app settings\"\n  on public.app_settings for update\n  to anon, authenticated\n  using (\n    user_id = (\n      select id\n      from public.app_security\n      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))\n      limit 1\n    )\n    or exists (\n      select 1\n      from public.app_security\n      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))\n        and role = 'admin'\n    )\n  )\n  with check (\n    user_id = (\n      select id\n      from public.app_security\n      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))\n      limit 1\n    )\n    or exists (\n      select 1\n      from public.app_security\n      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))\n        and role = 'admin'\n    )\n  );\n\n-- 6) Keep delete_user_by_id free from Ali-specific restrictions\ncreate or replace function public.delete_user_by_id(p_user_id uuid)\nreturns json\nlanguage plpgsql\nas $$\ndeclare\n  v_user_name text;\n  v_result json;\nbegin\n  select user_name into v_user_name\n  from public.app_security\n  where id = p_user_id;\n\n  if v_user_name is null then\n    return json_build_object(\n      'success', false,\n      'message', 'المستخدم غير موجود'\n    );\n  end if;\n\n  delete from public.app_security where id = p_user_id;\n\n  v_result := json_build_object(\n    'success', true,\n    'message', 'تم حذف المستخدم بنجاح',\n    'user_name', v_user_name\n  );\n\n  return v_result;\nend;\n$$;\n\ncommit;\n`;
  fs.writeFileSync(filePath, sql, 'utf8');
  console.log(`Wrote migration: ${path.relative(root, filePath)}`);
}

function writeReadme() {
  const filePath = path.join(root, 'REMOVE_ALI_AND_ISOLATE_USERS_README.txt');
  const text = [
    'This patch does two things:',
    '1) removes hard-coded Ali owner logic from the app and SQL migration layer',
    '2) isolates app settings per user via app_settings.user_id instead of one shared fixed row',
    '',
    'What changed:',
    '- contexts/AuthContext.tsx',
    '- services/logoService.ts',
    '- utils/logoHelper.ts',
    '- utils/whatsappTemplates.ts',
    '- app/whatsapp-templates.tsx',
    '- app/users-management.tsx',
    '- components/QuickAddMovementSheet.tsx',
    '- types/database.ts',
    '- supabase/migrations/20260502030000_remove_ali_and_isolate_user_settings.sql',
    '',
    'Next steps:',
    '1) Run the migration SQL in Supabase.',
    '2) Run npm run typecheck',
    '3) Test with two different user accounts.',
  ].join('\n');
  fs.writeFileSync(filePath, text, 'utf8');
  console.log(`Wrote: ${path.relative(root, filePath)}`);
}

function main() {
  const requiredFiles = [
    path.join(root, 'contexts', 'AuthContext.tsx'),
    path.join(root, 'services', 'logoService.ts'),
    path.join(root, 'utils', 'logoHelper.ts'),
    path.join(root, 'utils', 'whatsappTemplates.ts'),
    path.join(root, 'app', 'whatsapp-templates.tsx'),
    path.join(root, 'app', 'users-management.tsx'),
    path.join(root, 'components', 'QuickAddMovementSheet.tsx'),
    path.join(root, 'types', 'database.ts'),
    path.join(root, 'supabase', 'migrations'),
  ];

  for (const item of requiredFiles) {
    if (!fs.existsSync(item)) {
      throw new Error(`Missing required path: ${item}`);
    }
  }

  patchTypesDatabase();
  patchAuthContext();
  patchLogoService();
  patchLogoHelper();
  patchWhatsAppTemplatesUtil();
  patchWhatsAppTemplatesPage();
  patchUsersManagement();
  patchQuickAddMovementSheet();
  writeMigration();
  writeReadme();

  console.log('Done successfully.');
  console.log(`Backup directory: ${backupDir}`);
}

main();
