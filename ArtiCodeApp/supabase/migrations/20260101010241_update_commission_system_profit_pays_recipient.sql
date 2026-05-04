/*
  # تحديث نظام العمولة - الأرباح تدفع للمستلم المختار
  
  ## المشكلة السابقة
  عندما يتم اختيار مستلم العمولة:
    - المُحوِّل: كانت العمولة تُطرح من مبلغه
    - المُحوَّل إليه: كانت العمولة تُضاف لمبلغه
    
  ## الحل الجديد
  عندما يتم اختيار مستلم العمولة:
    - الأرباح: تدفع العمولة (outgoing)
    - المستلم المختار: يحصل على العمولة (incoming)
    - المبالغ الأساسية لا تتغير
    
  عندما لا يتم اختيار أحد (NULL):
    - الأرباح: تستلم العمولة (incoming) - كما هو حالياً
  
  ## التغييرات
  
  ### 1. تعديل دالة create_internal_transfer
    - حذف المنطق الذي يطرح/يضيف العمولة من/إلى المبالغ
    - المبالغ تبقى أساسية في جميع الحالات
    - فقط حفظ commission_recipient_id كما هو
  
  ### 2. تعديل trigger العمولة
    - عند commission_recipient_id IS NULL:
      * إنشاء حركة incoming للأرباح (السلوك الحالي)
    - عند commission_recipient_id IS NOT NULL:
      * إنشاء حركة outgoing من الأرباح
      * إنشاء حركة incoming للمستلم المختار
  
  ## أمثلة النتائج
  
  ### مثال: جلال يحول 5000$ لعماد بعمولة 50$
  
  **1. اختيار "جلال" (المُحوِّل):**
    - جلال: outgoing بمبلغ 5000$
    - عماد: incoming بمبلغ 5000$
    - الأرباح: outgoing بمبلغ 50$ (تدفع)
    - جلال: incoming بمبلغ 50$ (يحصل)
    النتيجة: جلال دفع 4950$ صافي، عماد حصل 5000$، الأرباح دفعت 50$
  
  **2. اختيار "عماد" (المُحوَّل إليه):**
    - جلال: outgoing بمبلغ 5000$
    - عماد: incoming بمبلغ 5000$
    - الأرباح: outgoing بمبلغ 50$ (تدفع)
    - عماد: incoming بمبلغ 50$ (يحصل)
    النتيجة: جلال دفع 5000$، عماد حصل 5050$ صافي، الأرباح دفعت 50$
  
  **3. الافتراضي (لم يختر أحد):**
    - جلال: outgoing بمبلغ 5000$
    - عماد: incoming بمبلغ 5000$
    - الأرباح: incoming بمبلغ 50$ (تستلم)
    النتيجة: جلال دفع 5000$، عماد حصل 5000$، الأرباح حصلت 50$
*/

-- 1. حذف الـ trigger والدالة القديمة
DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss();

-- 2. إنشاء دالة trigger جديدة محدّثة
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  profit_loss_id uuid;
  next_movement_num_profit text;
  next_movement_num_recipient text;
BEGIN
  -- التحقق من وجود عمولة
  IF NEW.commission IS NULL OR NEW.commission = 0 THEN
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

  -- الحالة 1: لم يتم اختيار مستلم (NULL) - الأرباح تستلم العمولة
  IF NEW.commission_recipient_id IS NULL THEN
    -- الحصول على رقم الحركة التالي
    SELECT generate_movement_number() INTO next_movement_num_profit;

    -- إنشاء حركة incoming للأرباح والخسائر
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
      next_movement_num_profit,
      'عمولة من حركة رقم ' || NEW.movement_number,
      NEW.created_at
    );

  -- الحالة 2: تم اختيار مستلم - الأرباح تدفع العمولة للمستلم
  ELSE
    -- الحصول على أرقام الحركات
    SELECT generate_movement_number() INTO next_movement_num_profit;
    SELECT generate_movement_number() INTO next_movement_num_recipient;

    -- إنشاء حركة outgoing من الأرباح والخسائر (تدفع العمولة)
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
      'outgoing',
      next_movement_num_profit,
      'دفع عمولة لحركة رقم ' || NEW.movement_number,
      NEW.created_at
    );

    -- إنشاء حركة incoming للمستلم المختار (يحصل على العمولة)
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
      NEW.commission_recipient_id,
      NEW.commission,
      0,
      NEW.commission_currency,
      NEW.commission_currency,
      'incoming',
      next_movement_num_recipient,
      'عمولة من حركة رقم ' || NEW.movement_number,
      NEW.created_at
    );
  END IF;

  RETURN NEW;
END;
$$;

-- 3. إنشاء trigger جديد
CREATE TRIGGER trigger_record_commission
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss();

-- 4. حذف النسخ القديمة من دالة create_internal_transfer
DROP FUNCTION IF EXISTS create_internal_transfer(uuid, uuid, decimal, text, text, decimal, text, uuid);

-- 5. إنشاء دالة create_internal_transfer محدّثة (بدون منطق طرح/إضافة العمولة)
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
        beneficiary_name,
        commission,
        commission_currency,
        commission_recipient_id
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
        p_amount,
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
    ELSIF v_transfer_direction = 'customer_to_customer' THEN
      v_from_movement_number := generate_movement_number();
      v_to_movement_number := generate_movement_number();

      -- حركة العميل المُحوِّل (outgoing)
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
        p_amount,
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

      -- حركة العميل المُحوَّل إليه (incoming)
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
        p_amount,
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

COMMENT ON FUNCTION record_commission_to_profit_loss IS 'دالة تلقائية لتسجيل العمولات: إذا لم يُحدد مستلم، الأرباح تستلم. إذا حُدد مستلم، الأرباح تدفع له';
COMMENT ON FUNCTION create_internal_transfer IS 'دالة لإنشاء تحويل داخلي - المبالغ أساسية دائماً، والعمولة تُسجّل عبر الـ trigger';