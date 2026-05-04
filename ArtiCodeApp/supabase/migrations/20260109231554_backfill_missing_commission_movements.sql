/*
  # تسجيل العمولات المفقودة للحركات القديمة
  
  ## المشكلة
  الحركات القديمة التي تم إنشاؤها قبل إصلاح الـ trigger لم يتم تسجيل عمولاتها بشكل كامل.
  
  ## الحل
  1. البحث عن جميع الحركات التي لها عمولات ولكن لم يتم تسجيلها للمستلم
  2. تسجيل حركات العمولة المفقودة
*/

DO $$
DECLARE
  movement_record RECORD;
  profit_loss_account_id UUID;
  commission_movement_number TEXT;
  commission_notes TEXT;
BEGIN
  -- الحصول على حساب الأرباح والخسائر
  SELECT id INTO profit_loss_account_id
  FROM customers
  WHERE is_profit_loss_account = true
  LIMIT 1;

  IF profit_loss_account_id IS NULL THEN
    RAISE NOTICE 'لم يتم العثور على حساب الأرباح والخسائر';
    RETURN;
  END IF;

  -- البحث عن جميع الحركات التي لها عمولات للمرسل أو المستلم ولكن لم يتم تسجيل حركة استلام للعميل
  FOR movement_record IN
    SELECT 
      am.id,
      am.movement_number,
      am.commission,
      am.commission_currency,
      am.commission_recipient_id,
      am.sender_name,
      am.beneficiary_name,
      am.from_customer_id,
      am.to_customer_id
    FROM account_movements am
    WHERE am.commission IS NOT NULL 
      AND am.commission > 0
      AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
      AND am.commission_recipient_id != profit_loss_account_id
      AND NOT EXISTS (
        SELECT 1 FROM account_movements cm
        WHERE cm.is_commission_movement = true 
          AND cm.related_commission_movement_id = am.id
          AND cm.customer_id = am.commission_recipient_id
      )
  LOOP
    -- توليد رقم حركة للعمولة
    commission_movement_number := 'COM-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 8);

    -- تحديد اسم المستلم
    DECLARE
      recipient_name TEXT;
    BEGIN
      IF movement_record.commission_recipient_id = movement_record.from_customer_id THEN
        recipient_name := COALESCE(movement_record.sender_name, 'المرسل');
      ELSE
        recipient_name := COALESCE(movement_record.beneficiary_name, 'المستلم');
      END IF;

      commission_notes := format(
        'عمولة لـ %s من تحويل %s → %s بمبلغ %s %s',
        recipient_name,
        COALESCE(movement_record.sender_name, 'غير محدد'),
        COALESCE(movement_record.beneficiary_name, 'غير محدد'),
        movement_record.commission,
        movement_record.commission_currency
      );

      -- تسجيل حركة دفع من الأرباح (إذا لم تكن موجودة)
      IF NOT EXISTS (
        SELECT 1 FROM account_movements
        WHERE is_commission_movement = true
          AND related_commission_movement_id = movement_record.id
          AND customer_id = profit_loss_account_id
      ) THEN
        INSERT INTO account_movements (
          movement_number,
          customer_id,
          movement_type,
          amount,
          currency,
          notes,
          is_commission_movement,
          related_commission_movement_id,
          commission,
          commission_currency
        ) VALUES (
          commission_movement_number,
          profit_loss_account_id,
          'outgoing',
          movement_record.commission,
          movement_record.commission_currency,
          commission_notes,
          true,
          movement_record.id,
          0,
          movement_record.commission_currency
        );
        
        RAISE NOTICE 'تم تسجيل حركة دفع من الأرباح للحركة: %', movement_record.movement_number;
      END IF;

      -- تسجيل حركة استلام للعميل
      commission_movement_number := 'COM-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 8);
      
      INSERT INTO account_movements (
        movement_number,
        customer_id,
        movement_type,
        amount,
        currency,
        notes,
        is_commission_movement,
        related_commission_movement_id,
        commission,
        commission_currency
      ) VALUES (
        commission_movement_number,
        movement_record.commission_recipient_id,
        'incoming',
        movement_record.commission,
        movement_record.commission_currency,
        commission_notes,
        true,
        movement_record.id,
        0,
        movement_record.commission_currency
      );

      RAISE NOTICE 'تم تسجيل حركة استلام للعميل: % للحركة: %', recipient_name, movement_record.movement_number;
    END;
  END LOOP;

  RAISE NOTICE 'تم الانتهاء من تسجيل العمولات المفقودة';
END $$;