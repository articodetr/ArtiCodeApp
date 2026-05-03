/*
  # إصلاح نظام الموافقات للحسابات المرتبطة (Splitwise)

  ## المشكلة
  الحركات على الحسابات المرتبطة تتطلب موافقة (pending) مما يمنع إنشاء الحركة المرآة فوراً.
  - دالة insert_movement_with_user تضبط pending_approval=true و approval_status='pending' للحركات الخارجة
  - الـ trigger trigger_create_mirror_movement ينشئ المرآة فقط عندما approval_status='approved'
  - النتيجة: الحركات لا تظهر للطرف الآخر حتى الموافقة عليها

  ## الحل
  A) تحديث insert_movement_with_user لعدم طلب موافقة للحسابات المرتبطة (incoming و outgoing)
  B) إضافة trigger للأمان: عند تحديث حركة من pending إلى approved، إنشاء المرآة إذا لم تكن موجودة
  C) تحديث البيانات الموجودة: الموافقة تلقائياً على حركات الحسابات المرتبطة المعلقة

  ## السلوك المطلوب (Splitwise)
  - جميع الحركات على الحسابات المرتبطة تُنشأ بحالة 'approved' تلقائياً
  - الحركة المرآة تُنشأ فوراً على الطرف الآخر
  - كلا الطرفين يرون الحركة مباشرة
*/

-- A) تحديث دالة insert_movement_with_user
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
  receipt_number text,
  customer_id uuid,
  movement_type text,
  amount numeric,
  currency text,
  commission numeric,
  commission_currency text,
  created_at timestamptz,
  created_by_user_name text,
  pending_approval boolean,
  approval_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_user_full_name text;
  v_movement_id uuid;
  v_movement_number text;
  v_receipt_number text;
  v_customer record;
  v_needs_approval boolean;
  v_approval_status text;
BEGIN
  -- الحصول على معلومات المستخدم
  SELECT u.id, u.full_name INTO v_user_id, v_user_full_name
  FROM app_security u
  WHERE u.user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found: %', p_user_name;
  END IF;

  -- الحصول على معلومات العميل
  SELECT * INTO v_customer
  FROM customers
  WHERE customers.id = p_customer_id;

  IF v_customer IS NULL THEN
    RAISE EXCEPTION 'Customer not found: %', p_customer_id;
  END IF;

  -- تحديد إذا كانت الحركة تحتاج موافقة
  -- الحسابات المرتبطة (Splitwise): لا تحتاج موافقة أبداً
  v_needs_approval := false;
  v_approval_status := 'approved';
  
  IF v_customer.linked_user_id IS NOT NULL THEN
    -- الحسابات المرتبطة: موافقة تلقائية دائماً (incoming و outgoing)
    v_needs_approval := false;
    v_approval_status := 'approved';
    
    RAISE NOTICE '[insert_movement_with_user] حساب مرتبط - موافقة تلقائية: customer=%, type=%', 
      p_customer_id, p_movement_type;
  END IF;

  -- توليد رقم الحركة
  v_movement_number := generate_movement_number();

  -- إنشاء الحركة
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
    source_user_id,
    created_by_user_id,
    created_by_user_name,
    pending_approval,
    approval_status
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
    v_user_id,
    v_user_id,
    v_user_full_name,
    v_needs_approval,
    v_approval_status
  )
  RETURNING 
    account_movements.id,
    account_movements.movement_number,
    account_movements.receipt_number
  INTO v_movement_id, v_movement_number, v_receipt_number;

  -- إرجاع البيانات
  RETURN QUERY
  SELECT 
    v_movement_id,
    v_movement_number,
    v_receipt_number,
    p_customer_id,
    p_movement_type,
    p_amount,
    p_currency,
    p_commission,
    p_commission_currency,
    NOW(),
    v_user_full_name,
    v_needs_approval,
    v_approval_status;
END;
$$;

COMMENT ON FUNCTION insert_movement_with_user IS 'إدراج حركة مع سياق المستخدم - الحسابات المرتبطة تُوافق تلقائياً';

-- B) إضافة trigger للأمان: إنشاء المرآة عند الموافقة على حركة معلقة
CREATE OR REPLACE FUNCTION trigger_create_mirror_on_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- عند تغيير حالة الموافقة من pending إلى approved
  -- وليس للحركة مرآة بعد، إنشاء المرآة
  IF NEW.approval_status = 'approved' 
     AND OLD.approval_status <> 'approved' 
     AND NEW.mirror_movement_id IS NULL THEN
    
    RAISE NOTICE '[trigger_create_mirror_on_approval] إنشاء مرآة للحركة المعتمدة: %', NEW.id;
    PERFORM create_mirror_movement_v2(NEW.id);
  END IF;
  
  RETURN NEW;
END;
$$;

-- حذف الـ trigger القديم إذا كان موجوداً
DROP TRIGGER IF EXISTS after_movement_approval_create_mirror ON account_movements;

-- إنشاء الـ trigger الجديد
CREATE TRIGGER after_movement_approval_create_mirror
  AFTER UPDATE ON account_movements
  FOR EACH ROW
  WHEN (NEW.approval_status IS DISTINCT FROM OLD.approval_status)
  EXECUTE FUNCTION trigger_create_mirror_on_approval();

COMMENT ON FUNCTION trigger_create_mirror_on_approval IS 'إنشاء حركة مرآة عند الموافقة على حركة كانت معلقة';

-- C) تحديث البيانات الموجودة: الموافقة على حركات الحسابات المرتبطة المعلقة
DO $$
DECLARE
  v_updated_count int;
BEGIN
  -- الموافقة تلقائياً على جميع الحركات المعلقة للحسابات المرتبطة
  UPDATE account_movements m
  SET 
    pending_approval = false,
    approval_status = 'approved'
  WHERE 
    m.approval_status = 'pending'
    AND EXISTS (
      SELECT 1 
      FROM customers c
      WHERE c.id = m.customer_id 
        AND c.linked_user_id IS NOT NULL
    );
  
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  
  RAISE NOTICE '[backfill] تمت الموافقة على % حركة معلقة للحسابات المرتبطة', v_updated_count;
END $$;
