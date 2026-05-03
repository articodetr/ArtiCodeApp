/*
  # إصلاح نظام العملاء المتبادلين - استخدام نفس رقم الحساب
  
  ## المشكلة
  عندما يضيف مستخدم (مثلاً جلال أحمد رقم 26001) مستخدماً آخر (مثلاً جلال رقم 26009) كعميل،
  النظام الحالي ينشئ رقم حساب جديد (30000+) للعميل المتبادل.
  
  المطلوب: استخدام نفس رقم حساب المستخدم المستهدف (26009) في جدول customers،
  حتى عندما يسجل جلال أحمد حركة على جلال، تظهر الحركة المرآة في حساب جلال (26009).
  
  ## الحل
  
  ### 1. إزالة جميع القيود الفريدة على account_number
  - السماح بتكرار نفس رقم الحساب لمستخدمين مختلفين
  - كل مستخدم يرى رقم الحساب الحقيقي للمستخدم المرتبط
  
  ### 2. تحديث العملاء المتبادلين الحاليين
  - استرجاع أرقام الحسابات الأصلية من app_security
  
  ### 3. إضافة قيود فريدة مركبة
  - منع تكرار (user_id, linked_user_id) - لا يمكن ربط نفس المستخدم مرتين
  - منع تكرار (user_id, account_number) للعملاء العاديين فقط
  
  ### 4. تحديث الدوال
  - استخدام account_number من app_security مباشرة
  
  ## الأمان
  - الحفاظ على جميع سياسات RLS
  - القيود الفريدة تمنع التكرار غير المسموح
*/

-- 1. إزالة جميع القيود الفريدة على account_number في جدول customers
DROP INDEX IF EXISTS customers_account_number_unique_idx;
DROP INDEX IF EXISTS customers_account_number_idx;

-- حذف أي constraint فريد على account_number
DO $$
DECLARE
  constraint_rec RECORD;
BEGIN
  FOR constraint_rec IN 
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'customers'::regclass
      AND contype = 'u'
      AND ARRAY[(SELECT attnum FROM pg_attribute 
                 WHERE attrelid = 'customers'::regclass 
                 AND attname = 'account_number')] && conkey
  LOOP
    EXECUTE 'ALTER TABLE customers DROP CONSTRAINT ' || quote_ident(constraint_rec.conname);
    RAISE NOTICE 'تم حذف القيد: %', constraint_rec.conname;
  END LOOP;
END $$;

-- 2. تحديث أرقام حسابات العملاء المتبادلين الحاليين
DO $$
DECLARE
  customer_record RECORD;
  update_count int := 0;
BEGIN
  -- البحث عن جميع العملاء المتبادلين
  FOR customer_record IN 
    SELECT 
      c.id, 
      c.account_number as current_account_number,
      c.linked_user_id, 
      s.account_number as correct_account_number,
      s.full_name as linked_user_name
    FROM customers c
    INNER JOIN app_security s ON c.linked_user_id = s.id
    WHERE c.linked_user_id IS NOT NULL
      AND c.account_number IS NOT NULL
      AND c.account_number != s.account_number  -- فقط الذين يحتاجون تحديث
  LOOP
    -- تحديث رقم الحساب ليكون نفس رقم حساب المستخدم المرتبط
    UPDATE customers
    SET 
      account_number = customer_record.correct_account_number,
      notes = COALESCE(notes, '') || E'\n' || 
              '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || '] ' ||
              'تم تحديث رقم الحساب من ' || customer_record.current_account_number || 
              ' إلى ' || customer_record.correct_account_number || ' (رقم الحساب الحقيقي للمستخدم ' || 
              customer_record.linked_user_name || ')'
    WHERE id = customer_record.id;
    
    update_count := update_count + 1;
    RAISE NOTICE 'تم تحديث العميل المتبادل [%]: % -> % (%)', 
      update_count,
      customer_record.current_account_number, 
      customer_record.correct_account_number,
      customer_record.linked_user_name;
  END LOOP;
  
  RAISE NOTICE 'تم تحديث % عميل متبادل', update_count;
END $$;

-- 3. إضافة قيد فريد مركب: منع تكرار (user_id, linked_user_id)
-- هذا يضمن أن كل مستخدم لا يمكنه ربط نفس المستخدم الآخر أكثر من مرة
CREATE UNIQUE INDEX IF NOT EXISTS customers_user_linked_user_unique_idx
  ON customers(user_id, linked_user_id)
  WHERE linked_user_id IS NOT NULL;

-- 4. إضافة قيد فريد على (user_id, account_number) للعملاء العاديين فقط
-- هذا يضمن أن المستخدم الواحد لا يمكنه إنشاء عميلين عاديين بنفس رقم الحساب
CREATE UNIQUE INDEX IF NOT EXISTS customers_user_account_number_unique_idx
  ON customers(user_id, account_number)
  WHERE linked_user_id IS NULL AND account_number IS NOT NULL;

-- 5. تحديث دالة get_or_create_reciprocal_customer لاستخدام نفس رقم الحساب
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
  
  -- إذا لم يوجد، الحصول على معلومات المستخدم الأصلي
  SELECT full_name, account_number INTO v_source_user_name, v_source_account_number
  FROM app_security
  WHERE id = p_source_user_id;
  
  IF v_source_account_number IS NULL THEN
    RAISE EXCEPTION 'المستخدم الأصلي ليس له رقم حساب';
  END IF;
  
  -- إنشاء سجل العميل المتبادل باستخدام نفس رقم حساب المستخدم الأصلي
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
    v_source_account_number,  -- استخدام نفس رقم الحساب من app_security
    'تم إنشاؤه تلقائياً للحركات المتبادلة - رقم الحساب الحقيقي: ' || v_source_account_number
  ) RETURNING id INTO v_customer_id;
  
  RETURN v_customer_id;
END;
$$;

-- 6. تحديث دالة create_linked_customer لاستخدام نفس رقم الحساب
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

  -- إنشاء سجل العميل المرتبط باستخدام نفس رقم الحساب من app_security
  INSERT INTO customers (
    user_id,
    linked_user_id,
    name,
    phone,
    account_number,  -- استخدام نفس رقم حساب المستخدم
    notes
  ) VALUES (
    p_owner_user_id,
    p_linked_user_id,
    COALESCE(p_customer_name, v_linked_user_name),
    'LINKED_USER_' || v_linked_account_number,
    v_linked_account_number,  -- نفس رقم الحساب من app_security
    'عميل مرتبط بمستخدم مسجل - رقم الحساب الحقيقي: ' || v_linked_account_number
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

  RETURN QUERY SELECT true, v_customer_id, 'تم ربط المستخدم كعميل بنجاح - رقم الحساب: ' || v_linked_account_number::text;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. إضافة comments توضيحية
COMMENT ON FUNCTION get_or_create_reciprocal_customer(uuid, uuid) IS 
  'تحصل على أو تنشئ سجل عميل متبادل باستخدام نفس رقم حساب المستخدم من app_security';

COMMENT ON FUNCTION create_linked_customer(uuid, uuid, text) IS 
  'تنشئ عميل مرتبط بمستخدم مسجل باستخدام نفس رقم حساب المستخدم';

-- 8. حذف الـ sequence الذي لم نعد نحتاجه
DROP SEQUENCE IF EXISTS reciprocal_customer_account_number_seq;

-- 9. حذف دالة generate_customer_account_number التي لم نعد نحتاجها
DROP FUNCTION IF EXISTS generate_customer_account_number();

-- 10. عرض ملخص التغييرات
DO $$
DECLARE
  linked_customers_count int;
BEGIN
  SELECT COUNT(*) INTO linked_customers_count
  FROM customers
  WHERE linked_user_id IS NOT NULL;
  
  RAISE NOTICE '=====================================';
  RAISE NOTICE 'تم إصلاح نظام العملاء المتبادلين بنجاح';
  RAISE NOTICE '=====================================';
  RAISE NOTICE 'عدد العملاء المتبادلين: %', linked_customers_count;
  RAISE NOTICE 'الآن يستخدم كل عميل متبادل نفس رقم حساب المستخدم المرتبط';
  RAISE NOTICE '=====================================';
END $$;
