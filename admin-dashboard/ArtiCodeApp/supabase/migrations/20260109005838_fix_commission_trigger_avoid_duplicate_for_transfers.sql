/*
  # إصلاح تكرار حركات العمولة في التحويل الداخلي
  
  ## المشكلة
  
  في التحويل الداخلي، يُنشأ حركتين (from و to)
  الـ trigger ينفذ مرتين (مرة لكل حركة)
  ينتج عنه حركات عمولة مكررة على P&L
  
  ## الحل
  
  تنفيذ الـ trigger فقط للحركة الأولى (التي ليس لها related_transfer_id)
  أو للحركات العادية (التي ليست تحويل داخلي)
*/

-- حذف الـ trigger القديم
DROP TRIGGER IF EXISTS record_commission_trigger_v3 ON account_movements;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss_v3() CASCADE;

-- إنشاء AFTER INSERT trigger محدّث
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss_v4()
RETURNS TRIGGER AS $$
DECLARE
  v_profit_loss_id uuid;
  v_is_internal_transfer boolean;
BEGIN
  -- تنفيذ فقط للحركات الجديدة التي تحتوي على عمولة وليست حركات عمولة
  IF (NEW.is_commission_movement IS NULL OR NEW.is_commission_movement = false) AND
     (NEW.commission IS NOT NULL AND NEW.commission > 0) THEN
    
    -- للتحويل الداخلي: تنفيذ فقط للحركة الأولى (التي ليس لها related_transfer_id)
    IF NEW.related_transfer_id IS NOT NULL THEN
      RETURN NEW;
    END IF;
    
    -- الحصول على حساب الأرباح والخسائر
    SELECT id INTO v_profit_loss_id FROM customers WHERE phone = 'PROFIT_LOSS_ACCOUNT';
    
    IF v_profit_loss_id IS NULL THEN
      RETURN NEW;
    END IF;
    
    -- التحقق من كونها تحويل داخلي
    v_is_internal_transfer := (NEW.from_customer_id IS NOT NULL OR NEW.to_customer_id IS NOT NULL);
    
    -- الحالة 1: العمولة لصالح المُرسِل في تحويل داخلي
    IF v_is_internal_transfer AND NEW.commission_recipient_id IS NOT NULL AND 
       NEW.commission_recipient_id = NEW.from_customer_id THEN
      -- لا نفعل شيء - العمولة محسوبة في المبلغ الصافي للمُرسِل
      RETURN NEW;
    END IF;
    
    -- الحالة 2: العمولة لصالح المستلم
    IF NEW.commission_recipient_id IS NOT NULL AND 
       NEW.commission_recipient_id != v_profit_loss_id THEN
      
      -- في التحويل الداخلي، إذا كانت العمولة للمستلم
      IF v_is_internal_transfer AND NEW.commission_recipient_id = NEW.to_customer_id THEN
        -- P&L يدفع العمولة
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
          'outgoing',
          NEW.commission,
          NEW.commission_currency,
          'دفع عمولة للحركة ' || NEW.movement_number,
          true,
          NEW.id
        );
        
        RETURN NEW;
      END IF;
      
      -- للحركات العادية (غير التحويل الداخلي)
      IF NOT v_is_internal_transfer THEN
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
        
        -- P&L يدفع
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
          'outgoing',
          NEW.commission,
          NEW.commission_currency,
          'دفع عمولة للحركة ' || NEW.movement_number,
          true,
          NEW.id
        );
      END IF;
    ELSE
      -- الحالة 3: العمولة لصالح P&L (الافتراضي)
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
        'incoming',
        NEW.commission,
        NEW.commission_currency,
        'عمولة من حركة ' || NEW.movement_number,
        true,
        NEW.id
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER record_commission_trigger_v4
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss_v4();

COMMENT ON FUNCTION record_commission_to_profit_loss_v4 IS 'تسجيل العمولات - ينفذ مرة واحدة فقط للحركة الأولى في التحويل الداخلي';
