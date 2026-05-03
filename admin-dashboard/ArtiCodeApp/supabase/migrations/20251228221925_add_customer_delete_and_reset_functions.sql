/*
  # إضافة دوال حذف وتصفير حسابات العملاء

  ## 1. الدوال الجديدة
    - `reset_customer_account()` - دالة لتصفير حساب عميل (حذف جميع حركاته مع الاحتفاظ ببياناته)
    - `delete_customer_completely()` - دالة لحذف عميل بالكامل مع جميع حركاته
    - `get_customer_movements_count()` - دالة للحصول على عدد الحركات لعميل
    - `get_customers_without_movements()` - دالة للحصول على العملاء بدون حركات

  ## 2. جدول سجل الحذف
    - `deletion_logs` - جدول لتسجيل عمليات الحذف للرجوع إليها

  ## 3. الأمان
    - تفعيل RLS على جدول سجل الحذف
    - جميع الدوال تتحقق من وجود العميل قبل تنفيذ العمليات
    
  ## 4. ملاحظات هامة
    - تصفير الحساب يحذف الحركات فقط ويبقي بيانات العميل
    - الحذف الكامل يحذف العميل وجميع بياناته
    - جميع عمليات الحذف يتم تسجيلها في جدول deletion_logs
*/

-- 1. إنشاء جدول سجل الحذف
CREATE TABLE IF NOT EXISTS deletion_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_type text NOT NULL CHECK (operation_type IN ('reset_account', 'delete_customer', 'delete_movement')),
  customer_id uuid,
  customer_name text,
  customer_account_number text,
  movements_count int DEFAULT 0,
  deleted_at timestamptz DEFAULT now(),
  notes text
);

-- إنشاء فهرس للأداء
CREATE INDEX IF NOT EXISTS deletion_logs_customer_id_idx ON deletion_logs(customer_id);
CREATE INDEX IF NOT EXISTS deletion_logs_deleted_at_idx ON deletion_logs(deleted_at DESC);
CREATE INDEX IF NOT EXISTS deletion_logs_operation_type_idx ON deletion_logs(operation_type);

-- 2. دالة للحصول على عدد الحركات لعميل
CREATE OR REPLACE FUNCTION get_customer_movements_count(p_customer_id uuid)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  movements_count int;
BEGIN
  SELECT COUNT(*) INTO movements_count
  FROM account_movements
  WHERE customer_id = p_customer_id;
  
  RETURN movements_count;
END;
$$;

-- 3. دالة لتصفير حساب عميل (حذف الحركات فقط)
CREATE OR REPLACE FUNCTION reset_customer_account(p_customer_id uuid)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_customer_name text;
  v_account_number text;
  v_movements_count int;
  v_result json;
BEGIN
  -- التحقق من وجود العميل
  SELECT name, account_number INTO v_customer_name, v_account_number
  FROM customers
  WHERE id = p_customer_id;
  
  IF v_customer_name IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'message', 'العميل غير موجود'
    );
  END IF;
  
  -- الحصول على عدد الحركات قبل الحذف
  v_movements_count := get_customer_movements_count(p_customer_id);
  
  -- حذف جميع الحركات
  DELETE FROM account_movements WHERE customer_id = p_customer_id;
  
  -- تحديث رصيد العميل إلى صفر
  UPDATE customers SET balance = 0 WHERE id = p_customer_id;
  
  -- تسجيل العملية في سجل الحذف
  INSERT INTO deletion_logs (
    operation_type, 
    customer_id, 
    customer_name, 
    customer_account_number,
    movements_count,
    notes
  ) VALUES (
    'reset_account',
    p_customer_id,
    v_customer_name,
    v_account_number,
    v_movements_count,
    'تم تصفير حساب العميل وحذف جميع حركاته'
  );
  
  v_result := json_build_object(
    'success', true,
    'message', 'تم تصفير الحساب بنجاح',
    'movements_deleted', v_movements_count,
    'customer_name', v_customer_name
  );
  
  RETURN v_result;
END;
$$;

-- 4. دالة لحذف عميل بالكامل
CREATE OR REPLACE FUNCTION delete_customer_completely(p_customer_id uuid)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_customer_name text;
  v_account_number text;
  v_movements_count int;
  v_result json;
BEGIN
  -- التحقق من وجود العميل
  SELECT name, account_number INTO v_customer_name, v_account_number
  FROM customers
  WHERE id = p_customer_id;
  
  IF v_customer_name IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'message', 'العميل غير موجود'
    );
  END IF;
  
  -- الحصول على عدد الحركات قبل الحذف
  v_movements_count := get_customer_movements_count(p_customer_id);
  
  -- تسجيل العملية في سجل الحذف قبل حذف العميل
  INSERT INTO deletion_logs (
    operation_type, 
    customer_id, 
    customer_name, 
    customer_account_number,
    movements_count,
    notes
  ) VALUES (
    'delete_customer',
    p_customer_id,
    v_customer_name,
    v_account_number,
    v_movements_count,
    'تم حذف العميل بالكامل مع جميع حركاته'
  );
  
  -- حذف العميل (سيتم حذف الحركات تلقائياً بسبب ON DELETE CASCADE)
  DELETE FROM customers WHERE id = p_customer_id;
  
  v_result := json_build_object(
    'success', true,
    'message', 'تم حذف العميل بنجاح',
    'movements_deleted', v_movements_count,
    'customer_name', v_customer_name
  );
  
  RETURN v_result;
END;
$$;

-- 5. دالة للحصول على العملاء بدون حركات
CREATE OR REPLACE FUNCTION get_customers_without_movements()
RETURNS TABLE (
  id uuid,
  name text,
  phone text,
  account_number text,
  created_at timestamptz
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    c.name,
    c.phone,
    c.account_number,
    c.created_at
  FROM customers c
  LEFT JOIN account_movements am ON c.id = am.customer_id
  WHERE am.id IS NULL
  ORDER BY c.created_at DESC;
END;
$$;

-- 6. دالة لحذف جميع العملاء بدون حركات
CREATE OR REPLACE FUNCTION delete_customers_without_movements()
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_deleted_count int;
  v_customer_record RECORD;
BEGIN
  v_deleted_count := 0;
  
  -- المرور على جميع العملاء بدون حركات
  FOR v_customer_record IN 
    SELECT * FROM get_customers_without_movements()
  LOOP
    -- تسجيل العملية
    INSERT INTO deletion_logs (
      operation_type,
      customer_id,
      customer_name,
      customer_account_number,
      movements_count,
      notes
    ) VALUES (
      'delete_customer',
      v_customer_record.id,
      v_customer_record.name,
      v_customer_record.account_number,
      0,
      'حذف تلقائي - عميل بدون حركات'
    );
    
    -- حذف العميل
    DELETE FROM customers WHERE id = v_customer_record.id;
    v_deleted_count := v_deleted_count + 1;
  END LOOP;
  
  RETURN json_build_object(
    'success', true,
    'message', 'تم حذف العملاء بنجاح',
    'deleted_count', v_deleted_count
  );
END;
$$;

-- تفعيل RLS على جدول سجل الحذف
ALTER TABLE deletion_logs ENABLE ROW LEVEL SECURITY;

-- سياسة RLS (السماح بجميع العمليات)
CREATE POLICY "Allow all operations on deletion_logs"
  ON deletion_logs FOR ALL
  USING (true)
  WITH CHECK (true);