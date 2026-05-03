/*
  # نظام أرقام السندات المشتركة للحسابات المرتبطة

  ## الوصف
  بدلاً من أن يكون لكل customer أرقام سندات منفصلة:
  - الحسابات المرتبطة (مثل Taha و Salem) يشتركون في نفس sequence
  - Taha يضيف حركة → receipt_number = "000001"
  - Salem يضيف حركة → receipt_number = "000002"
  - Taha يضيف حركة أخرى → receipt_number = "000003"
  
  ## التغييرات
  1. إنشاء جدول `linked_account_pairs` لتتبع أزواج الحسابات المرتبطة
  2. إنشاء sequence لكل زوج من الحسابات
  3. تحديث function توليد receipt_number لاستخدام الـ pair sequence
*/

-- إنشاء جدول لتتبع أزواج الحسابات المرتبطة
CREATE TABLE IF NOT EXISTS linked_account_pairs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id_1 uuid NOT NULL REFERENCES app_security(id) ON DELETE CASCADE,
  user_id_2 uuid NOT NULL REFERENCES app_security(id) ON DELETE CASCADE,
  customer_id_1 uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  customer_id_2 uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  last_receipt_number integer NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT unique_pair UNIQUE (user_id_1, user_id_2),
  CONSTRAINT valid_pair CHECK (user_id_1 < user_id_2)
);

-- فهرس لتسريع البحث
CREATE INDEX IF NOT EXISTS idx_linked_pairs_users ON linked_account_pairs(user_id_1, user_id_2);
CREATE INDEX IF NOT EXISTS idx_linked_pairs_customers ON linked_account_pairs(customer_id_1, customer_id_2);

-- RLS policies
ALTER TABLE linked_account_pairs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own pairs"
  ON linked_account_pairs FOR SELECT
  TO authenticated
  USING (
    user_id_1 = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR user_id_2 = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
  );

CREATE POLICY "Users can insert own pairs"
  ON linked_account_pairs FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id_1 = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR user_id_2 = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
  );

-- Function للحصول على أو إنشاء pair
CREATE OR REPLACE FUNCTION get_or_create_linked_pair(
  p_user_id_a uuid,
  p_user_id_b uuid,
  p_customer_id_a uuid,
  p_customer_id_b uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_pair_id uuid;
  v_user_id_1 uuid;
  v_user_id_2 uuid;
  v_customer_id_1 uuid;
  v_customer_id_2 uuid;
BEGIN
  -- ترتيب المستخدمين لضمان الاتساق
  IF p_user_id_a < p_user_id_b THEN
    v_user_id_1 := p_user_id_a;
    v_user_id_2 := p_user_id_b;
    v_customer_id_1 := p_customer_id_a;
    v_customer_id_2 := p_customer_id_b;
  ELSE
    v_user_id_1 := p_user_id_b;
    v_user_id_2 := p_user_id_a;
    v_customer_id_1 := p_customer_id_b;
    v_customer_id_2 := p_customer_id_a;
  END IF;

  -- البحث عن pair موجود
  SELECT id INTO v_pair_id
  FROM linked_account_pairs
  WHERE user_id_1 = v_user_id_1 AND user_id_2 = v_user_id_2;

  -- إذا لم يوجد، إنشاء واحد جديد
  IF v_pair_id IS NULL THEN
    INSERT INTO linked_account_pairs (
      user_id_1,
      user_id_2,
      customer_id_1,
      customer_id_2,
      last_receipt_number
    ) VALUES (
      v_user_id_1,
      v_user_id_2,
      v_customer_id_1,
      v_customer_id_2,
      0
    )
    RETURNING id INTO v_pair_id;
  END IF;

  RETURN v_pair_id;
END;
$$;

-- Function جديدة لتوليد receipt_number مشترك
CREATE OR REPLACE FUNCTION generate_shared_receipt_number(p_customer_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_customer record;
  v_linked_customer_id uuid;
  v_pair_id uuid;
  v_next_number integer;
  v_receipt_number text;
BEGIN
  -- الحصول على معلومات العميل
  SELECT * INTO v_customer
  FROM customers
  WHERE id = p_customer_id;

  IF v_customer IS NULL THEN
    RAISE EXCEPTION 'Customer not found: %', p_customer_id;
  END IF;

  -- التحقق إذا كان العميل مرتبط
  IF v_customer.linked_user_id IS NULL THEN
    -- عميل عادي (غير مرتبط) - استخدم sequence خاص به
    SELECT COALESCE(MAX(CAST(receipt_number AS integer)), 0) + 1
    INTO v_next_number
    FROM account_movements
    WHERE customer_id = p_customer_id
      AND receipt_number IS NOT NULL
      AND receipt_number ~ '^\d+$';
    
    RETURN lpad(v_next_number::text, 5, '0');
  END IF;

  -- البحث عن العميل المقابل المرتبط
  SELECT id INTO v_linked_customer_id
  FROM customers
  WHERE user_id = v_customer.linked_user_id
    AND linked_user_id = v_customer.user_id
  LIMIT 1;

  IF v_linked_customer_id IS NULL THEN
    -- لم يتم العثور على العميل المرتبط بعد - استخدم sequence خاص
    SELECT COALESCE(MAX(CAST(receipt_number AS integer)), 0) + 1
    INTO v_next_number
    FROM account_movements
    WHERE customer_id = p_customer_id
      AND receipt_number IS NOT NULL
      AND receipt_number ~ '^\d+$';
    
    RETURN lpad(v_next_number::text, 5, '0');
  END IF;

  -- الحصول على أو إنشاء pair
  v_pair_id := get_or_create_linked_pair(
    v_customer.user_id,
    v_customer.linked_user_id,
    p_customer_id,
    v_linked_customer_id
  );

  -- تحديث وقفل الـ pair للحصول على الرقم التالي
  UPDATE linked_account_pairs
  SET 
    last_receipt_number = last_receipt_number + 1,
    updated_at = now()
  WHERE id = v_pair_id
  RETURNING last_receipt_number INTO v_next_number;

  -- تنسيق الرقم بـ 6 خانات
  v_receipt_number := lpad(v_next_number::text, 6, '0');

  RETURN v_receipt_number;
END;
$$;

-- تحديث function auto_generate_receipt_number لاستخدام النظام الجديد
CREATE OR REPLACE FUNCTION auto_generate_receipt_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- توليد رقم السند فقط إذا لم يكن موجوداً
  IF NEW.receipt_number IS NULL THEN
    -- التحقق من وجود customer_id
    IF NEW.customer_id IS NULL THEN
      RAISE EXCEPTION 'Cannot generate receipt number without customer_id';
    END IF;

    -- توليد رقم السند المشترك أو الخاص
    NEW.receipt_number := generate_shared_receipt_number(NEW.customer_id);
    NEW.receipt_generated_at := now();
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON TABLE linked_account_pairs IS 
  'أزواج الحسابات المرتبطة التي تشترك في تسلسل أرقام السندات';

COMMENT ON FUNCTION generate_shared_receipt_number IS 
  'توليد رقم سند مشترك للحسابات المرتبطة - الأرقام مترابطة بين الطرفين';
