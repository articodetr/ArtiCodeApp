/*
  # إضافة نظام حساب الأرباح والخسائر

  ## التغييرات الجديدة
  
  ### 1. تعديل جدول العملاء
    - إضافة حقل `is_profit_loss_account` (boolean) لتمييز حساب الأرباح والخسائر
    - حساب واحد فقط يمكن أن يكون حساب أرباح وخسائر
  
  ### 2. إنشاء حساب الأرباح والخسائر
    - يتم إنشاء حساب خاص اسمه "الأرباح والخسائر"
    - هذا الحساب لا يمكن حذفه
    - يستخدم لتجميع كل العمولات تلقائياً
  
  ### 3. الأمان والقيود
    - تعديل دالة `delete_customer` لمنع حذف حساب الأرباح والخسائر
    - constraint لضمان وجود حساب واحد فقط للأرباح والخسائر
    - يمكن تعديل اسم الحساب فقط (لا يمكن حذفه)
  
  ### 4. ملاحظات مهمة
    - جميع العمولات تُسجل تلقائياً في هذا الحساب
    - العمولة تُخصم من المستفيد وتُضاف للأرباح والخسائر
    - العمولة بنفس عملة الحركة الأساسية
*/

-- إضافة حقل is_profit_loss_account إلى جدول customers
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'customers' AND column_name = 'is_profit_loss_account'
  ) THEN
    ALTER TABLE customers ADD COLUMN is_profit_loss_account boolean DEFAULT false;
  END IF;
END $$;

-- إنشاء constraint لضمان وجود حساب واحد فقط للأرباح والخسائر
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'only_one_profit_loss_account'
  ) THEN
    ALTER TABLE customers
    ADD CONSTRAINT only_one_profit_loss_account
    EXCLUDE USING btree (is_profit_loss_account WITH =)
    WHERE (is_profit_loss_account = true);
  END IF;
END $$;

-- إنشاء حساب "الأرباح والخسائر" إذا لم يكن موجوداً
DO $$
DECLARE
  profit_loss_exists boolean;
BEGIN
  -- التحقق من وجود الحساب
  SELECT EXISTS (
    SELECT 1 FROM customers WHERE is_profit_loss_account = true
  ) INTO profit_loss_exists;

  -- إنشاء الحساب إذا لم يكن موجوداً
  IF NOT profit_loss_exists THEN
    INSERT INTO customers (
      name,
      phone,
      is_profit_loss_account,
      created_at
    ) VALUES (
      'الأرباح والخسائر',
      'SYSTEM_ACCOUNT',
      true,
      now()
    );
  END IF;
END $$;

-- تعديل دالة delete_customer لمنع حذف حساب الأرباح والخسائر
CREATE OR REPLACE FUNCTION delete_customer(customer_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  movement_count integer;
  is_profit_loss boolean;
  result json;
BEGIN
  -- التحقق من أن الحساب ليس حساب الأرباح والخسائر
  SELECT is_profit_loss_account INTO is_profit_loss
  FROM customers
  WHERE id = customer_id;

  IF is_profit_loss THEN
    RETURN json_build_object(
      'success', false,
      'error', 'لا يمكن حذف حساب الأرباح والخسائر'
    );
  END IF;

  -- التحقق من عدد الحركات المرتبطة بالعميل
  SELECT COUNT(*) INTO movement_count
  FROM account_movements
  WHERE party_id = customer_id;

  IF movement_count > 0 THEN
    RETURN json_build_object(
      'success', false,
      'error', 'لا يمكن حذف عميل لديه حركات مسجلة'
    );
  END IF;

  -- حذف العميل
  DELETE FROM customers WHERE id = customer_id;

  RETURN json_build_object(
    'success', true,
    'message', 'تم حذف العميل بنجاح'
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN json_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

-- تحديث RLS policy للحماية من حذف حساب الأرباح والخسائر
DROP POLICY IF EXISTS "Users can delete own customers" ON customers;

CREATE POLICY "Users can delete own customers"
  ON customers FOR DELETE
  TO authenticated
  USING (is_profit_loss_account IS NOT true);

-- إضافة index لتحسين الأداء
CREATE INDEX IF NOT EXISTS idx_customers_profit_loss 
ON customers(is_profit_loss_account) 
WHERE is_profit_loss_account = true;

-- إضافة دالة مساعدة للحصول على ID حساب الأرباح والخسائر
CREATE OR REPLACE FUNCTION get_profit_loss_account_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT id FROM customers WHERE is_profit_loss_account = true LIMIT 1;
$$;

COMMENT ON FUNCTION get_profit_loss_account_id() IS 'دالة للحصول على معرف حساب الأرباح والخسائر';

COMMENT ON COLUMN customers.is_profit_loss_account IS 'يحدد إذا كان هذا الحساب هو حساب الأرباح والخسائر. يجب أن يكون حساب واحد فقط في النظام.';
