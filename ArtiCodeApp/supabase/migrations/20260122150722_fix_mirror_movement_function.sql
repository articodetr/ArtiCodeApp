/*
  # إصلاح دالة إنشاء الحركات المرآة
  
  تحديث الدالة لإزالة الحقول غير الموجودة وإصلاح الأخطاء
*/

-- إعادة إنشاء دالة create_mirror_movement بدون الحقول غير الموجودة
CREATE OR REPLACE FUNCTION create_mirror_movement()
RETURNS TRIGGER AS $$
DECLARE
  v_linked_user_id uuid;
  v_source_user_id uuid;
  v_reciprocal_customer_id uuid;
  v_mirror_movement_id uuid;
  v_mirror_type text;
BEGIN
  -- تجاهل الحركات التي هي أصلاً حركات مرآة
  IF NEW.mirror_movement_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  
  -- تجاهل حركات العمولة
  IF NEW.is_commission_movement = true THEN
    RETURN NEW;
  END IF;
  
  -- الحصول على linked_user_id و user_id للعميل
  SELECT c.linked_user_id, c.user_id
  INTO v_linked_user_id, v_source_user_id
  FROM customers c
  WHERE c.id = NEW.customer_id;
  
  -- إذا لم يكن العميل مرتبطاً بمستخدم، لا نفعل شيء
  IF v_linked_user_id IS NULL THEN
    -- تحديث source_user_id للحركة الأصلية
    UPDATE account_movements
    SET source_user_id = v_source_user_id
    WHERE id = NEW.id;
    
    RETURN NEW;
  END IF;
  
  -- تحديد نوع الحركة المعاكسة
  IF NEW.movement_type = 'incoming' THEN
    v_mirror_type := 'outgoing';
  ELSE
    v_mirror_type := 'incoming';
  END IF;
  
  -- الحصول على أو إنشاء سجل العميل المتبادل
  v_reciprocal_customer_id := get_or_create_reciprocal_customer(
    v_linked_user_id,
    v_source_user_id
  );
  
  -- إنشاء الحركة المرآة
  INSERT INTO account_movements (
    movement_number,
    customer_id,
    movement_type,
    amount,
    currency,
    commission,
    commission_currency,
    commission_recipient_id,
    notes,
    sender_name,
    beneficiary_name,
    transfer_number,
    receipt_number,
    account_statement_number,
    source_user_id,
    mirror_movement_id,
    is_commission_movement
  ) VALUES (
    NEW.movement_number || '-M',
    v_reciprocal_customer_id,
    v_mirror_type,
    NEW.amount,
    NEW.currency,
    NEW.commission,
    NEW.commission_currency,
    NEW.commission_recipient_id,
    CASE 
      WHEN NEW.notes IS NOT NULL THEN 'حركة مرآة: ' || NEW.notes
      ELSE 'حركة مرآة'
    END,
    NEW.sender_name,
    NEW.beneficiary_name,
    NEW.transfer_number,
    NEW.receipt_number,
    NEW.account_statement_number,
    v_linked_user_id,
    NEW.id,
    false
  ) RETURNING id INTO v_mirror_movement_id;
  
  -- تحديث الحركة الأصلية بمعرف الحركة المرآة
  UPDATE account_movements
  SET mirror_movement_id = v_mirror_movement_id,
      source_user_id = v_source_user_id
  WHERE id = NEW.id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
