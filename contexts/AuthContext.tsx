import React, { createContext, useContext, useState, useEffect } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Crypto from 'expo-crypto';
import { supabase } from '@/lib/supabase';
import { AppSettings } from '@/types/database';

interface AuthContextType {
  isAuthenticated: boolean;
  isLoading: boolean;
  currentUser: { userName: string; role: string; userId: string; fullName: string; accountNumber: string } | null;
  login: (userName: string, pin: string) => Promise<{ success: boolean; error?: string }>;
  register: (fullName: string, userName: string, password: string) => Promise<{ success: boolean; accountNumber?: string; error?: string }>;
  logout: () => Promise<void>;
  checkUsernameAvailability: (userName: string) => Promise<boolean>;
  settings: AppSettings | null;
  refreshSettings: () => Promise<void>;
  updateSettings: (settings: Partial<AppSettings>) => Promise<boolean>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

const AUTH_KEY = '@money_transfer_auth';
const USER_KEY = '@money_transfer_current_user';

// Helper functions for password hashing using expo-crypto
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

async function verifyPassword(password: string, hashedPassword: string): Promise<boolean> {
  try {
    // Split stored hash into salt and hash
    const [salt, storedHash] = hashedPassword.split(':');

    if (!salt || !storedHash) {
      console.error('[verifyPassword] Invalid hash format');
      return false;
    }

    // Hash the provided password with the same salt
    const hash = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      password + salt
    );

    // Compare hashes
    return hash === storedHash;
  } catch (error) {
    console.error('[verifyPassword] Error:', error);
    return false;
  }
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [currentUser, setCurrentUser] = useState<{ userName: string; role: string; userId: string; fullName: string; accountNumber: string } | null>(null);

  const loadSettings = async () => {
    try {
      const FIXED_SETTINGS_ID = '00000000-0000-0000-0000-000000000000';
      const { data, error } = await supabase
        .from('app_settings')
        .select('*')
        .eq('id', FIXED_SETTINGS_ID)
        .maybeSingle();

      if (!error && data) {
        setSettings(data);
        return;
      }

      if (!error && !data) {
        // Create default settings if none exist
        const defaultSettings = {
          shop_name: 'ArtiCode',
          shop_phone: '',
          shop_address: '',
        };

        const { data: newSettings } = await supabase
          .from('app_settings')
          .insert(defaultSettings)
          .select()
          .single();

        if (newSettings) {
          setSettings(newSettings);
          return;
        }
      }

      // If we get here, set default settings
      setSettings({
        id: '',
        shop_name: 'ArtiCode',
        shop_phone: '',
        shop_address: '',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        selected_receipt_logo: null,
      } as any);
    } catch (error) {
      console.error('Error loading settings:', error);
      // Set default settings on error
      setSettings({
        id: '',
        shop_name: 'ArtiCode',
        shop_phone: '',
        shop_address: '',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        selected_receipt_logo: null,
      } as any);
    }
  };

  useEffect(() => {
    checkAuth();
    loadSettings();
  }, []);

  const checkAuth = async () => {
    try {
      const authValue = await AsyncStorage.getItem(AUTH_KEY);
      const userValue = await AsyncStorage.getItem(USER_KEY);

      if (authValue === 'true' && userValue) {
        const user = JSON.parse(userValue);
        setIsAuthenticated(true);
        setCurrentUser(user);

        // Set current_user in Supabase for RLS
        try {
          await supabase.rpc('set_current_user', { user_name: user.userName });
        } catch (error) {
          console.error('Error setting current user in Supabase:', error);
        }
      }
    } catch (error) {
      console.error('Error checking auth:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const login = async (userName: string, pin: string): Promise<{ success: boolean; error?: string }> => {
    try {
      if (!settings) {
        await loadSettings();
      }

      // Check if account is locked due to too many failed attempts
      const { data: isLocked } = await supabase.rpc('check_login_attempts', { p_user_name: userName });

      if (isLocked === true) {
        return { success: false, error: 'تم قفل حسابك مؤقتاً بعد 5 محاولات فاشلة. حاول بعد 15 دقيقة' };
      }

      const { data, error } = await supabase
        .from('app_security')
        .select('id, pin_hash, is_active, role, user_name, full_name, account_number')
        .eq('user_name', userName)
        .maybeSingle();

      if (error || !data) {
        // Record failed attempt
        await supabase.rpc('record_login_attempt', {
          p_user_name: userName,
          p_success: false,
        });
        return { success: false, error: 'اسم المستخدم أو كلمة المرور غير صحيحة' };
      }

      if (!data.is_active) {
        return { success: false, error: 'حسابك غير نشط. يرجى التواصل مع المدير' };
      }

      // Check password - support multiple hash formats for backward compatibility
      let isPasswordValid = false;

      // Check if hash contains ':' (new expo-crypto format: salt:hash)
      if (data.pin_hash.includes(':')) {
        // New expo-crypto format
        isPasswordValid = await verifyPassword(pin, data.pin_hash);
      } else {
        // Legacy SHA256 format (no salt)
        const hashHex = await Crypto.digestStringAsync(
          Crypto.CryptoDigestAlgorithm.SHA256,
          pin
        );
        isPasswordValid = data.pin_hash === hashHex;

        // If valid and using old hash, upgrade to new format
        if (isPasswordValid) {
          const newHash = await hashPassword(pin);
          await supabase
            .from('app_security')
            .update({ pin_hash: newHash })
            .eq('id', data.id);
        }
      }

      if (isPasswordValid) {
        // Record successful login
        await supabase.rpc('record_login_attempt', {
          p_user_name: userName,
          p_success: true,
        });

        // Update last login
        await supabase
          .from('app_security')
          .update({ last_login: new Date().toISOString() })
          .eq('id', data.id);

        // Set current_user in Supabase for RLS
        await supabase.rpc('set_current_user', { user_name: userName });

        const user = {
          userName: data.user_name,
          role: data.role,
          userId: data.id,
          fullName: data.full_name,
          accountNumber: data.account_number,
        };

        await AsyncStorage.setItem(AUTH_KEY, 'true');
        await AsyncStorage.setItem(USER_KEY, JSON.stringify(user));
        setCurrentUser(user);
        setIsAuthenticated(true);
        return { success: true };
      }

      // Record failed attempt
      await supabase.rpc('record_login_attempt', {
        p_user_name: userName,
        p_success: false,
      });

      return { success: false, error: 'اسم المستخدم أو كلمة المرور غير صحيحة' };
    } catch (error) {
      console.error('Error during login:', error);
      return { success: false, error: 'حدث خطأ أثناء تسجيل الدخول' };
    }
  };

  const logout = async () => {
    try {
      await AsyncStorage.removeItem(AUTH_KEY);
      await AsyncStorage.removeItem(USER_KEY);
      setIsAuthenticated(false);
      setCurrentUser(null);
    } catch (error) {
      console.error('Error during logout:', error);
    }
  };

  const refreshSettings = async () => {
    await loadSettings();
  };

  const register = async (fullName: string, userName: string, password: string): Promise<{ success: boolean; accountNumber?: string; error?: string }> => {
    try {
      console.log('[AuthContext] Starting registration:', { fullName, userName });

      // Validate inputs
      if (!fullName || fullName.trim().length < 2) {
        console.log('[AuthContext] Validation failed: fullName too short');
        return { success: false, error: 'الاسم الكامل يجب أن يكون حرفين على الأقل' };
      }

      if (!userName || userName.trim().length < 3) {
        console.log('[AuthContext] Validation failed: userName too short');
        return { success: false, error: 'اسم المستخدم يجب أن يكون 3 أحرف على الأقل' };
      }

      if (!password || password.length < 6) {
        console.log('[AuthContext] Validation failed: password too short');
        return { success: false, error: 'كلمة المرور يجب أن تكون 6 أحرف على الأقل' };
      }

      // Check for weak passwords
      const weakPasswords = [
        '123456', '123456789', 'password', 'admin', 'qwerty', '12345678',
        '111111', '123123', '1234567890', '1234567', 'abc123', '000000',
        '654321', '666666', '88888888', '999999', 'asdfghjkl', 'qwertyuiop'
      ];

      if (weakPasswords.includes(password.toLowerCase())) {
        console.log('[AuthContext] Validation failed: weak password');
        return { success: false, error: 'كلمة المرور ضعيفة جداً. اختر كلمة مرور أقوى' };
      }

      // Check if username already exists
      console.log('[AuthContext] Checking username availability...');
      const { data: existingUser, error: checkError } = await supabase
        .from('app_security')
        .select('user_name')
        .eq('user_name', userName.trim())
        .maybeSingle();

      if (checkError) {
        console.error('[AuthContext] Error checking username:', checkError);
        return { success: false, error: 'خطأ في التحقق من اسم المستخدم' };
      }

      if (existingUser) {
        console.log('[AuthContext] Username already exists');
        return { success: false, error: 'اسم المستخدم مستخدم بالفعل. اختر اسم آخر' };
      }

      // Hash password with expo-crypto
      console.log('[AuthContext] Hashing password...');
      let hashedPassword: string;
      try {
        hashedPassword = await hashPassword(password);
        console.log('[AuthContext] Password hashed successfully');
      } catch (hashError) {
        console.error('[AuthContext] Hashing failed:', hashError);
        return { success: false, error: 'فشل تشفير كلمة المرور' };
      }

      // Insert new user (account_number will be auto-generated by trigger)
      console.log('[AuthContext] Inserting new user into database...');
      const { data: newUser, error } = await supabase
        .from('app_security')
        .insert({
          user_name: userName.trim(),
          full_name: fullName.trim(),
          pin_hash: hashedPassword,
          role: 'user',
          is_active: true,
        })
        .select('account_number, user_name, full_name')
        .single();

      if (error) {
        console.error('[AuthContext] Insert error:', error);
        console.error('[AuthContext] Error code:', error.code);
        console.error('[AuthContext] Error message:', error.message);
        console.error('[AuthContext] Error details:', error.details);
        return { success: false, error: `خطأ في قاعدة البيانات: ${error.message}` };
      }

      if (!newUser) {
        console.error('[AuthContext] No user data returned');
        return { success: false, error: 'حدث خطأ أثناء إنشاء الحساب. حاول مرة أخرى' };
      }

      console.log('[AuthContext] User created successfully:', newUser);
      return {
        success: true,
        accountNumber: newUser.account_number,
      };
    } catch (error) {
      console.error('[AuthContext] Exception during registration:', error);
      if (error instanceof Error) {
        console.error('[AuthContext] Error message:', error.message);
        console.error('[AuthContext] Error stack:', error.stack);
        return { success: false, error: `خطأ: ${error.message}` };
      }
      return { success: false, error: 'حدث خطأ أثناء إنشاء الحساب' };
    }
  };

  const checkUsernameAvailability = async (userName: string): Promise<boolean> => {
    try {
      if (!userName || userName.trim().length < 3) {
        return false;
      }

      const { data } = await supabase
        .from('app_security')
        .select('user_name')
        .eq('user_name', userName.trim())
        .maybeSingle();

      // Return true if username is available (data is null)
      return data === null;
    } catch (error) {
      console.error('Error checking username:', error);
      return false;
    }
  };

  const updateSettings = async (newSettings: Partial<AppSettings>): Promise<boolean> => {
    try {
      console.log('[AuthContext] updateSettings called with:', JSON.stringify(newSettings, null, 2));

      if (newSettings.shop_logo !== undefined && currentUser?.role !== 'admin') {
        console.error('[AuthContext] Non-admin user attempted to update shop logo');
        return false;
      }

      const FIXED_ID = '00000000-0000-0000-0000-000000000000';

      const settingsToUpsert = {
        id: FIXED_ID,
        ...newSettings,
      };

      console.log('[AuthContext] Performing upsert with data:', JSON.stringify(settingsToUpsert, null, 2));

      const { data, error: upsertError } = await supabase
        .from('app_settings')
        .upsert(settingsToUpsert, {
          onConflict: 'id',
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

      await loadSettings();
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
  };

  return (
    <AuthContext.Provider
      value={{
        isAuthenticated,
        isLoading,
        currentUser,
        login,
        register,
        logout,
        checkUsernameAvailability,
        settings,
        refreshSettings,
        updateSettings,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    // Return default values during initialization
    return {
      isAuthenticated: false,
      isLoading: true,
      currentUser: null,
      login: async (_userName: string, _pin: string) => ({ success: false, error: 'Initializing...' }),
      register: async (_fullName: string, _userName: string, _password: string) => ({ success: false, error: 'Initializing...' }),
      logout: async () => {},
      checkUsernameAvailability: async (_userName: string) => false,
      settings: null,
      refreshSettings: async () => {},
      updateSettings: async () => false,
    };
  }
  return context;
}
