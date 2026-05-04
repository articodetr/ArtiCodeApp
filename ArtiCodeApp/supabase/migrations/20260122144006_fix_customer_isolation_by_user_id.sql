/*
  # عزل العملاء حسب المستخدم
  
  ## المشكلة
  العملاء حالياً مشتركون بين جميع المستخدمين، ويمكن لأي مستخدم رؤية عملاء مستخدم آخر.
  
  ## الحل
  
  ### 1. إنشاء دالة للحصول على user_id من user_name
  - دالة helper تحصل على user_id من current_setting
  
  ### 2. تحديث سياسات RLS
  - حذف السياسة القديمة التي تسمح بالوصول الكامل
  - إضافة سياسات جديدة تفلتر حسب user_id
  
  ### 3. تحديث Views
  - إضافة user_id إلى جميع الـ Views المتعلقة بالعملاء
*/

-- 1. إنشاء دالة للحصول على user_id من المستخدم الحالي
CREATE OR REPLACE FUNCTION get_current_user_id()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_user_name text;
  v_user_id uuid;
BEGIN
  -- الحصول على user_name من السياق
  v_user_name := current_setting('app.current_user', true);
  
  -- إذا لم يكن هناك مستخدم في السياق، إرجاع null
  IF v_user_name IS NULL OR v_user_name = '' THEN
    RETURN NULL;
  END IF;
  
  -- البحث عن user_id في جدول app_security
  SELECT id INTO v_user_id
  FROM app_security
  WHERE user_name = v_user_name
  LIMIT 1;
  
  RETURN v_user_id;
END;
$$;

COMMENT ON FUNCTION get_current_user_id() IS 'الحصول على user_id للمستخدم الحالي من السياق';

-- منح الصلاحيات
GRANT EXECUTE ON FUNCTION get_current_user_id() TO anon, authenticated;

-- 2. حذف السياسة القديمة
DROP POLICY IF EXISTS "Allow all operations on customers" ON customers;

-- 3. إنشاء سياسات RLS جديدة للعملاء حسب user_id

-- سياسة القراءة: يمكن للمستخدم رؤية عملائه فقط أو العملاء المرتبطين به
CREATE POLICY "Users can view their own customers"
  ON customers FOR SELECT
  TO authenticated
  USING (
    user_id = get_current_user_id()
    OR linked_user_id = get_current_user_id()
    OR phone = 'PROFIT_LOSS_ACCOUNT'  -- حساب الأرباح والخسائر متاح للجميع
  );

-- سياسة للمستخدمين غير المسجلين (anon) - يمكنهم رؤية جميع العملاء
CREATE POLICY "Anonymous users can view all customers"
  ON customers FOR SELECT
  TO anon
  USING (true);

-- سياسة الإضافة: يمكن للمستخدم إضافة عملاء له
CREATE POLICY "Users can insert their own customers"
  ON customers FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = get_current_user_id()
    OR phone = 'PROFIT_LOSS_ACCOUNT'
  );

-- سياسة الإضافة للمستخدمين غير المسجلين
CREATE POLICY "Anonymous users can insert customers"
  ON customers FOR INSERT
  TO anon
  WITH CHECK (true);

-- سياسة التحديث: يمكن للمستخدم تحديث عملائه فقط
CREATE POLICY "Users can update their own customers"
  ON customers FOR UPDATE
  TO authenticated
  USING (
    user_id = get_current_user_id()
    OR phone = 'PROFIT_LOSS_ACCOUNT'
  )
  WITH CHECK (
    user_id = get_current_user_id()
    OR phone = 'PROFIT_LOSS_ACCOUNT'
  );

-- سياسة التحديث للمستخدمين غير المسجلين
CREATE POLICY "Anonymous users can update customers"
  ON customers FOR UPDATE
  TO anon
  USING (true)
  WITH CHECK (true);

-- سياسة الحذف: يمكن للمستخدم حذف عملائه فقط
CREATE POLICY "Users can delete their own customers"
  ON customers FOR DELETE
  TO authenticated
  USING (
    user_id = get_current_user_id()
    AND phone != 'PROFIT_LOSS_ACCOUNT'  -- لا يمكن حذف حساب الأرباح والخسائر
  );

-- سياسة الحذف للمستخدمين غير المسجلين
CREATE POLICY "Anonymous users can delete customers"
  ON customers FOR DELETE
  TO anon
  USING (phone != 'PROFIT_LOSS_ACCOUNT');

-- 4. تحديث View: customers_with_last_activity لإضافة user_id
DROP VIEW IF EXISTS customers_with_last_activity CASCADE;

CREATE OR REPLACE VIEW customers_with_last_activity AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.email,
  c.address,
  c.notes,
  c.created_at,
  c.account_number,
  c.is_profit_loss_account,
  c.user_id,  -- إضافة user_id
  c.linked_user_id,  -- إضافة linked_user_id
  MAX(am.created_at) as last_activity_date,
  COUNT(am.id) as movements_count
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
  AND am.is_commission_movement = false
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.notes, 
         c.created_at, c.account_number, c.is_profit_loss_account, c.user_id, c.linked_user_id
ORDER BY c.is_profit_loss_account DESC, last_activity_date DESC NULLS LAST;

-- منح الصلاحيات
GRANT SELECT ON customers_with_last_activity TO authenticated, anon;

COMMENT ON VIEW customers_with_last_activity IS 'عرض العملاء مع آخر نشاط - يتضمن user_id للفلترة';

-- 5. تحديث View: customer_balances_by_currency لإضافة user_id
DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

CREATE OR REPLACE VIEW customer_balances_by_currency AS
SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  c.user_id,  -- إضافة user_id
  c.linked_user_id,  -- إضافة linked_user_id
  am.currency,
  -- إجمالي المبالغ الواردة (incoming = له)
  COALESCE(SUM(CASE WHEN am.movement_type = 'incoming' THEN am.amount ELSE 0 END), 0) AS total_incoming,
  -- إجمالي المبالغ الصادرة (outgoing = عليه)
  COALESCE(SUM(CASE WHEN am.movement_type = 'outgoing' THEN am.amount ELSE 0 END), 0) AS total_outgoing,
  -- الرصيد النهائي: incoming موجب، outgoing سالب
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ),
    0
  ) AS balance
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
WHERE am.currency IS NOT NULL
GROUP BY c.id, c.name, c.user_id, c.linked_user_id, am.currency, c.is_profit_loss_account
HAVING COALESCE(
  SUM(
    CASE 
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ),
  0
) != 0 OR c.is_profit_loss_account = true;

-- منح الصلاحيات
GRANT SELECT ON customer_balances_by_currency TO authenticated, anon;

COMMENT ON VIEW customer_balances_by_currency IS 'أرصدة العملاء حسب العملة - يتضمن user_id للفلترة';

-- 6. إضافة تعليقات توضيحية
COMMENT ON POLICY "Users can view their own customers" ON customers IS 'يسمح للمستخدم برؤية عملائه فقط أو العملاء المرتبطين به';
COMMENT ON POLICY "Users can insert their own customers" ON customers IS 'يسمح للمستخدم بإضافة عملاء له';
COMMENT ON POLICY "Users can update their own customers" ON customers IS 'يسمح للمستخدم بتحديث عملائه فقط';
COMMENT ON POLICY "Users can delete their own customers" ON customers IS 'يسمح للمستخدم بحذف عملائه فقط';
