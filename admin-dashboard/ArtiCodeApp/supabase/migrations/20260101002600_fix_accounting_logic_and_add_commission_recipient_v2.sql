/*
  # إصلاح المنطق المحاسبي وإضافة نظام اختيار مستلم العمولة
  
  ## المشكلة المُصلّحة
  
  ### 1. المنطق المحاسبي المقلوب في customer_to_customer
  المشكلة: عند التحويل بين عميلين، كانت الحركات معكوسة:
    - المُحوِّل (from): incoming ❌ (يزيد رصيده بدلاً من أن ينقص)
    - المُحوَّل إليه (to): outgoing ❌ (ينقص رصيده بدلاً من أن يزيد)
  
  الحل: تبديل movement_type في حالة customer_to_customer:
    - المُحوِّل (from): outgoing ✅ (ينقص رصيده)
    - المُحوَّل إليه (to): incoming ✅ (يزيد رصيده)
  
  ### 2. نظام اختيار مستلم العمولة
  الميزة الجديدة: السماح باختيار من يستلم العمولة:
    - المُحوِّل (from): العمولة تُضاف لحركته (يدفع أقل)
    - المُحوَّل إليه (to): العمولة تُضاف لحركته (يحصل على أكثر)
    - NULL (افتراضي): العمولة تذهب لحساب الأرباح والخسائر
  
  ## التغييرات
  
  ### 1. إضافة حقل commission_recipient_id
    - نوع: uuid NULL
    - مرجع: customers(id)
    - معنى: من يستلم العمولة (NULL = الأرباح والخسائر)
  
  ### 2. تحديث دالة create_internal_transfer
    - إضافة معامل p_commission_recipient_id
    - إصلاح المنطق المحاسبي في customer_to_customer
    - توزيع العمولة حسب المستلم:
      * إذا = from_customer_id: العمولة تُطرح من المبلغ المخصوم
      * إذا = to_customer_id: العمولة تُضاف للمبلغ المُضاف
      * إذا = NULL: العمولة للأرباح والخسائر (trigger يتعامل معها)
  
  ### 3. تحديث trigger العمولة
    - الـ trigger يعمل فقط عند: commission > 0 AND commission_recipient_id IS NULL
    - إذا كان commission_recipient_id محدد: لا يُنشئ حركة منفصلة (العمولة مضمنة)
  
  ## الأمثلة
  
  ### مثال: جلال يحول 5000$ لعماد بعمولة 50$
  
  **1. العمولة لجلال (المُحوِّل):**
    ```
    p_commission_recipient_id = جلال
    - جلال: outgoing بمبلغ 4950$ (5000 - 50)
    - عماد: incoming بمبلغ 5000$
    ```
  
  **2. العمولة لعماد (المُحوَّل إليه):**
    ```
    p_commission_recipient_id = عماد
    - جلال: outgoing بمبلغ 5000$
    - عماد: incoming بمبلغ 5050$ (5000 + 50)
    ```
  
  **3. العمولة للأرباح والخسائر (افتراضي):**
    ```
    p_commission_recipient_id = NULL
    - جلال: outgoing بمبلغ 5000$
    - عماد: incoming بمبلغ 5000$
    - الأرباح والخسائر: incoming بمبلغ 50$ (حركة منفصلة)
    ```
  
  ## الملاحظات
  - الحركات القديمة لا تتأثر (commission_recipient_id = NULL)
  - يمكن تعديل مستلم العمولة بعد الحفظ
  - التحقق من صحة الاختيار (يجب أن يكون أحد الأطراف أو NULL)
*/

-- 1. إضافة حقل commission_recipient_id
ALTER TABLE account_movements 
ADD COLUMN IF NOT EXISTS commission_recipient_id uuid REFERENCES customers(id) ON DELETE SET NULL;

-- 2. إنشاء index للأداء
CREATE INDEX IF NOT EXISTS account_movements_commission_recipient_idx 
ON account_movements(commission_recipient_id);

-- 3. حذف الـ trigger والدالة القديمة
DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss();

-- 4. حذف النسخ القديمة من دالة create_internal_transfer
DROP FUNCTION IF EXISTS create_internal_transfer(uuid, uuid, decimal, text, text);
DROP FUNCTION IF EXISTS create_internal_transfer(uuid, uuid, decimal, text, text, decimal, text);

-- 5. إنشاء دالة trigger جديدة (تعمل فقط عند commission_recipient_id = NULL)
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  profit_loss_id uuid;
  next_movement_num text;
BEGIN
  -- التحقق من وجود عمولة وأن المستلم غير محدد
  IF NEW.commission IS NULL 
     OR NEW.commission = 0 
     OR NEW.commission_recipient_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- الحصول على معرف حساب الأرباح والخسائر
  SELECT id INTO profit_loss_id
  FROM customers
  WHERE is_profit_loss_account = true
  LIMIT 1;

  -- التحقق من وجود الحساب
  IF profit_loss_id IS NULL THEN
    RAISE EXCEPTION 'حساب الأرباح والخسائر غير موجود';
  END IF;

  -- الحصول على رقم الحركة التالي
  SELECT generate_movement_number() INTO next_movement_num;

  -- إنشاء حركة العمولة في حساب الأرباح والخسائر
  INSERT INTO account_movements (
    customer_id,
    amount,
    commission,
    currency,
    commission_currency,
    movement_type,
    movement_number,
    notes,
    created_at
  ) VALUES (
    profit_loss_id,
    NEW.commission,
    0,
    NEW.commission_currency,
    NEW.commission_currency,
    'incoming',
    next_movement_num,
    'عمولة من حركة رقم ' || NEW.movement_number,
    NEW.created_at
  );

  RETURN NEW;
END;
$$;

-- 6. إنشاء trigger جديد
CREATE TRIGGER trigger_record_commission
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss();

-- 7. إنشاء دالة create_internal_transfer الجديدة مع إصلاح المنطق وإضافة commission_recipient
CREATE OR REPLACE FUNCTION create_internal_transfer(
  p_from_customer_id uuid,
  p_to_customer_id uuid,
  p_amount decimal,
  p_currency text,
  p_notes text DEFAULT NULL,
  p_commission decimal DEFAULT NULL,
  p_commission_currency text DEFAULT 'USD',
  p_commission_recipient_id uuid DEFAULT NULL
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
  v_from_amount decimal;
  v_to_amount decimal;
  v_commission_for_from boolean := false;
  v_commission_for_to boolean := false;
BEGIN
  -- التحقق من صحة البيانات
  IF p_amount <= 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'المبلغ يجب أن يكون أكبر من صفر'::text;
    RETURN;
  END IF;

  -- التحقق من صحة العمولة إذا كانت موجودة
  IF p_commission IS NOT NULL AND p_commission < 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العمولة يجب أن تكون صفر أو أكبر'::text;
    RETURN;
  END IF;

  -- التحقق من عدم التحويل لنفس الطرف
  IF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NOT NULL AND p_from_customer_id = p_to_customer_id THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'لا يمكن التحويل لنفس العميل'::text;
    RETURN;
  END IF;

  -- التحقق من صحة مستلم العمولة
  IF p_commission_recipient_id IS NOT NULL THEN
    IF p_commission_recipient_id != p_from_customer_id AND p_commission_recipient_id != p_to_customer_id THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'مستلم العمولة يجب أن يكون أحد أطراف التحويل'::text;
      RETURN;
    END IF;
    
    -- تحديد من سيستلم العمولة
    v_commission_for_from := (p_commission_recipient_id = p_from_customer_id);
    v_commission_for_to := (p_commission_recipient_id = p_to_customer_id);
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

  -- حساب المبالغ مع العمولة
  v_from_amount := p_amount;
  v_to_amount := p_amount;

  -- إذا كانت العمولة للمُحوِّل: يدفع أقل
  IF p_commission IS NOT NULL AND p_commission > 0 AND v_commission_for_from THEN
    v_from_amount := p_amount - p_commission;
  END IF;

  -- إذا كانت العمولة للمُحوَّل إليه: يحصل على أكثر
  IF p_commission IS NOT NULL AND p_commission > 0 AND v_commission_for_to THEN
    v_to_amount := p_amount + p_commission;
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
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
      ) VALUES (
        v_to_movement_number,
        p_to_customer_id,
        'incoming',
        v_to_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        NULL,
        p_to_customer_id,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name,
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
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
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
      ) VALUES (
        v_from_movement_number,
        p_from_customer_id,
        'outgoing',
        v_from_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        NULL,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name,
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      RETURN QUERY SELECT v_from_movement_id, NULL::uuid, true, 'تم التحويل بنجاح من ' || v_from_customer_name || ' إلى المحل'::text;
      RETURN;

    -- حالة 3: عميل → عميل (إنشاء حركتين مترابطتين)
    -- المنطق الصحيح: المُحوِّل outgoing (ينقص رصيده)، المُحوَّل إليه incoming (يزيد رصيده)
    ELSIF v_transfer_direction = 'customer_to_customer' THEN
      v_from_movement_number := generate_movement_number();
      v_to_movement_number := generate_movement_number();

      -- حركة العميل المُحوِّل (outgoing = ينقص رصيده) ✅
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
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
      ) VALUES (
        v_from_movement_number,
        p_from_customer_id,
        'outgoing',
        v_from_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        p_to_customer_id,
        v_transfer_direction,
        v_from_customer_name,
        v_to_customer_name,
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      -- حركة العميل المُحوَّل إليه (incoming = يزيد رصيده) ✅
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
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
      ) VALUES (
        v_to_movement_number,
        p_to_customer_id,
        'incoming',
        v_to_amount,
        p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id,
        p_to_customer_id,
        v_transfer_direction,
        v_from_movement_id,
        v_from_customer_name,
        v_to_customer_name,
        p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
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

COMMENT ON COLUMN account_movements.commission_recipient_id IS 'معرف العميل الذي يستلم العمولة (NULL = الأرباح والخسائر)';
COMMENT ON FUNCTION create_internal_transfer IS 'دالة لإنشاء تحويل داخلي مع إمكانية تحديد مستلم العمولة (مع إصلاح المنطق المحاسبي)';
COMMENT ON FUNCTION record_commission_to_profit_loss IS 'دالة تلقائية لتسجيل العمولات في حساب الأرباح والخسائر (فقط عند commission_recipient_id = NULL)';