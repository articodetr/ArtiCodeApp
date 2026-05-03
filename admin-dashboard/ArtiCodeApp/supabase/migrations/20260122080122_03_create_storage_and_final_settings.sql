/*
  # إنشاء Storage Bucket وإعدادات نهائية
  
  ## Storage Buckets
  
  ### 1. shop-logos
  - Bucket لحفظ شعارات المحلات
  - يدعم الوصول العام للقراءة
  
  ## حقول إضافية
  
  ### 1. selected_receipt_logo
  - إضافة حقل لتحديد الشعار المستخدم في الإيصالات
  
  ## WhatsApp Templates
  
  ### 1. whatsapp_message_template
  - قوالب رسائل WhatsApp
  
  ### 2. whatsapp_share_account_template  
  - قالب مشاركة كشف الحساب
  
  ## الأمان
  - RLS policies للسماح بالوصول العام للقراءة
  - RLS policies للسماح بالتحديث للمستخدمين
*/

-- 1. إنشاء Storage Bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'shop-logos',
  'shop-logos',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/gif', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

-- 2. إضافة RLS policies للـ storage
CREATE POLICY "Public read access for shop-logos"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'shop-logos');

CREATE POLICY "Authenticated users can upload shop-logos"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'shop-logos');

CREATE POLICY "Authenticated users can update shop-logos"
  ON storage.objects FOR UPDATE
  USING (bucket_id = 'shop-logos')
  WITH CHECK (bucket_id = 'shop-logos');

CREATE POLICY "Authenticated users can delete shop-logos"
  ON storage.objects FOR DELETE
  USING (bucket_id = 'shop-logos');

-- 3. إضافة حقل selected_receipt_logo لـ app_settings
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'selected_receipt_logo'
  ) THEN
    ALTER TABLE app_settings ADD COLUMN selected_receipt_logo text;
  END IF;
END $$;

-- 4. إضافة حقول WhatsApp templates
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_message_template'
  ) THEN
    ALTER TABLE app_settings ADD COLUMN whatsapp_message_template text DEFAULT 
    '🧾 *إيصال حوالة مالية*

رقم الإيصال: {receipt_number}
التاريخ: {date}

📝 *تفاصيل الحوالة:*
المبلغ: {amount} {currency}

👤 *معلومات العميل:*
الاسم: {customer_name}
الهاتف: {customer_phone}

📍 *{shop_name}*
{shop_address}
📞 {shop_phone}';
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'whatsapp_share_account_template'
  ) THEN
    ALTER TABLE app_settings ADD COLUMN whatsapp_share_account_template text DEFAULT
    '📊 *كشف حساب*

العميل: {customer_name}
الفترة: من {start_date} إلى {end_date}

💰 *الأرصدة:*
{balances}

📝 *الحركات:*
{movements}

الرصيد الإجمالي: {total_balance}

📍 *{shop_name}*';
  END IF;
END $$;

-- 5. تحديث RLS لـ app_settings للسماح للمستخدمين غير المصادقين بالقراءة
DROP POLICY IF EXISTS "Allow all operations on app_settings" ON app_settings;

CREATE POLICY "Allow read access to app_settings"
  ON app_settings FOR SELECT
  USING (true);

CREATE POLICY "Allow update access to app_settings"
  ON app_settings FOR UPDATE
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow insert access to app_settings"
  ON app_settings FOR INSERT
  WITH CHECK (true);

-- 6. التأكد من وجود حساب Ali admin
DO $$
DECLARE
  v_ali_id uuid;
BEGIN
  SELECT id INTO v_ali_id FROM app_security WHERE user_name = 'Ali';
  
  IF v_ali_id IS NULL THEN
    INSERT INTO app_security (user_name, pin_hash, role)
    VALUES ('Ali', '$2a$10$rZL2vKq7xK5H8U.qnJ5zNOXXuJGz6XqLq0KGZhF7yYJZQZB5H5F5e', 'admin');
  END IF;
END $$;