/*
  # إصلاح سياسة INSERT للسماح بالحركات المرآة
  
  المشكلة: سياسة INSERT الحالية تسمح فقط بإضافة حركات للعملاء المملوكين من قبل المستخدم الحالي.
  لكن عند إنشاء حركة مرآة، الـ trigger يحاول إنشاء حركة لعميل تابع لمستخدم آخر.
  
  الحل: تحديث السياسة للسماح بإدخال حركات عندما:
  1. العميل مملوك من قبل المستخدم الحالي، أو
  2. العميل هو عميل مرتبط (linked_user_id يشير للمستخدم الحالي)
*/

-- حذف السياسة القديمة
DROP POLICY IF EXISTS "Users can insert own movements" ON account_movements;

-- إنشاء السياسة الجديدة
CREATE POLICY "Users can insert own movements"
  ON account_movements
  FOR INSERT
  TO authenticated
  WITH CHECK (
    -- السماح بإضافة حركات للعملاء المملوكين
    customer_id IN (
      SELECT id 
      FROM customers 
      WHERE user_id = (
        SELECT id 
        FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
    OR
    -- السماح بإضافة حركات للعملاء المرتبطين (للحركات المرآة)
    customer_id IN (
      SELECT id 
      FROM customers 
      WHERE linked_user_id = (
        SELECT id 
        FROM app_security 
        WHERE user_name = current_setting('app.current_user', true)
      )
    )
  );
