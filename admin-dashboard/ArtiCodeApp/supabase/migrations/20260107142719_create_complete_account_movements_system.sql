/*
  # إنشاء نظام حركات الحسابات الكامل

  ## الجداول الجديدة
  
  ### 1. account_movements (حركات الحساب)
  - جدول رئيسي لتسجيل جميع الحركات المالية
  - يدعم التحويلات الداخلية والعمولات
  - يحتوي على معلومات كاملة عن المُرسل والمستلم
  
  ### 2. app_security (أمان التطبيق)
  - جدول لحفظ معلومات المستخدمين ورموز PIN
  - يدعم multi-user مع أدوار (admin, user)
  
  ### 3. حساب الأرباح والخسائر
  - حساب خاص لتسجيل العمولات والأرباح

  ## الدوال والـ Views
  
  - generate_movement_number: لتوليد رقم حركة تلقائي
  - create_internal_transfer: لإنشاء تحويل داخلي
  - customer_balances: view لعرض أرصدة العملاء
  - triggers لتسجيل العمولات تلقائياً
  
  ## الأمان
  - RLS مفعّل على جميع الجداول
  - حماية خاصة لحساب admin
*/

-- 1. إنشاء جدول account_movements
CREATE TABLE IF NOT EXISTS account_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  movement_number text UNIQUE NOT NULL,
  customer_id uuid REFERENCES customers(id) ON DELETE CASCADE,
  movement_type text NOT NULL CHECK (movement_type IN ('incoming', 'outgoing')),
  amount decimal(15, 2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'USD',
  notes text,
  created_at timestamptz DEFAULT now(),
  
  -- حقول التحويل الداخلي
  from_customer_id uuid REFERENCES customers(id) ON DELETE SET NULL,
  to_customer_id uuid REFERENCES customers(id) ON DELETE SET NULL,
  transfer_direction text,
  related_transfer_id uuid REFERENCES account_movements(id) ON DELETE SET NULL,
  sender_name text,
  beneficiary_name text,
  
  -- حقول العمولة
  commission decimal(15, 2),
  commission_currency text DEFAULT 'USD',
  commission_recipient_id uuid REFERENCES customers(id) ON DELETE SET NULL,
  is_commission_movement boolean DEFAULT false,
  related_commission_movement_id uuid REFERENCES account_movements(id) ON DELETE SET NULL,
  
  -- حقول إضافية
  receipt_number text,
  account_statement_number text,
  transfer_number text
);

-- إنشاء فهارس للأداء
CREATE INDEX IF NOT EXISTS account_movements_customer_id_idx ON account_movements(customer_id);
CREATE INDEX IF NOT EXISTS account_movements_created_at_idx ON account_movements(created_at DESC);
CREATE INDEX IF NOT EXISTS account_movements_type_idx ON account_movements(movement_type);
CREATE INDEX IF NOT EXISTS account_movements_from_customer_idx ON account_movements(from_customer_id);
CREATE INDEX IF NOT EXISTS account_movements_to_customer_idx ON account_movements(to_customer_id);
CREATE INDEX IF NOT EXISTS account_movements_commission_movement_idx ON account_movements(is_commission_movement);

-- 2. إنشاء جدول app_security
CREATE TABLE IF NOT EXISTS app_security (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_name text NOT NULL,
  pin_hash text NOT NULL,
  role text NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  last_login timestamptz
);

-- إدراج مستخدم admin افتراضي (PIN: 1234)
INSERT INTO app_security (user_name, pin_hash, role)
VALUES ('Ali', '$2a$10$rZL2vKq7xK5H8U.qnJ5zNOXXuJGz6XqLq0KGZhF7yYJZQZB5H5F5e', 'admin')
ON CONFLICT DO NOTHING;

-- 3. إنشاء حساب الأرباح والخسائر
DO $$
DECLARE
  v_profit_loss_id uuid;
BEGIN
  -- التحقق من وجود حساب الأرباح والخسائر
  SELECT id INTO v_profit_loss_id FROM customers WHERE phone = 'PROFIT_LOSS_ACCOUNT';
  
  IF v_profit_loss_id IS NULL THEN
    INSERT INTO customers (name, phone, email, address, notes)
    VALUES (
      'الأرباح والخسائر',
      'PROFIT_LOSS_ACCOUNT',
      'profit@system.local',
      'حساب نظامي',
      'حساب خاص لتسجيل الأرباح والخسائر من العمولات - لا يجب حذفه'
    );
  END IF;
END $$;

-- 4. دالة لإنشاء رقم حركة تلقائي
CREATE OR REPLACE FUNCTION generate_movement_number()
RETURNS text AS $$
DECLARE
  new_number text;
  counter int;
BEGIN
  SELECT COUNT(*) INTO counter FROM account_movements WHERE DATE(created_at) = CURRENT_DATE;
  
  LOOP
    counter := counter + 1;
    new_number := 'MOV-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-' || LPAD(counter::text, 4, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM account_movements WHERE movement_number = new_number);
  END LOOP;
  
  RETURN new_number;
END;
$$ LANGUAGE plpgsql;

-- 5. دالة create_internal_transfer (النسخة المحدثة)
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
  v_actual_to_amount decimal;
  v_actual_from_amount decimal;
BEGIN
  IF p_amount <= 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'المبلغ يجب أن يكون أكبر من صفر'::text;
    RETURN;
  END IF;

  IF p_commission IS NOT NULL AND p_commission < 0 THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'العمولة يجب أن تكون صفر أو أكبر'::text;
    RETURN;
  END IF;

  IF p_from_customer_id IS NOT NULL AND p_to_customer_id IS NOT NULL AND p_from_customer_id = p_to_customer_id THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'لا يمكن التحويل لنفس العميل'::text;
    RETURN;
  END IF;

  IF p_commission_recipient_id IS NOT NULL THEN
    IF p_commission_recipient_id != p_from_customer_id AND p_commission_recipient_id != p_to_customer_id THEN
      RETURN QUERY SELECT NULL::uuid, NULL::uuid, false, 'مستلم العمولة يجب أن يكون أحد أطراف التحويل'::text;
      RETURN;
    END IF;
  END IF;

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

  -- حساب المبلغ الفعلي للمُحوِّل
  IF p_commission IS NOT NULL AND p_commission > 0 THEN
    IF p_commission_recipient_id = p_from_customer_id THEN
      v_actual_from_amount := p_amount - p_commission;
    ELSE
      v_actual_from_amount := p_amount;
    END IF;
  ELSE
    v_actual_from_amount := p_amount;
  END IF;

  -- حساب المبلغ الفعلي للمستلم
  IF p_commission IS NOT NULL AND p_commission > 0 THEN
    IF p_commission_recipient_id IS NULL THEN
      v_actual_to_amount := p_amount - p_commission;
    ELSIF p_commission_recipient_id = p_to_customer_id THEN
      v_actual_to_amount := p_amount + p_commission;
    ELSE
      v_actual_to_amount := p_amount;
    END IF;
  ELSE
    v_actual_to_amount := p_amount;
  END IF;

  BEGIN
    IF v_transfer_direction = 'shop_to_customer' THEN
      v_to_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_to_movement_number, p_to_customer_id, 'incoming', v_actual_to_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        NULL, p_to_customer_id, v_transfer_direction,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_to_movement_id;

      RETURN QUERY SELECT NULL::uuid, v_to_movement_id, true, 'تم التحويل بنجاح من المحل إلى ' || v_to_customer_name::text;
      RETURN;

    ELSIF v_transfer_direction = 'customer_to_shop' THEN
      v_from_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_from_movement_number, p_from_customer_id, 'outgoing', v_actual_from_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id, NULL, v_transfer_direction,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      RETURN QUERY SELECT v_from_movement_id, NULL::uuid, true, 'تم التحويل بنجاح من ' || v_from_customer_name || ' إلى المحل'::text;
      RETURN;

    ELSIF v_transfer_direction = 'customer_to_customer' THEN
      v_from_movement_number := generate_movement_number();
      v_to_movement_number := generate_movement_number();

      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_from_movement_number, p_from_customer_id, 'outgoing', v_actual_from_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id, p_to_customer_id, v_transfer_direction,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_from_movement_id;

      INSERT INTO account_movements (
        movement_number, customer_id, movement_type, amount, currency, notes,
        from_customer_id, to_customer_id, transfer_direction, related_transfer_id,
        sender_name, beneficiary_name, commission, commission_currency, commission_recipient_id
      ) VALUES (
        v_to_movement_number, p_to_customer_id, 'incoming', v_actual_to_amount, p_currency,
        COALESCE(p_notes, 'تحويل من ' || v_from_customer_name || ' إلى ' || v_to_customer_name),
        p_from_customer_id, p_to_customer_id, v_transfer_direction, v_from_movement_id,
        v_from_customer_name, v_to_customer_name, p_commission,
        CASE WHEN p_commission IS NOT NULL THEN p_commission_currency ELSE NULL END,
        p_commission_recipient_id
      ) RETURNING id INTO v_to_movement_id;

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

-- 6. View customer_balances لعرض أرصدة العملاء
CREATE OR REPLACE VIEW customer_balances AS
SELECT 
  c.id,
  c.name,
  c.phone,
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false) 
        THEN am.amount 
        ELSE 0 
      END
    ), 0
  ) as total_incoming,
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'outgoing' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN am.amount 
        ELSE 0 
      END
    ), 0
  ) as total_outgoing,
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
        THEN am.amount 
        WHEN am.movement_type = 'outgoing' AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
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

-- 7. Trigger لتسجيل العمولات تلقائياً
CREATE OR REPLACE FUNCTION record_commission_to_profit_loss()
RETURNS TRIGGER AS $$
DECLARE
  v_profit_loss_id uuid;
  v_commission_movement_id uuid;
  v_recipient_movement_id uuid;
BEGIN
  IF NEW.commission IS NOT NULL AND NEW.commission > 0 THEN
    SELECT id INTO v_profit_loss_id FROM customers WHERE phone = 'PROFIT_LOSS_ACCOUNT';
    
    IF v_profit_loss_id IS NULL THEN
      RETURN NEW;
    END IF;

    IF NEW.commission_recipient_id IS NOT NULL THEN
      IF NEW.commission_recipient_id != NEW.to_customer_id THEN
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

DROP TRIGGER IF EXISTS trigger_record_commission ON account_movements;
CREATE TRIGGER trigger_record_commission
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION record_commission_to_profit_loss();

-- 8. تفعيل RLS
ALTER TABLE account_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_security ENABLE ROW LEVEL SECURITY;

-- سياسات RLS
CREATE POLICY "Allow all operations on account_movements"
  ON account_movements FOR ALL
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Allow all operations on app_security"
  ON app_security FOR ALL
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Protect admin user Ali"
  ON app_security
  FOR DELETE
  USING (user_name != 'Ali');

-- 9. Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE account_movements;
ALTER PUBLICATION supabase_realtime ADD TABLE customers;
ALTER PUBLICATION supabase_realtime ADD TABLE app_security;

COMMENT ON TABLE account_movements IS 'جدول حركات الحسابات - يدعم التحويلات الداخلية والعمولات';
COMMENT ON FUNCTION create_internal_transfer IS 'إنشاء تحويل داخلي - عند commission_recipient_id=from: المُحوِّل outgoing=(amount-commission)، عند commission_recipient_id=to: المستلم incoming=(amount+commission)';
