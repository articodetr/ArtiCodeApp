const fs = require('fs');
const path = require('path');

const root = process.cwd();
const backupDir = path.join(root, '.articode-typecheck-hotfix-backup', String(Date.now()));

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function backupFile(targetPath) {
  ensureDir(backupDir);
  const rel = path.relative(root, targetPath).replace(/[\\/]/g, '__');
  const backupPath = path.join(backupDir, rel);
  ensureDir(path.dirname(backupPath));
  fs.copyFileSync(targetPath, backupPath);
  console.log('Backup created:', backupPath);
}

function replaceInFile(relPath, replacer) {
  const targetPath = path.join(root, ...relPath.split('/'));
  if (!fs.existsSync(targetPath)) {
    throw new Error(`File not found: ${relPath}`);
  }
  backupFile(targetPath);
  const source = fs.readFileSync(targetPath, 'utf8');
  const updated = replacer(source);
  if (updated === source) {
    throw new Error(`No changes applied to ${relPath}. Expected pattern was not found.`);
  }
  fs.writeFileSync(targetPath, updated, 'utf8');
  console.log('Updated:', relPath);
}

replaceInFile('contexts/AuthContext.tsx', (source) => {
  const pattern = /const updateSettings = async \(newSettings: Partial<AppSettings>\): Promise<boolean> => \{[\s\S]*?\n  \};/;
  const replacement = `const updateSettings = async (newSettings: Partial<AppSettings>): Promise<boolean> => {\n    try {\n      console.log('[AuthContext] updateSettings called with:', JSON.stringify(newSettings, null, 2));\n\n      const activeUserId = currentUser?.userId;\n      if (!activeUserId) {\n        console.error('[AuthContext] Cannot update settings without an authenticated user');\n        return false;\n      }\n\n      if (newSettings.shop_logo !== undefined && currentUser?.role !== 'admin') {\n        console.error('[AuthContext] Non-admin user attempted to update shop logo');\n        return false;\n      }\n\n      const settingsToUpsert = {\n        user_id: activeUserId,\n        ...newSettings,\n      };\n\n      console.log('[AuthContext] Performing upsert with data:', JSON.stringify(settingsToUpsert, null, 2));\n\n      const { data, error: upsertError } = await supabase\n        .from('app_settings')\n        .upsert(settingsToUpsert, {\n          onConflict: 'user_id',\n          ignoreDuplicates: false,\n        })\n        .select();\n\n      if (upsertError) {\n        console.error('[AuthContext] Upsert error:', upsertError);\n        console.error('[AuthContext] Error code:', upsertError.code);\n        console.error('[AuthContext] Error message:', upsertError.message);\n        console.error('[AuthContext] Error details:', JSON.stringify(upsertError, null, 2));\n        throw upsertError;\n      }\n\n      console.log('[AuthContext] Settings upserted successfully:', data);\n\n      await loadSettings(activeUserId);\n      console.log('[AuthContext] Settings reloaded');\n      return true;\n    } catch (error) {\n      console.error('[AuthContext] Error updating settings:', error);\n      if (error instanceof Error) {\n        console.error('[AuthContext] Error name:', error.name);\n        console.error('[AuthContext] Error message:', error.message);\n        console.error('[AuthContext] Error stack:', error.stack);\n      }\n      return false;\n    }\n  };`;
  return source.replace(pattern, replacement);
});

replaceInFile('services/logoService.ts', (source) => {
  let out = source;

  out = out.replace(
    /export async function updateShopLogo\(logoUrl: string \| null\): Promise<boolean> \{[\s\S]*?\n\}/,
    `export async function updateShopLogo(logoUrl: string | null): Promise<boolean> {\n  try {\n    console.log('[logoService] updateShopLogo called with logoUrl:', logoUrl);\n\n    const userId = await getCurrentUserId();\n    const onConflictColumn = userId ? 'user_id' : 'id';\n\n    const settingsQuery = supabase\n      .from('app_settings')\n      .select('id, user_id, shop_logo')\n      .limit(1);\n\n    const { data: settings, error: fetchError } = userId\n      ? await settingsQuery.eq('user_id', userId).maybeSingle()\n      : await settingsQuery.eq('id', FIXED_SETTINGS_ID).maybeSingle();\n\n    if (fetchError) {\n      console.error('[logoService] Fetch error:', fetchError);\n    }\n\n    if (settings?.shop_logo && logoUrl !== settings.shop_logo) {\n      console.log('[logoService] Deleting old logo:', settings.shop_logo);\n      await deleteLogo(settings.shop_logo);\n    }\n\n    const settingsToUpsert: Record<string, string | null> = userId\n      ? {\n          user_id: userId,\n          shop_logo: logoUrl,\n        }\n      : {\n          id: FIXED_SETTINGS_ID,\n          shop_logo: logoUrl,\n        };\n\n    console.log('[logoService] Upserting settings:', settingsToUpsert);\n\n    const { data, error: upsertError } = await supabase\n      .from('app_settings')\n      .upsert(settingsToUpsert as any, {\n        onConflict: onConflictColumn,\n        ignoreDuplicates: false,\n      })\n      .select();\n\n    if (upsertError) {\n      console.error('[logoService] Upsert error:', upsertError);\n      console.error('[logoService] Error details:', JSON.stringify(upsertError, null, 2));\n      return false;\n    }\n\n    console.log('[logoService] Settings upserted successfully:', data);\n    return true;\n  } catch (error) {\n    console.error('[logoService] Error updating shop logo:', error);\n    if (error instanceof Error) {\n      console.error('[logoService] Error message:', error.message);\n    }\n    return false;\n  }\n}`
  );

  out = out.replace(
    /export async function updateShopSettings\(settings: \{[\s\S]*?\n\}/,
    `export async function updateShopSettings(settings: {\n  shop_name?: string;\n  shop_phone?: string;\n  shop_address?: string;\n}): Promise<boolean> {\n  try {\n    console.log('[logoService] updateShopSettings called with:', settings);\n\n    const userId = await getCurrentUserId();\n    const onConflictColumn = userId ? 'user_id' : 'id';\n\n    const settingsToUpsert: Record<string, string> = userId\n      ? {\n          user_id: userId,\n          ...settings,\n        }\n      : {\n          id: FIXED_SETTINGS_ID,\n          ...settings,\n        };\n\n    const { data, error: upsertError } = await supabase\n      .from('app_settings')\n      .upsert(settingsToUpsert as any, {\n        onConflict: onConflictColumn,\n        ignoreDuplicates: false,\n      })\n      .select();\n\n    if (upsertError) {\n      console.error('[logoService] Upsert error:', upsertError);\n      throw upsertError;\n    }\n\n    console.log('[logoService] Settings upserted successfully:', data);\n    return true;\n  } catch (error) {\n    console.error('[logoService] Error updating shop settings:', error);\n    return false;\n  }\n}`
  );

  return out;
});

replaceInFile('utils/logoHelper.ts', (source) => {
  return source.replace(
    'async function getAppReceiptLogoBase64(forceRefresh = false, userId?: string): Promise<string> {',
    'async function getAppReceiptLogoBase64(forceRefresh = false, userId?: string | null): Promise<string> {'
  );
});

const readme = `تم تطبيق hotfix لأخطاء TypeScript الأخيرة.\n\nالملفات المعدلة:\n- contexts/AuthContext.tsx\n- services/logoService.ts\n- utils/logoHelper.ts\n\nالخطوة التالية:\n1) npm run typecheck\n2) إذا نجح، أكمل الاختبار داخل التطبيق\n\nالنسخ الاحتياطية موجودة في:\n${backupDir}`;

fs.writeFileSync(path.join(root, 'ARTICODE_TYPECHECK_HOTFIX_README.txt'), readme, 'utf8');
console.log('Done successfully.');
console.log('Backup directory:', backupDir);
