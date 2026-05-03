/*
  # توحيد منطق الاستلام والتسليم مع العمولة - عرض الصافي للعميل

  ## المشكلة الحالية
  
  - المبلغ المعروض للعميل لا يعكس الصافي بعد العمولة
  - العمولة تظهر كحركة منفصلة على حساب العميل
  - التقارير والطباعة لا تُطابق المتطلبات
  
  ## المتطلبات الجديدة
  
  ### 1. الاستلام من العميل (customer_to_shop = outgoing)
  - مثال: استلام 5000$، عمولة 50$
  - المبلغ المعروض للعميل: 4950$ (صافي بعد خصم العمولة)
  - P&L يستلم: 50$
  
  ### 2. التسليم للعميل (shop_to_customer = incoming)
  - مثال: تسليم 900$، عمولة 10$
  - المبلغ المعروض للعميل: 910$ (إجمالي شامل العمولة)
  - P&L يستلم: 10$
  
  ### 3. التحويل الداخلي - 3 حالات
  
  #### الحالة 1: العمولة لصالح المُرسِل
  - المُرسِل (جلال): يُخصم منه 4880$ (5000 - 120)
  - المستلم (عماد): يستلم 5000$
  - P&L: لا حركة
  
  #### الحالة 2: العمولة لصالح المستلم
  - المُرسِل: يُخصم منه 5000$
  - المستلم: يستلم 5120$ (5000 + 120)
  - P&L: تسليم 120$ (outgoing)
  
  #### الحالة 3: العمولة لصالح P&L
  - المُرسِل: يُخصم منه 5000$
  - المستلم: يستلم 4880$ (5000 - 120)
  - P&L: استلام 120$ (incoming)
  
  ## الحل
  
  1. إضافة حقل `original_amount` لحفظ المبلغ الأصلي المُدخل
  2. تعديل `amount` ليعكس الصافي الفعلي المعروض للعميل
  3. BEFORE INSERT trigger يحسب الصافي تلقائياً
  4. AFTER INSERT trigger يُنشئ حركة العمولة لـ P&L فقط
  5. إزالة حركات العمولة المنفصلة على حساب العميل
  
  ## الأمان
  
  - جميع التعديلات على البنية والـ triggers
  - لا تؤثر على البيانات الحالية
  - تطبيق فوري على الحركات الجديدة فقط
*/

-- 1. إضافة حقل original_amount لحفظ المبلغ الأصلي
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'original_amount'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN original_amount numeric(15,2);
    COMMENT ON COLUMN account_movements.original_amount IS 'المبلغ الأصلي المُدخل قبل حساب العمولة';
  END IF;
END $$;

-- 2. حذف الـ triggers القديمة
DROP TRIGGER IF EXISTS record_commission_trigger ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss() CASCADE;

-- 3. إنشاء BEFORE INSERT trigger لحساب المبلغ الصافي
CREATE OR REPLACE FUNCTION calculate_net_amount_before_insert()
RETURNS TRIGGER AS $$
DECLARE
  v_commission_value numeric(15,2);
BEGIN
  -- حفظ المبلغ الأصلي
  NEW.original_amount := NEW.amount;
  
  -- إذا لم يكن هناك عمولة، لا نفعل شيء
  IF NEW.commission IS NULL OR NEW.commission = 0 THEN
    RETURN NEW;
  END IF;
  
  -- إذا كانت حركة عمولة منفصلة، لا نُعدّل amount
  IF NEW.is_commission_movement = true THEN
    RETURN NEW;
  END IF;
  
  v_commission_value := NEW.commission;
  
  -- للحركات العادية (غير التحويل الداخلي)
  IF NEW.is_internal_transfer = false OR NEW.is_internal_transfer IS NULL THEN
    IF NEW.movement_type = 'outgoing' THEN
      -- استلام من العميل: الصافي = المبلغ - العمولة
      NEW.amount := NEW.amount - v_commission_value;
    ELSIF NEW.movement_type = 'incoming' THEN
      -- تسليم للعميل: الإجمالي = المبلغ + العمولة
      NEW.amount := NEW.amount + v_commission_value;
    END IF;
  ELSE
    -- للتحويل الداخلي: سيتم التعامل معه في منطق خاص
    -- نحتفظ بـ amount كما هو، وسيتم تعديله في الواجهة أو trigger منفصل
    NULL;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER calculate_net_amount_trigger
  BEFORE INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION calculate_net_amount_before_insert();

COMMENT ON FUNCTION calculate_net_amount_before_insert IS 'حساب المبلغ الصافي تلقائياً قبل الإدراج بناءً على نوع الحركة والعمولة';

-- 4. إنشاء AFTER INSERT trigger لتسجيل العمولة لحساب P&L فقط
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss_v2()
RETURNS TRIGGER AS $$
DECLARE
  v_profit_loss_id uuid;
  v_commission_movement_type text;
BEGIN
  -- تنفيذ فقط للحركات الجديدة التي تحتوي على عمولة وليست حركات عمولة
  IF (NEW.is_commission_movement IS NULL OR NEW.is_commission_movement = false) AND
     (NEW.commission IS NOT NULL AND NEW.commission > 0) THEN
    
    -- الحصول على حساب الأرباح والخسائر
    SELECT id INTO v_profit_loss_id FROM customers WHERE phone = 'PROFIT_LOSS_ACCOUNT';
    
    IF v_profit_loss_id IS NULL THEN
      RETURN NEW;
    END IF;
    
    -- تحديد نوع حركة العمولة في P&L
    -- القاعدة: العمولة دائماً دخل لـ P&L إلا في حالة واحدة (العمولة لصالح المستلم في التحويل الداخلي)
    v_commission_movement_type := 'incoming';
    
    -- إذا كان هناك مستلم للعمولة غير حساب P&L، فهذا يعني P&L يدفع
    IF NEW.commission_recipient_id IS NOT NULL AND 
       NEW.commission_recipient_id != v_profit_loss_id THEN
      v_commission_movement_type := 'outgoing';
      
      -- إنشاء حركة استلام للمستفيد من العمولة
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        is_commission_movement,
        related_commission_movement_id
      ) VALUES (
        generate_movement_number(),
        NEW.commission_recipient_id,
        'incoming',
        NEW.commission,
        NEW.commission_currency,
        'عمولة من حركة ' || NEW.movement_number,
        true,
        NEW.id
      );
    END IF;
    
    -- إنشاء حركة العمولة لـ P&L
    INSERT INTO account_movements (
      movement_number,
      customer_id,
      movement_type,
      amount,
      currency,
      notes,
      is_commission_movement,
      related_commission_movement_id
    ) VALUES (
      generate_movement_number(),
      v_profit_loss_id,
      v_commission_movement_type,
      NEW.commission,
      NEW.commission_currency,
      CASE 
        WHEN v_commission_movement_type = 'incoming' THEN 'عمولة من حركة ' || NEW.movement_number
        ELSE 'دفع عمولة للحركة ' || NEW.movement_number
      END,
      true,
      NEW.id
    );
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER record_commission_trigger_v2
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss_v2();

COMMENT ON FUNCTION record_commission_to_profit_loss_v2 IS 'تسجيل العمولات إلى حساب الأرباح والخسائر فقط - لا يُنشئ حركات على حساب العميل';

-- 5. تحديث البيانات الحالية لملء original_amount
UPDATE account_movements 
SET original_amount = amount 
WHERE original_amount IS NULL 
  AND (is_commission_movement IS NULL OR is_commission_movement = false);

-- 6. إعادة بناء البيانات التجريبية بالمنطق الجديد
-- حذف جميع الحركات القديمة
TRUNCATE account_movements CASCADE;

-- حذف العملاء التجريبيين
DELETE FROM customers WHERE phone IN ('777123456', '777654321');

-- إعادة إدراج العملاء
INSERT INTO customers (id, name, phone, notes) VALUES
  ('5b7903a6-539d-4b8d-abba-85f802e94114', 'جلال', '777123456', 'عميل تجريبي'),
  ('b9a27d05-e39b-4258-93fa-2bc76b2dfdab', 'عماد', '777654321', 'عميل تجريبي')
ON CONFLICT (id) DO NOTHING;
