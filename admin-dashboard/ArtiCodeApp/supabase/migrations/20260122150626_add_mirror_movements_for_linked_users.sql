/*
  # إضافة نظام الحركات المرآة للمستخدمين المربوطين
  
  ## الهدف
  عندما يسجل مستخدم حركة مالية لعميل مرتبط بمستخدم آخر، يجب أن تظهر الحركة تلقائياً
  بشكل معاكس في حساب المستخدم المرتبط.
  
  ## المثال
  - المستخدم علي (26010) يسجل "له 100 دولار" لجلال (26009)
  - تُسجل حركة incoming لجلال في حساب علي ✓
  - تُسجل حركة outgoing لعلي في حساب جلال ✓ (جديد)
  
  ## التغييرات
  1. إضافة حقل `mirror_movement_id` لربط الحركات المرآة
  2. إضافة حقل `source_user_id` لتحديد مصدر الحركة الأصلي
  3. إنشاء trigger لإنشاء الحركات المرآة تلقائياً
  4. دالة لإنشاء سجل عميل متبادل إذا لم يكن موجوداً
*/

-- 1. إضافة حقول جديدة لجدول account_movements
DO $$
BEGIN
  -- إضافة mirror_movement_id لربط الحركات المرآة
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'mirror_movement_id'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN mirror_movement_id uuid;
  END IF;

  -- إضافة source_user_id لتحديد المستخدم الأصلي الذي أنشأ الحركة
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'account_movements' AND column_name = 'source_user_id'
  ) THEN
    ALTER TABLE account_movements ADD COLUMN source_user_id uuid REFERENCES app_security(id);
  END IF;
END $$;

-- 2. إضافة index للبحث السريع
CREATE INDEX IF NOT EXISTS idx_am_mirror_movement_id ON account_movements(mirror_movement_id);
CREATE INDEX IF NOT EXISTS idx_am_source_user_id ON account_movements(source_user_id);

-- 3. دالة للحصول على أو إنشاء سجل عميل متبادل
CREATE OR REPLACE FUNCTION get_or_create_reciprocal_customer(
  p_target_user_id uuid,
  p_source_user_id uuid
) RETURNS uuid AS $$
DECLARE
  v_customer_id uuid;
  v_source_user_name text;
  v_source_account_number text;
BEGIN
  -- البحث عن سجل عميل موجود للمستخدم الأصلي في حساب المستخدم المستهدف
  SELECT id INTO v_customer_id
  FROM customers
  WHERE user_id = p_target_user_id
    AND linked_user_id = p_source_user_id;
  
  -- إذا وُجد، إرجاع المعرف
  IF v_customer_id IS NOT NULL THEN
    RETURN v_customer_id;
  END IF;
  
  -- إذا لم يوجد، إنشاء سجل جديد
  SELECT full_name, account_number INTO v_source_user_name, v_source_account_number
  FROM app_security
  WHERE id = p_source_user_id;
  
  INSERT INTO customers (
    user_id,
    linked_user_id,
    name,
    phone,
    account_number,
    notes
  ) VALUES (
    p_target_user_id,
    p_source_user_id,
    v_source_user_name,
    'LINKED_USER_' || v_source_account_number,
    v_source_account_number,
    'تم إنشاؤه تلقائياً للحركات المتبادلة'
  ) RETURNING id INTO v_customer_id;
  
  RETURN v_customer_id;
END;
$$ LANGUAGE plpgsql;

-- 4. دالة لإنشاء حركة مرآة
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
    account_number,
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
    'حركة مرآة: ' || COALESCE(NEW.notes, ''),
    NEW.sender_name,
    NEW.beneficiary_name,
    NEW.transfer_number,
    NEW.receipt_number,
    NEW.account_number,
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

-- 5. إنشاء trigger لإنشاء الحركات المرآة تلقائياً
DROP TRIGGER IF EXISTS trigger_create_mirror_movement ON account_movements;
CREATE TRIGGER trigger_create_mirror_movement
  AFTER INSERT ON account_movements
  FOR EACH ROW
  EXECUTE FUNCTION create_mirror_movement();

-- 6. تحديث RLS policies لتضمين الحركات المرآة
-- المستخدمون يمكنهم رؤية الحركات المرآة الخاصة بهم
DROP POLICY IF EXISTS "Users can view own movements" ON account_movements;
CREATE POLICY "Users can view own movements"
  ON account_movements FOR SELECT
  TO authenticated
  USING (
    -- الحركة تخص عميل من عملاء المستخدم
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    )
    OR
    -- الحركة تخص المستخدم نفسه كعميل مرتبط
    customer_id IN (
      SELECT id FROM customers
      WHERE linked_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    )
    OR
    -- الحركة المرآة التي أنشأها المستخدم
    source_user_id = (SELECT id FROM app_security WHERE user_name = current_setting('app.current_user', true))
    OR
    -- المدير يرى الجميع
    EXISTS (
      SELECT 1 FROM app_security
      WHERE user_name = current_setting('app.current_user', true)
      AND role = 'admin'
    )
  );

-- 7. تحديث view لإظهار العلاقة بين الحركات المرآة
CREATE OR REPLACE VIEW account_movements_with_mirror_info AS
SELECT
  am.*,
  c.name as customer_name,
  c.account_number as customer_account,
  c.user_id as owner_user_id,
  c.linked_user_id,
  owner.full_name as owner_name,
  linked.full_name as linked_user_name,
  mirror.id as mirror_movement_exists,
  CASE
    WHEN am.mirror_movement_id IS NOT NULL THEN true
    ELSE false
  END as is_mirror_movement
FROM account_movements am
INNER JOIN customers c ON am.customer_id = c.id
LEFT JOIN app_security owner ON c.user_id = owner.id
LEFT JOIN app_security linked ON c.linked_user_id = linked.id
LEFT JOIN account_movements mirror ON am.mirror_movement_id = mirror.id;

-- Grant permissions
GRANT SELECT ON account_movements_with_mirror_info TO authenticated;
