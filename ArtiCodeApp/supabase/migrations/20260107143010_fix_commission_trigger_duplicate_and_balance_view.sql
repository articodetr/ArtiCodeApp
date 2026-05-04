/*
  # إصلاح مشكلتين في نظام العمولات
  
  ## المشاكل
  
  1. **Trigger ينشئ حركات مكررة**:
     - عند التحويل الداخلي، ينفذ الـ trigger مرتين (مرة لكل حركة)
     - ينتج عنه حركات عمولة مكررة
  
  2. **View يستبعد حركات العمولة من الرصيد**:
     - customer_balances يستبعد `is_commission_movement = true`
     - يجب تضمين حركات العمولة لحساب الرصيد الصحيح
  
  ## الحلول
  
  1. تعديل الـ trigger للعمل فقط مع الحركة الأولى (from_movement)
  2. تحديث الـ view لتضمين جميع الحركات في حساب الرصيد
*/

-- 1. حذف البيانات الاختبارية المكررة
TRUNCATE account_movements CASCADE;

-- 2. إعادة إدراج العملاء
DELETE FROM customers WHERE phone IN ('777123456', '777654321');

-- 3. تحديث trigger لمنع التكرار
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss()
RETURNS TRIGGER AS $$
DECLARE
  v_profit_loss_id uuid;
  v_commission_movement_id uuid;
  v_recipient_movement_id uuid;
BEGIN
  -- تنفيذ فقط إذا كانت هذه حركة جديدة وليست حركة عمولة
  -- وتحتوي على عمولة وليس لها related_transfer_id (أي أنها الحركة الأولى)
  IF (TG_OP = 'INSERT') AND 
     (NEW.is_commission_movement IS NULL OR NEW.is_commission_movement = false) AND
     (NEW.commission IS NOT NULL AND NEW.commission > 0) AND
     (NEW.related_transfer_id IS NULL) THEN
    
    SELECT id INTO v_profit_loss_id FROM customers WHERE phone = 'PROFIT_LOSS_ACCOUNT';
    
    IF v_profit_loss_id IS NULL THEN
      RETURN NEW;
    END IF;

    -- إذا كان هناك مستلم للعمولة غير المستلم الرئيسي
    IF NEW.commission_recipient_id IS NOT NULL THEN
      IF NEW.commission_recipient_id != NEW.to_customer_id THEN
        -- إنشاء حركة incoming للعميل مستلم العمولة
        INSERT INTO account_movements (
          movement_number, customer_id, movement_type, amount, currency, notes,
          is_commission_movement, related_commission_movement_id
        ) VALUES (
          generate_movement_number(),
          NEW.commission_recipient_id,
          'incoming',
          NEW.commission,
          NEW.commission_currency,
          'عمولة من حركة ' || NEW.movement_number,
          true,
          NEW.id
        ) RETURNING id INTO v_recipient_movement_id;
      END IF;

      -- إنشاء حركة outgoing من الأرباح والخسائر
      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        is_commission_movement, related_commission_movement_id
      ) VALUES (
        generate_movement_number(),
        v_profit_loss_id,
        'outgoing',
        NEW.commission,
        NEW.commission_currency,
        'دفع عمولة للحركة ' || NEW.movement_number,
        true,
        NEW.id
      ) RETURNING id INTO v_commission_movement_id;
    ELSE
      -- لا يوجد مستلم محدد = الأرباح تستلم
      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        is_commission_movement, related_commission_movement_id
      ) VALUES (
        generate_movement_number(),
        v_profit_loss_id,
        'incoming',
        NEW.commission,
        NEW.commission_currency,
        'عمولة من حركة ' || NEW.movement_number,
        true,
        NEW.id
      ) RETURNING id INTO v_commission_movement_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 4. تحديث view customer_balances لتضمين جميع الحركات
CREATE OR REPLACE VIEW customer_balances AS
SELECT 
  c.id,
  c.name,
  c.phone,
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' 
        THEN am.amount 
        ELSE 0 
      END
    ), 0
  ) as total_incoming,
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'outgoing'
        THEN am.amount 
        ELSE 0 
      END
    ), 0
  ) as total_outgoing,
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming'
        THEN am.amount 
        WHEN am.movement_type = 'outgoing'
        THEN -am.amount 
        ELSE 0 
      END
    ), 0
  ) as balance,
  am.currency,
  MAX(am.created_at) as last_activity
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
WHERE c.phone != 'PROFIT_LOSS_ACCOUNT'
  OR c.phone IS NULL
GROUP BY c.id, c.name, c.phone, am.currency;

COMMENT ON VIEW customer_balances IS 'عرض أرصدة العملاء - يتضمن جميع الحركات بما في ذلك حركات العمولة';
COMMENT ON FUNCTION record_commission_to_profit_loss IS 'تسجيل العمولات تلقائياً - ينفذ مرة واحدة فقط للحركة الأولى';
