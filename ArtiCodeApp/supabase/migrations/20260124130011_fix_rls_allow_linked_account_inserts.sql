/*
  # إصلاح RLS للسماح بإضافة حركات على الحسابات المرتبطة

  ## المشكلة
  - مستخدم Salem لا يستطيع إضافة حركات على customer Salem لأن هذا العميل مملوك من Taha
  - RLS policy الحالية تسمح فقط بإضافة حركات على العملاء المملوكين للمستخدم نفسه
  
  ## الحل
  تحديث INSERT policy لتسمح بإضافة حركات على:
  1. العملاء المملوكين للمستخدم (الوضع الطبيعي)
  2. العملاء المرتبطين (reciprocal customers) حيث linked_user_id = المستخدم الحالي
  
  ## مثال
  - مستخدم Salem يملك customer Taha (26018)
  - customer Salem (26017) مملوك من Taha و linked_user_id = Salem user
  - Salem يجب أن يستطيع إضافة حركات على كلا الحسابين
*/

-- حذف policy القديمة
DROP POLICY IF EXISTS "Users can insert own movements" ON account_movements;

-- إنشاء policy جديدة تدعم الحسابات المرتبطة
CREATE POLICY "Users can insert movements for own and linked customers"
  ON account_movements FOR INSERT
  TO authenticated
  WITH CHECK (
    -- الحركة على عميل مملوك للمستخدم الحالي
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (
        SELECT id FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
    OR
    -- OR الحركة على عميل مرتبط (reciprocal customer)
    -- حيث العميل له linked_user_id يساوي المستخدم الحالي
    customer_id IN (
      SELECT id FROM customers
      WHERE linked_user_id = (
        SELECT id FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
  );

COMMENT ON POLICY "Users can insert movements for own and linked customers" 
  ON account_movements 
  IS 'السماح بإضافة حركات على العملاء المملوكين أو المرتبطين (Splitwise reciprocal)';

-- تحديث UPDATE policy أيضاً
DROP POLICY IF EXISTS "Users can update own movements" ON account_movements;

CREATE POLICY "Users can update movements for own and linked customers"
  ON account_movements FOR UPDATE
  TO authenticated
  USING (
    -- الحركة على عميل مملوك للمستخدم الحالي
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (
        SELECT id FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
    OR
    -- OR الحركة على عميل مرتبط
    customer_id IN (
      SELECT id FROM customers
      WHERE linked_user_id = (
        SELECT id FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
  )
  WITH CHECK (
    -- نفس الشرط للـ WITH CHECK
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (
        SELECT id FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
    OR
    customer_id IN (
      SELECT id FROM customers
      WHERE linked_user_id = (
        SELECT id FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
  );

COMMENT ON POLICY "Users can update movements for own and linked customers" 
  ON account_movements 
  IS 'السماح بتحديث حركات على العملاء المملوكين أو المرتبطين';

-- تحديث DELETE policy أيضاً
DROP POLICY IF EXISTS "Users can delete own movements" ON account_movements;

CREATE POLICY "Users can delete movements for own and linked customers"
  ON account_movements FOR DELETE
  TO authenticated
  USING (
    -- الحركة على عميل مملوك للمستخدم الحالي
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = (
        SELECT id FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
    OR
    -- OR الحركة على عميل مرتبط
    customer_id IN (
      SELECT id FROM customers
      WHERE linked_user_id = (
        SELECT id FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
  );

COMMENT ON POLICY "Users can delete movements for own and linked customers" 
  ON account_movements 
  IS 'السماح بحذف حركات على العملاء المملوكين أو المرتبطين';
