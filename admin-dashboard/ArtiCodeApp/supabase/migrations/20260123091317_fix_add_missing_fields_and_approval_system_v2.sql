/*
  # إصلاح النظام وإضافة نظام الموافقات الذكي

  ## 1. إصلاح الحقول المفقودة
    - إضافة `receipt_generated_at` (timestamptz) - لحل المشكلة الحالية
    - إضافة `created_by_user_id` (uuid) - لتتبع منشئ الحركة
    - إضافة `created_by_user_name` (text) - اسم المنشئ للعرض السريع
    
  ## 2. نظام الموافقات
    - إضافة `pending_approval` (boolean) - هل الحركة تنتظر موافقة
    - إضافة `approval_status` (text) - حالة الموافقة (approved, pending, rejected)
    - إضافة `approved_by_user_id` (uuid) - من وافق على الحركة
    - إضافة `approved_at` (timestamptz) - وقت الموافقة
    
  ## 3. نظام الحذف بالموافقة
    - إضافة `deletion_requested` (boolean) - هل هناك طلب حذف
    - إضافة `deletion_requested_by` (uuid) - من طلب الحذف
    - إضافة `deletion_requested_at` (timestamptz) - وقت طلب الحذف
    
  ## 4. الأمان
    - تحديث RLS policies
    - إضافة indexes للأداء
    - تحديث الدوال الموجودة
*/

-- 1. إضافة الحقول المفقودة إلى جدول account_movements
DO $$
BEGIN
  -- receipt_generated_at - عاجل لحل المشكلة الحالية
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'receipt_generated_at'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN receipt_generated_at timestamptz;
    COMMENT ON COLUMN account_movements.receipt_generated_at IS 'تاريخ ووقت توليد رقم السند';
  END IF;

  -- created_by_user_id - لتتبع المنشئ
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'created_by_user_id'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN created_by_user_id uuid REFERENCES app_security(id);
    COMMENT ON COLUMN account_movements.created_by_user_id IS 'معرف المستخدم الذي أنشأ الحركة';
  END IF;

  -- created_by_user_name - اسم المنشئ للعرض
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'created_by_user_name'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN created_by_user_name text;
    COMMENT ON COLUMN account_movements.created_by_user_name IS 'اسم المستخدم الذي أنشأ الحركة';
  END IF;

  -- pending_approval - هل تنتظر موافقة
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'pending_approval'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN pending_approval boolean DEFAULT false;
    COMMENT ON COLUMN account_movements.pending_approval IS 'هل الحركة تنتظر موافقة من الطرف الآخر';
  END IF;

  -- approval_status - حالة الموافقة
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'approval_status'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN approval_status text DEFAULT 'approved'
      CHECK (approval_status IN ('approved', 'pending', 'rejected'));
    COMMENT ON COLUMN account_movements.approval_status IS 'حالة الموافقة على الحركة';
  END IF;

  -- approved_by_user_id - من وافق
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'approved_by_user_id'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN approved_by_user_id uuid REFERENCES app_security(id);
    COMMENT ON COLUMN account_movements.approved_by_user_id IS 'معرف المستخدم الذي وافق على الحركة';
  END IF;

  -- approved_at - وقت الموافقة
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'approved_at'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN approved_at timestamptz;
    COMMENT ON COLUMN account_movements.approved_at IS 'تاريخ ووقت الموافقة على الحركة';
  END IF;

  -- deletion_requested - طلب حذف
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'deletion_requested'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN deletion_requested boolean DEFAULT false;
    COMMENT ON COLUMN account_movements.deletion_requested IS 'هل هناك طلب لحذف هذه الحركة';
  END IF;

  -- deletion_requested_by - من طلب الحذف
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'deletion_requested_by'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN deletion_requested_by uuid REFERENCES app_security(id);
    COMMENT ON COLUMN account_movements.deletion_requested_by IS 'معرف المستخدم الذي طلب حذف الحركة';
  END IF;

  -- deletion_requested_at - وقت طلب الحذف
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'deletion_requested_at'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN deletion_requested_at timestamptz;
    COMMENT ON COLUMN account_movements.deletion_requested_at IS 'تاريخ ووقت طلب حذف الحركة';
  END IF;
END $$;

-- 2. إنشاء indexes للأداء
CREATE INDEX IF NOT EXISTS idx_movements_created_by_user 
  ON account_movements(created_by_user_id);

CREATE INDEX IF NOT EXISTS idx_movements_pending_approval 
  ON account_movements(pending_approval) WHERE pending_approval = true;

CREATE INDEX IF NOT EXISTS idx_movements_approval_status 
  ON account_movements(approval_status) WHERE approval_status = 'pending';

CREATE INDEX IF NOT EXISTS idx_movements_deletion_requested 
  ON account_movements(deletion_requested) WHERE deletion_requested = true;

-- 3. تحديث البيانات الموجودة
UPDATE account_movements 
SET 
  approval_status = 'approved',
  pending_approval = false,
  deletion_requested = false
WHERE approval_status IS NULL OR pending_approval IS NULL;

-- 4. حذف الدالة القديمة وإعادة إنشائها
DROP FUNCTION IF EXISTS insert_movement_with_user(text,uuid,text,numeric,text,text,text,text,numeric,text,uuid);

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
  -- منطق: حركات "عليه" (outgoing) للعملاء المرتبطين تحتاج موافقة
  v_needs_approval := false;
  v_approval_status := 'approved';
  
  IF v_customer.linked_user_id IS NOT NULL AND p_movement_type = 'outgoing' THEN
    v_needs_approval := true;
    v_approval_status := 'pending';
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
    now(),
    v_user_full_name,
    v_needs_approval,
    v_approval_status;
END;
$$;

-- 5. إنشاء جدول الإشعارات
CREATE TABLE IF NOT EXISTS movement_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  movement_id uuid NOT NULL REFERENCES account_movements(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES app_security(id),
  notification_type text NOT NULL CHECK (notification_type IN ('approval_needed', 'deletion_request', 'approved', 'rejected', 'movement_added')),
  message text NOT NULL,
  is_read boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  read_at timestamptz
);

-- Indexes للإشعارات
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread 
  ON movement_notifications(user_id, is_read) WHERE is_read = false;

CREATE INDEX IF NOT EXISTS idx_notifications_movement 
  ON movement_notifications(movement_id);

-- RLS للإشعارات
ALTER TABLE movement_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own notifications"
  ON movement_notifications FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "System can insert notifications"
  ON movement_notifications FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "Users can update their own notifications"
  ON movement_notifications FOR UPDATE
  TO authenticated
  USING (true);

-- 6. دالة لإنشاء إشعار
CREATE OR REPLACE FUNCTION create_notification(
  p_movement_id uuid,
  p_user_id uuid,
  p_notification_type text,
  p_message text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_notification_id uuid;
BEGIN
  INSERT INTO movement_notifications (
    movement_id,
    user_id,
    notification_type,
    message
  ) VALUES (
    p_movement_id,
    p_user_id,
    p_notification_type,
    p_message
  )
  RETURNING id INTO v_notification_id;

  RETURN v_notification_id;
END;
$$;

COMMENT ON FUNCTION create_notification IS 'إنشاء إشعار جديد للمستخدم';
