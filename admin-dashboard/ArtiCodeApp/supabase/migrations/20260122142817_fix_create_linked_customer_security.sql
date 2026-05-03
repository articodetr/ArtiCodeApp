/*
  # Fix create_linked_customer Function Security

  1. Changes
    - Update `create_linked_customer` function to use SECURITY DEFINER
    - This allows the function to bypass RLS policies when creating linked customers
    - The function will run with the privileges of the function owner (postgres user)
  
  2. Security
    - The function still validates all inputs and business logic
    - Only allows linking valid users who exist in app_security
    - Prevents duplicate linking and self-linking
*/

-- Drop and recreate the function with SECURITY DEFINER
DROP FUNCTION IF EXISTS create_linked_customer(uuid, uuid, text);

CREATE OR REPLACE FUNCTION create_linked_customer(
  p_owner_user_id uuid,
  p_linked_user_id uuid,
  p_customer_name text
)
RETURNS TABLE (
  success boolean,
  customer_id uuid,
  message text
) 
SECURITY DEFINER  -- This allows the function to bypass RLS
SET search_path = public
AS $$
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