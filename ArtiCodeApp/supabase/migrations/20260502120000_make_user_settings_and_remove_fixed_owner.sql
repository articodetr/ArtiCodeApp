-- يحول منطق الإعدادات من سجل عام واحد إلى إعدادات مستقلة لكل مستخدم
-- ويزيل بقايا حماية الحساب الرئيسي الثابت (Ali/A)

begin;

-- 1) إزالة أي حماية قديمة لحساب رئيسي ثابت
DROP TRIGGER IF EXISTS prevent_ali_deletion_trigger ON app_security;
DROP FUNCTION IF EXISTS prevent_ali_deletion();
DROP TRIGGER IF EXISTS prevent_main_admin_deletion_trigger ON app_security;
DROP FUNCTION IF EXISTS prevent_main_admin_deletion();

-- 2) إضافة user_id إلى app_settings بحيث يكون لكل مستخدم إعداداته الخاصة
ALTER TABLE app_settings
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES app_security(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS app_settings_user_id_uidx
  ON app_settings(user_id)
  WHERE user_id IS NOT NULL;

-- 3) نسخ الإعدادات العامة الحالية إلى كل المستخدمين الموجودين
DO $$
DECLARE
  v_seed record;
BEGIN
  SELECT
    shop_name,
    shop_logo,
    shop_phone,
    shop_address,
    selected_receipt_logo,
    header_layout,
    header_primary_color,
    shop_name_en,
    shop_phone_en,
    shop_address_en
  INTO v_seed
  FROM app_settings
  LIMIT 1;

  INSERT INTO app_settings (
    id,
    user_id,
    shop_name,
    shop_logo,
    shop_phone,
    shop_address,
    selected_receipt_logo,
    header_layout,
    header_primary_color,
    shop_name_en,
    shop_phone_en,
    shop_address_en
  )
  SELECT
    gen_random_uuid(),
    u.id,
    COALESCE(v_seed.shop_name, 'ArtiCode'),
    v_seed.shop_logo,
    COALESCE(v_seed.shop_phone, ''),
    COALESCE(v_seed.shop_address, ''),
    v_seed.selected_receipt_logo,
    v_seed.header_layout,
    v_seed.header_primary_color,
    v_seed.shop_name_en,
    v_seed.shop_phone_en,
    v_seed.shop_address_en
  FROM app_security u
  WHERE NOT EXISTS (
    SELECT 1
    FROM app_settings s
    WHERE s.user_id = u.id
  );
END $$;

-- 4) دالة ترجع إعدادات المستخدم أو تنشئها إذا لم تكن موجودة
CREATE OR REPLACE FUNCTION get_or_create_user_settings(p_user_id uuid)
RETURNS app_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings app_settings;
BEGIN
  SELECT *
  INTO v_settings
  FROM app_settings
  WHERE user_id = p_user_id
  LIMIT 1;

  IF FOUND THEN
    RETURN v_settings;
  END IF;

  INSERT INTO app_settings (
    id,
    user_id,
    shop_name,
    shop_logo,
    shop_phone,
    shop_address,
    selected_receipt_logo
  )
  VALUES (
    gen_random_uuid(),
    p_user_id,
    'ArtiCode',
    NULL,
    '',
    '',
    NULL
  )
  RETURNING * INTO v_settings;

  RETURN v_settings;
END;
$$;

-- 5) تجهيز جدول الحركات حتى تكون منسوبة فعلياً لصاحب الحساب الحالي
ALTER TABLE movements
  ADD COLUMN IF NOT EXISTS created_by_user_id uuid REFERENCES app_security(id),
  ADD COLUMN IF NOT EXISTS source_user_id uuid REFERENCES app_security(id);

CREATE INDEX IF NOT EXISTS movements_created_by_user_id_idx
  ON movements(created_by_user_id);

CREATE INDEX IF NOT EXISTS movements_source_user_id_idx
  ON movements(source_user_id);

CREATE INDEX IF NOT EXISTS customers_user_id_idx
  ON customers(user_id);

-- 6) الحفاظ على التوافق مع النظام الحالي:
-- نترك سياسات app_settings مفتوحة مؤقتاً إذا كانت موجودة من النظام القديم
-- لأن التطبيق الحالي يعتمد على set_current_user وليس auth.users.
-- القراءة والتعديل ستصبح لكل مستخدم من خلال user_id في التطبيق نفسه.

commit;
