/*
  # إضافة نظام ربط المستخدمين بالعملاء

  ## التغييرات

  ### 1. تحديث جدول customers
  - إضافة `user_id` (uuid, NOT NULL): معرف المستخدم المالك للعميل
  - إضافة `linked_user_id` (uuid, NULL): معرف المستخدم المرتبط (إذا كان العميل مستخدم في النظام)
  - إضافة foreign key constraints لربط المستخدمين
  - إضافة indexes لتحسين الأداء

  ### 2. جدول user_customer_links
  - تتبع العلاقات بين المستخدمين والعملاء
  - تخزين تاريخ الربط وحالة العلاقة
  - منع تكرار نفس العلاقة

  ### 3. تحديث Row Level Security (RLS)
  - المستخدم يرى عملاءه فقط
  - المدير يرى جميع العملاء
  - المستخدمون المربوطون يمكنهم رؤية بيانات علاقاتهم
  - تطبيق سياسات مشابهة على account_movements

  ### 4. إنشاء views للعلاقات المتبادلة
  - عرض الأرصدة المتبادلة بين المستخدمين المرتبطين
  - عرض قائمة المستخدمين المرتبطين

  ### 5. ترحيل البيانات الحالية
  - ربط جميع العملاء الحاليين بحساب المدير (admin)
  - ضمان عدم تأثر البيانات الموجودة

  ## الأمان
  - RLS مفعّل على جميع الجداول الجديدة
  - حماية خاصة للعلاقات بين المستخدمين
  - المستخدمون لا يمكنهم رؤية بيانات بعضهم إلا من خلال العلاقات المصرح بها
*/

-- 1. إضافة حقول جديدة لجدول customers
DO $$
BEGIN
  -- إضافة user_id
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'customers' AND column_name = 'user_id'
  ) THEN
    ALTER TABLE customers ADD COLUMN user_id uuid;
  END IF;

  -- إضافة linked_user_id
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'customers' AND column_name = 'linked_user_id'
  ) THEN
    ALTER TABLE customers ADD COLUMN linked_user_id uuid;
  END IF;
END $$;

-- 2. إضافة foreign key constraints
DO $$
BEGIN
  -- Foreign key لـ user_id
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_customers_user_id'
  ) THEN
    ALTER TABLE customers
      ADD CONSTRAINT fk_customers_user_id
      FOREIGN KEY (user_id)
      REFERENCES app_security(id)
      ON DELETE CASCADE;
  END IF;

  -- Foreign key لـ linked_user_id
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_customers_linked_user_id'
  ) THEN
    ALTER TABLE customers
      ADD CONSTRAINT fk_customers_linked_user_id
      FOREIGN KEY (linked_user_id)
      REFERENCES app_security(id)
      ON DELETE SET NULL;
  END IF;
END $$;

-- 3. إضافة indexes لتحسين الأداء
CREATE INDEX IF NOT EXISTS idx_customers_user_id ON customers(user_id);
CREATE INDEX IF NOT EXISTS idx_customers_linked_user_id ON customers(linked_user_id);

-- 4. ترحيل البيانات الحالية - ربط جميع العملاء بحساب المدير
DO $$
DECLARE
  v_admin_id uuid;
BEGIN
  -- الحصول على معرف المدير (A)
  SELECT id INTO v_admin_id FROM app_security WHERE user_name = 'A' OR role = 'admin' LIMIT 1;

  IF v_admin_id IS NOT NULL THEN
    -- ربط جميع العملاء الحاليين بالمدير
    UPDATE customers
    SET user_id = v_admin_id
    WHERE user_id IS NULL;
  END IF;
END $$;

-- 5. جعل user_id NOT NULL بعد ترحيل البيانات
ALTER TABLE customers ALTER COLUMN user_id SET NOT NULL;

-- 6. إنشاء جدول user_customer_links لتتبع العلاقات
CREATE TABLE IF NOT EXISTS user_customer_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NOT NULL REFERENCES app_security(id) ON DELETE CASCADE,
  linked_user_id uuid NOT NULL REFERENCES app_security(id) ON DELETE CASCADE,
  customer_id uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  link_type text NOT NULL DEFAULT 'customer_link' CHECK (link_type IN ('customer_link')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'blocked')),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  notes text,

  -- منع ربط نفس المستخدم مرتين لنفس المالك
  CONSTRAINT unique_owner_linked_user UNIQUE (owner_user_id, linked_user_id)
);

-- إضافة indexes
CREATE INDEX IF NOT EXISTS idx_ucl_owner_user ON user_customer_links(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_ucl_linked_user ON user_customer_links(linked_user_id);
CREATE INDEX IF NOT EXISTS idx_ucl_customer ON user_customer_links(customer_id);
CREATE INDEX IF NOT EXISTS idx_ucl_status ON user_customer_links(status);

-- تفعيل RLS
ALTER TABLE user_customer_links ENABLE ROW LEVEL SECURITY;

-- 7. تحديث RLS policies لجدول customers
-- حذف السياسات القديمة
DROP POLICY IF EXISTS "Allow all operations on customers" ON customers;

-- سياسة القراءة: المستخدم يرى عملاءه + العملاء الذين هم مستخدمون مسجلون ربطوه
CREATE POLICY "Users can view own customers and linked accounts"
  ON customers FOR SELECT
  TO authenticated
  USING (
    -- المستخدم يرى عملاءه
    user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    -- المستخدم يرى نفسه كعميل عند المستخدمين الآخرين
    linked_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    -- المدير يرى الجميع
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

-- سياسة الإضافة: المستخدم يضيف عملاء لنفسه فقط
CREATE POLICY "Users can insert own customers"
  ON customers FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
  );

-- سياسة التعديل: المستخدم يعدل عملاءه فقط
CREATE POLICY "Users can update own customers"
  ON customers FOR UPDATE
  TO authenticated
  USING (
    user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  )
  WITH CHECK (
    user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

-- سياسة الحذف: المستخدم يحذف عملاءه فقط (مع حماية خاصة)
CREATE POLICY "Users can delete own customers"
  ON customers FOR DELETE
  TO authenticated
  USING (
    user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    AND phone != 'PROFIT_LOSS_ACCOUNT' -- حماية حساب الأرباح
    OR
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

-- 8. RLS policies لجدول user_customer_links
CREATE POLICY "Users can view own links"
  ON user_customer_links FOR SELECT
  TO authenticated
  USING (
    owner_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    linked_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

CREATE POLICY "Users can create own links"
  ON user_customer_links FOR INSERT
  TO authenticated
  WITH CHECK (
    owner_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
  );

CREATE POLICY "Users can update own links"
  ON user_customer_links FOR UPDATE
  TO authenticated
  USING (
    owner_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

CREATE POLICY "Users can delete own links"
  ON user_customer_links FOR DELETE
  TO authenticated
  USING (
    owner_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

-- 9. تحديث RLS policies لجدول account_movements
-- حذف السياسات القديمة
DROP POLICY IF EXISTS "Allow all operations on account_movements" ON account_movements;

-- سياسة القراءة
CREATE POLICY "Users can view own movements"
  ON account_movements FOR SELECT
  TO authenticated
  USING (
    -- الحركة تخص عميل من عملاء المستخدم
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    )
    OR
    -- الحركة تخص المستخدم نفسه كعميل مرتبط
    customer_id IN (
      SELECT id FROM customers
      WHERE linked_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    )
    OR
    -- المدير يرى الجميع
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

-- سياسة الإضافة
CREATE POLICY "Users can insert own movements"
  ON account_movements FOR INSERT
  TO authenticated
  WITH CHECK (
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    )
  );

-- سياسة التعديل
CREATE POLICY "Users can update own movements"
  ON account_movements FOR UPDATE
  TO authenticated
  USING (
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    )
    OR
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

-- سياسة الحذف
CREATE POLICY "Users can delete own movements"
  ON account_movements FOR DELETE
  TO authenticated
  USING (
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    )
    OR
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

-- 10. إنشاء view للأرصدة المتبادلة بين المستخدمين المرتبطين
CREATE OR REPLACE VIEW user_mutual_balances AS
SELECT
  c.user_id as owner_user_id,
  owner.user_name as owner_user_name,
  owner.full_name as owner_full_name,
  c.linked_user_id,
  linked.user_name as linked_user_name,
  linked.full_name as linked_full_name,
  c.id as customer_id,
  c.name as customer_name,
  am.currency,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN am.amount
        ELSE 0
      END
    ), 0
  ) as total_incoming,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN am.amount
        ELSE 0
      END
    ), 0
  ) as total_outgoing,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN am.amount
        WHEN am.movement_type = 'outgoing' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN -am.amount
        ELSE 0
      END
    ), 0
  ) as balance,
  MAX(am.created_at) as last_activity
FROM customers c
INNER JOIN app_security owner ON c.user_id = owner.id
LEFT JOIN app_security linked ON c.linked_user_id = linked.id
LEFT JOIN account_movements am ON c.id = am.customer_id
WHERE c.linked_user_id IS NOT NULL
GROUP BY c.user_id, owner.user_name, owner.full_name, c.linked_user_id,
         linked.user_name, linked.full_name, c.id, c.name, am.currency;

-- 11. إنشاء view لقائمة المستخدمين المرتبطين
CREATE OR REPLACE VIEW user_linked_accounts AS
SELECT
  c.user_id as owner_user_id,
  owner.user_name as owner_user_name,
  owner.full_name as owner_full_name,
  owner.account_number as owner_account_number,
  c.linked_user_id,
  linked.user_name as linked_user_name,
  linked.full_name as linked_full_name,
  linked.account_number as linked_account_number,
  c.id as customer_id,
  c.name as customer_name,
  c.phone as customer_phone,
  c.created_at as link_created_at,
  -- إجمالي الرصيد بجميع العملات
  (
    SELECT COALESCE(SUM(
      CASE
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ), 0)
    FROM account_movements am
    WHERE am.customer_id = c.id
      AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
  ) as total_balance
FROM customers c
INNER JOIN app_security owner ON c.user_id = owner.id
INNER JOIN app_security linked ON c.linked_user_id = linked.id
WHERE c.linked_user_id IS NOT NULL;

-- 12. تحديث view customer_balances لدعم المستخدمين المتعددين
DROP VIEW IF EXISTS customer_balances;
CREATE OR REPLACE VIEW customer_balances AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.user_id,
  c.linked_user_id,
  c.is_profit_loss_account,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN am.amount
        ELSE 0
      END
    ), 0
  ) as total_incoming,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'outgoing' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN am.amount
        ELSE 0
      END
    ), 0
  ) as total_outgoing,
  COALESCE(
    SUM(
      CASE
        WHEN am.movement_type = 'incoming' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN am.amount
        WHEN am.movement_type = 'outgoing' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN -am.amount
        ELSE 0
      END
    ), 0
  ) as balance,
  am.currency,
  MAX(am.created_at) as last_activity
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.user_id, c.linked_user_id, c.is_profit_loss_account, am.currency
HAVING c.is_profit_loss_account = true
  OR COALESCE(SUM(
    CASE
      WHEN am.movement_type = 'incoming' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
      THEN am.amount
      WHEN am.movement_type = 'outgoing' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
      THEN -am.amount
      ELSE 0
    END
  ), 0) != 0;

-- 13. دالة للبحث عن مستخدمين برقم الحساب
CREATE OR REPLACE FUNCTION search_users_by_account_number(
  p_account_number text,
  p_current_user_id uuid
)
RETURNS TABLE (
  id uuid,
  user_name text,
  full_name text,
  account_number text,
  is_already_linked boolean
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.id,
    s.user_name,
    s.full_name,
    s.account_number,
    EXISTS (
      SELECT 1 FROM customers
      WHERE user_id = p_current_user_id
      AND linked_user_id = s.id
    ) as is_already_linked
  FROM app_security s
  WHERE s.account_number ILIKE '%' || p_account_number || '%'
    AND s.id != p_current_user_id
    AND s.is_active = true
  ORDER BY s.account_number
  LIMIT 10;
END;
$$ LANGUAGE plpgsql;

-- 14. دالة لإنشاء عميل مرتبط بمستخدم
CREATE OR REPLACE FUNCTION create_linked_customer(
  p_owner_user_id uuid,
  p_linked_user_id uuid,
  p_customer_name text
)
RETURNS TABLE (
  success boolean,
  customer_id uuid,
  message text
) AS $$
DECLARE
  v_customer_id uuid;
  v_linked_user_name text;
  v_linked_account_number text;
  v_existing_link uuid;
BEGIN
  -- التحقق من عدم ربط نفس المستخدم
  IF p_owner_user_id = p_linked_user_id THEN
    RETURN QUERY SELECT false, NULL::uuid, 'لا يمكن ربط نفسك كعميل'::text;
    RETURN;
  END IF;

  -- التحقق من وجود ربط سابق
  SELECT id INTO v_existing_link
  FROM customers
  WHERE user_id = p_owner_user_id
    AND linked_user_id = p_linked_user_id;

  IF v_existing_link IS NOT NULL THEN
    RETURN QUERY SELECT false, v_existing_link, 'هذا المستخدم مربوط بالفعل'::text;
    RETURN;
  END IF;

  -- الحصول على معلومات المستخدم المرتبط
  SELECT full_name, account_number INTO v_linked_user_name, v_linked_account_number
  FROM app_security
  WHERE id = p_linked_user_id;

  IF v_linked_user_name IS NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, 'المستخدم المحدد غير موجود'::text;
    RETURN;
  END IF;

  -- إنشاء سجل العميل المرتبط
  INSERT INTO customers (
    user_id,
    linked_user_id,
    name,
    phone,
    account_number,
    notes
  ) VALUES (
    p_owner_user_id,
    p_linked_user_id,
    COALESCE(p_customer_name, v_linked_user_name),
    'LINKED_USER_' || v_linked_account_number,
    v_linked_account_number,
    'عميل مرتبط بمستخدم مسجل في النظام'
  ) RETURNING id INTO v_customer_id;

  -- إنشاء سجل في user_customer_links
  INSERT INTO user_customer_links (
    owner_user_id,
    linked_user_id,
    customer_id,
    status,
    notes
  ) VALUES (
    p_owner_user_id,
    p_linked_user_id,
    v_customer_id,
    'active',
    'ربط تلقائي عند إضافة العميل'
  );

  RETURN QUERY SELECT true, v_customer_id, 'تم ربط المستخدم كعميل بنجاح'::text;
END;
$$ LANGUAGE plpgsql;

-- 15. تفعيل Realtime للجداول الجديدة
ALTER PUBLICATION supabase_realtime ADD TABLE user_customer_links;

-- 16. Grant permissions على الـ views الجديدة
GRANT SELECT ON user_mutual_balances TO authenticated;
GRANT SELECT ON user_linked_accounts TO authenticated;
