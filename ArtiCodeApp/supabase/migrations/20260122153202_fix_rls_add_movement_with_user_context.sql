/*
  # إصلاح مشكلة RLS عند إضافة الحركات

  ## المشكلة
  - سياسة RLS تعتمد على `current_setting('app.current_user')`
  - الإعداد لا يبقى في الاتصالات المعاد استخدامها (connection pooling)
  - تفشل عمليات INSERT بسبب عدم وجود المستخدم في السياق

  ## الحل
  إنشاء دالة محمية (SECURITY DEFINER) تقوم بـ:
  1. استقبال معلومات الحركة + اسم المستخدم
  2. تعيين المستخدم في السياق
  3. إدخال الحركة في معاملة واحدة
  4. إرجاع البيانات المدخلة

  ## الدالة
  - `insert_movement_with_user`: دالة آمنة لإدخال الحركات مع تعيين المستخدم
*/

-- دالة لإدخال حركة مع تعيين المستخدم في السياق
CREATE OR REPLACE FUNCTION insert_movement_with_user(
  p_user_name text,
  p_customer_id uuid,
  p_movement_type text,
  p_amount numeric,
  p_currency text,
  p_notes text DEFAULT NULL,
  p_sender_name text DEFAULT NULL,
  p_beneficiary_name text DEFAULT NULL,
  p_commission numeric DEFAULT NULL,
  p_commission_currency text DEFAULT NULL,
  p_commission_recipient_id uuid DEFAULT NULL
)
RETURNS TABLE(
  id uuid,
  movement_number text,
  customer_id uuid,
  movement_type text,
  amount numeric,
  currency text,
  notes text,
  created_at timestamptz,
  sender_name text,
  beneficiary_name text,
  commission numeric,
  commission_currency text,
  commission_recipient_id uuid,
  receipt_number text,
  account_statement_number text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_movement_id uuid;
  v_movement_number text;
BEGIN
  -- تعيين المستخدم الحالي في السياق
  PERFORM set_config('app.current_user', p_user_name, false);
  
  -- توليد رقم الحركة
  v_movement_number := 'M' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(NEXTVAL('movement_number_seq')::text, 6, '0');
  
  -- إدخال الحركة
  INSERT INTO account_movements (
    movement_number,
    customer_id,
    movement_type,
    amount,
    currency,
    notes,
    sender_name,
    beneficiary_name,
    commission,
    commission_currency,
    commission_recipient_id,
    is_commission_movement
  ) VALUES (
    v_movement_number,
    p_customer_id,
    p_movement_type,
    p_amount,
    p_currency,
    p_notes,
    p_sender_name,
    p_beneficiary_name,
    p_commission,
    p_commission_currency,
    p_commission_recipient_id,
    false
  )
  RETURNING 
    account_movements.id,
    account_movements.movement_number,
    account_movements.customer_id,
    account_movements.movement_type,
    account_movements.amount,
    account_movements.currency,
    account_movements.notes,
    account_movements.created_at,
    account_movements.sender_name,
    account_movements.beneficiary_name,
    account_movements.commission,
    account_movements.commission_currency,
    account_movements.commission_recipient_id,
    account_movements.receipt_number,
    account_movements.account_statement_number
  INTO 
    v_movement_id,
    v_movement_number,
    p_customer_id,
    p_movement_type,
    p_amount,
    p_currency,
    p_notes,
    created_at,
    p_sender_name,
    p_beneficiary_name,
    p_commission,
    p_commission_currency,
    p_commission_recipient_id,
    receipt_number,
    account_statement_number;
  
  -- إرجاع البيانات
  RETURN QUERY
  SELECT 
    v_movement_id,
    v_movement_number,
    p_customer_id,
    p_movement_type,
    p_amount,
    p_currency,
    p_notes,
    created_at,
    p_sender_name,
    p_beneficiary_name,
    p_commission,
    p_commission_currency,
    p_commission_recipient_id,
    receipt_number,
    account_statement_number;
END;
$$;

-- منح الصلاحيات
GRANT EXECUTE ON FUNCTION insert_movement_with_user(text, uuid, text, numeric, text, text, text, text, numeric, text, uuid) TO anon, authenticated;

-- إنشاء sequence إذا لم يكن موجوداً
CREATE SEQUENCE IF NOT EXISTS movement_number_seq START WITH 1;
