/*
  # إصلاح تعارض أرقام حسابات العملاء المتبادلين
  
  ## المشكلة
  دالة `get_or_create_reciprocal_customer` كانت تحاول استخدام نفس رقم حساب المستخدم
  من `app_security` لإنشاء سجل العميل المتبادل في `customers`، مما يسبب تعارض مع
  القيد الفريد على `account_number` في جدول customers.
  
  ## الحل
  
  ### 1. إنشاء Sequence جديد للعملاء المتبادلين
  - يبدأ من 30000 لتجنب التعارض مع أرقام المستخدمين (26000)
  - يولد أرقام حسابات فريدة للعملاء المتبادلين
  
  ### 2. إنشاء دالة لتوليد رقم حساب للعملاء
  - `generate_customer_account_number()`: تولد رقم حساب فريد للعملاء
  - تدعم نوعين: عميل عادي أو عميل متبادل (linked)
  
  ### 3. تحديث دالة get_or_create_reciprocal_customer
  - استخدام `generate_customer_account_number()` بدلاً من `v_source_account_number`
  - ضمان عدم حدوث تعارض في أرقام الحسابات
  
  ### 4. تحديث العملاء المتبادلين الحاليين
  - إعطاء أرقام حسابات جديدة للعملاء المتبادلين الموجودين
  
  ## الأمان
  - تفعيل SECURITY DEFINER للدالة لتجاوز RLS
  - الحفاظ على جميع القيود والفهارس الموجودة
*/

-- 1. إنشاء Sequence لأرقام حسابات العملاء المتبادلين
CREATE SEQUENCE IF NOT EXISTS reciprocal_customer_account_number_seq
  START WITH 30000
  INCREMENT BY 1
  NO MAXVALUE
  CACHE 1;

-- 2. دالة لتوليد رقم حساب فريد للعملاء المتبادلين
CREATE OR REPLACE FUNCTION generate_customer_account_number()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  new_account_number text;
  account_exists boolean;
  max_attempts int := 100;
  attempt_count int := 0;
BEGIN
  LOOP
    -- الحصول على الرقم التالي من sequence
    new_account_number := LPAD(nextval('reciprocal_customer_account_number_seq')::text, 5, '0');
    
    -- التحقق من عدم وجود رقم الحساب في customers أو app_security
    SELECT EXISTS(
      SELECT 1 FROM customers WHERE account_number = new_account_number
      UNION
      SELECT 1 FROM app_security WHERE account_number = new_account_number
    ) INTO account_exists;
    
    -- إذا لم يوجد، نرجع الرقم
    EXIT WHEN NOT account_exists;
    
    -- حماية من اللوب اللانهائي
    attempt_count := attempt_count + 1;
    IF attempt_count >= max_attempts THEN
      RAISE EXCEPTION 'فشل في توليد رقم حساب فريد بعد % محاولة', max_attempts;
    END IF;
  END LOOP;
  
  RETURN new_account_number;
END;
$$;

-- 3. تحديث دالة get_or_create_reciprocal_customer لاستخدام الدالة الجديدة
CREATE OR REPLACE FUNCTION get_or_create_reciprocal_customer(
  p_target_user_id uuid,
  p_source_user_id uuid
) RETURNS uuid 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_customer_id uuid;
  v_source_user_name text;
  v_source_account_number text;
  v_new_customer_account_number text;
BEGIN
  -- البحث عن سجل عميل موجود للمستخدم الأصلي في حساب المستخدم المستهدف
  SELECT id INTO v_customer_id
  FROM customers
  WHERE user_id = p_target_user_id
    AND linked_user_id = p_source_user_id;
  
  -- إذا وُجد، إرجاع المعرف
  IF v_customer_id IS NOT NULL THEN
    RETURN v_customer_id;
  END IF;
  
  -- إذا لم يوجد، إنشاء سجل جديد
  SELECT full_name, account_number INTO v_source_user_name, v_source_account_number
  FROM app_security
  WHERE id = p_source_user_id;
  
  -- توليد رقم حساب جديد فريد للعميل المتبادل
  v_new_customer_account_number := generate_customer_account_number();
  
  -- إنشاء سجل العميل المتبادل مع رقم الحساب الجديد
  INSERT INTO customers (
    user_id,
    linked_user_id,
    name,
    phone,
    account_number,
    notes
  ) VALUES (
    p_target_user_id,
    p_source_user_id,
    v_source_user_name,
    'LINKED_USER_' || v_source_account_number,
    v_new_customer_account_number,  -- استخدام الرقم الجديد بدلاً من رقم المستخدم
    'تم إنشاؤه تلقائياً للحركات المتبادلة - مرتبط بمستخدم رقم حساب: ' || v_source_account_number
  ) RETURNING id INTO v_customer_id;
  
  RETURN v_customer_id;
END;
$$;

-- 4. تحديث أرقام حسابات العملاء المتبادلين الحاليين (إن وُجدت)
DO $$
DECLARE
  customer_record RECORD;
  new_account_num text;
BEGIN
  -- البحث عن جميع العملاء المتبادلين الحاليين
  FOR customer_record IN 
    SELECT c.id, c.account_number, c.linked_user_id, s.account_number as user_account
    FROM customers c
    INNER JOIN app_security s ON c.linked_user_id = s.id
    WHERE c.linked_user_id IS NOT NULL
      AND c.account_number IS NOT NULL
  LOOP
    -- التحقق إذا كان رقم الحساب متعارض مع رقم حساب المستخدم
    IF customer_record.account_number = customer_record.user_account THEN
      -- توليد رقم حساب جديد
      new_account_num := generate_customer_account_number();
      
      -- تحديث رقم الحساب
      UPDATE customers
      SET account_number = new_account_num,
          notes = COALESCE(notes, '') || ' | تم تحديث رقم الحساب من ' || customer_record.account_number || ' إلى ' || new_account_num
      WHERE id = customer_record.id;
      
      RAISE NOTICE 'تم تحديث رقم حساب العميل المتبادل: % -> %', 
        customer_record.account_number, new_account_num;
    END IF;
  END LOOP;
END $$;

-- 5. التأكد من وجود index فريد على account_number في customers
CREATE UNIQUE INDEX IF NOT EXISTS customers_account_number_unique_idx 
  ON customers(account_number) WHERE account_number IS NOT NULL;

-- 6. إضافة comment توضيحي للدالة
COMMENT ON FUNCTION generate_customer_account_number() IS 
  'تولد رقم حساب فريد للعملاء المتبادلين بدءاً من 30000';

COMMENT ON FUNCTION get_or_create_reciprocal_customer(uuid, uuid) IS 
  'تحصل على أو تنشئ سجل عميل متبادل برقم حساب فريد';

-- 7. تحديث sequence لبدء من الرقم الصحيح إذا كان هناك عملاء متبادلين
DO $$
DECLARE
  max_linked_customer_number text;
  max_number_int int;
BEGIN
  -- الحصول على أعلى رقم حساب للعملاء المتبادلين
  SELECT MAX(account_number) INTO max_linked_customer_number
  FROM customers
  WHERE linked_user_id IS NOT NULL
    AND account_number ~ '^[0-9]+$'; -- أرقام فقط
  
  IF max_linked_customer_number IS NOT NULL THEN
    max_number_int := max_linked_customer_number::int;
    
    -- إذا كان أكبر من 30000، نحدث sequence
    IF max_number_int >= 30000 THEN
      PERFORM setval('reciprocal_customer_account_number_seq', max_number_int + 1, false);
      RAISE NOTICE 'تم تحديث sequence ليبدأ من: %', max_number_int + 1;
    END IF;
  END IF;
END $$;
