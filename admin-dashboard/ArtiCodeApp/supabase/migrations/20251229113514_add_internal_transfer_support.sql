/*
  # إضافة دعم التحويلات الداخلية (Internal Transfers)
  
  ## الهدف
  السماح بتنفيذ التحويلات التالية:
  1. عميل → عميل (تحويل بين حسابين)
  2. المحل → عميل (صرف من حساب المحل)
  3. عميل → المحل (إيداع في حساب المحل)
  
  ## منطق الحساب (حسب النظام B)
  - رصيد العميل = مديونية على العميل لصالح المحل
  - موجب (+): لنا عنده
  - سالب (-): له عندنا
  
  ### التحويلات
  1. **عميل → عميل بمبلغ X**:
     - المُحوِّل (From): balance += X (تسليم له)
     - المُحوَّل إليه (To): balance -= X (استلام منه)
     - رصيد المحل: لا يتغير
  
  2. **المحل → عميل بمبلغ X**:
     - العميل: balance += X (تسليم له)
     - حركة واحدة: incoming
  
  3. **عميل → المحل بمبلغ X**:
     - العميل: balance -= X (استلام منه)
     - حركة واحدة: outgoing
  
  ## التغييرات
  
  ### 1. إضافة حقول جديدة لجدول account_movements
  - `from_customer_id`: معرف العميل المُحوِّل (null إذا كان المحل)
  - `to_customer_id`: معرف العميل المُحوَّل إليه (null إذا كان المحل)
  - `transfer_direction`: اتجاه التحويل
  - `related_transfer_id`: ربط الحركة بالحركة المقابلة (للتحويلات بين عميلين)
  
  ### 2. دالة إنشاء التحويل الداخلي
  - create_internal_transfer(): إنشاء تحويل داخلي بشكل آمن
  - التحقق من صحة البيانات
  - إنشاء حركتين مترابطتين في حالة عميل-عميل
  
  ### 3. تحديثات الأمان
  - إضافة RLS policies للحقول الجديدة
*/

-- 1. إضافة الحقول الجديدة لجدول account_movements
ALTER TABLE account_movements 
ADD COLUMN IF NOT EXISTS from_customer_id uuid REFERENCES customers(id) ON DELETE CASCADE,
ADD COLUMN IF NOT EXISTS to_customer_id uuid REFERENCES customers(id) ON DELETE CASCADE,
ADD COLUMN IF NOT EXISTS transfer_direction text CHECK (transfer_direction IN ('shop_to_customer', 'customer_to_shop', 'customer_to_customer')),
ADD COLUMN IF NOT EXISTS related_transfer_id uuid REFERENCES account_movements(id) ON DELETE SET NULL;

-- 2. إنشاء فهرس للأداء
CREATE INDEX IF NOT EXISTS account_movements_from_customer_idx ON account_movements(from_customer_id);
CREATE INDEX IF NOT EXISTS account_movements_to_customer_idx ON account_movements(to_customer_id);
CREATE INDEX IF NOT EXISTS account_movements_transfer_direction_idx ON account_movements(transfer_direction);
CREATE INDEX IF NOT EXISTS account_movements_related_transfer_idx ON account_movements(related_transfer_id);

-- 3. دالة لإنشاء تحويل داخلي
CREATE OR REPLACE FUNCTION create_internal_transfer(
  p_from_customer_id uuid,
  p_to_customer_id uuid,
  p_amount decimal,
  p_currency text,
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  from_movement_id uuid,
  to_movement_id uuid,
  success boolean,
  message text
) AS $$
DECLARE
  v_from_movement_id uuid;
  v_to_movement_id uuid;
  v_from_movement_number text;
  v_to_movement_number text;
  v_transfer_direction text;
  v_from_customer_name text;
  v_to_customer_name text;
BEGIN
  -- التحقق من صحة البيانات
  IF p_amount <= 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'المبلغ يجب أن يكون أكبر من صفر'::text;
    RETURN;
  END IF;
  
  -- التحقق من عدم التحويل لنفس الطرف
  IF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NOT NULL AND p_from_customer_id = p_to_customer_id THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'لا يمكن التحويل لنفس العميل'::text;
    RETURN;
  END IF;
  
  -- تحديد اتجاه التحويل
  IF p_from_customer_id IS NULL AND p_to_customer_id IS NOT NULL THEN
    v_transfer_direction := 'shop_to_customer';
  ELSIF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NULL THEN
    v_transfer_direction := 'customer_to_shop';
  ELSIF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NOT NULL THEN
    v_transfer_direction := 'customer_to_customer';
  ELSE
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'يجب تحديد طرف واحد على الأقل'::text;
    RETURN;
  END IF;
  
  -- الحصول على أسماء الأطراف
  IF p_from_customer_id IS NOT NULL THEN
    SELECT name INTO v_from_customer_name FROM customers WHERE id = p_from_customer_id;
    IF v_from_customer_name IS NULL THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العميل المُحوِّل غير موجود'::text;
      RETURN;
    END IF;
  ELSE
    v_from_customer_name := 'المحل';
  END IF;
  
  IF p_to_customer_id IS NOT NULL THEN
    SELECT name INTO v_to_customer_name FROM customers WHERE id = p_to_customer_id;
    IF v_to_customer_name IS NULL THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العميل المُحوَّل إليه غير موجود'::text;
      RETURN;
    END IF;
  ELSE
    v_to_customer_name := 'المحل';
  END IF;
  
  -- البدء بـ transaction
  BEGIN
    -- حالة 1: المحل → عميل (تسليم للعميل)
    IF v_transfer_direction = 'shop_to_customer' THEN
      v_to_movement_number := generate_movement_number();
      
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        sender_name,
        beneficiary_name
      ) VALUES (
        v_to_movement_number,
        p_to_customer_id,
        'incoming',
        p_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        NULL,
        p_to_customer_id,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name
      ) RETURNING id INTO v_to_movement_id;
      
      RETURN QUERY SELECT NULL::uuid, v_to_movement_id, true, 'تم التحويل بنجاح من المحل إلى ' || v_to_customer_name::text;
      RETURN;
    
    -- حالة 2: عميل → المحل (استلام من العميل)
    ELSIF v_transfer_direction = 'customer_to_shop' THEN
      v_from_movement_number := generate_movement_number();
      
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        sender_name,
        beneficiary_name
      ) VALUES (
        v_from_movement_number,
        p_from_customer_id,
        'outgoing',
        p_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        NULL,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name
      ) RETURNING id INTO v_from_movement_id;
      
      RETURN QUERY SELECT v_from_movement_id, NULL::uuid, true, 'تم التحويل بنجاح من ' || v_from_customer_name || ' إلى المحل'::text;
      RETURN;
    
    -- حالة 3: عميل → عميل (إنشاء حركتين مترابطتين)
    ELSIF v_transfer_direction = 'customer_to_customer' THEN
      v_from_movement_number := generate_movement_number();
      v_to_movement_number := generate_movement_number();
      
      -- حركة العميل المُحوِّل (تسليم له = incoming)
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        sender_name,
        beneficiary_name
      ) VALUES (
        v_from_movement_number,
        p_from_customer_id,
        'incoming',
        p_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        p_to_customer_id,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name
      ) RETURNING id INTO v_from_movement_id;
      
      -- حركة العميل المُحوَّل إليه (استلام منه = outgoing)
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        from_customer_id,
        to_customer_id,
        transfer_direction,
        related_transfer_id,
        sender_name,
        beneficiary_name
      ) VALUES (
        v_to_movement_number,
        p_to_customer_id,
        'outgoing',
        p_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        p_to_customer_id,
        v_transfer_direction,
        v_from_movement_id,
        v_from_customer_name,
        v_to_customer_name
      ) RETURNING id INTO v_to_movement_id;
      
      -- ربط الحركة الأولى بالثانية
      UPDATE account_movements
      SET related_transfer_id = v_to_movement_id
      WHERE id = v_from_movement_id;
      
      RETURN QUERY SELECT v_from_movement_id, v_to_movement_id, true, 'تم التحويل بنجاح من ' || v_from_customer_name || ' إلى ' || v_to_customer_name::text;
      RETURN;
    END IF;
    
  EXCEPTION
    WHEN OTHERS THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'خطأ في إنشاء التحويل: ' || SQLERRM::text;
      RETURN;
  END;
END;
$$ LANGUAGE plpgsql;

-- 4. إضافة RLS policies للحقول الجديدة (الوصول الكامل)
-- السياسات الموجودة تغطي الجدول بالكامل، لا حاجة لإضافة سياسات جديدة