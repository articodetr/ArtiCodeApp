/*
  # إصلاح أسماء Foreign Key Constraints

  ## المشكلة
  - أسماء Foreign Key Constraints الحالية لا تتوافق مع النمط المتوقع من Supabase
  - Supabase يتوقع النمط: {table}_{column}_fkey
  - الأسماء الحالية: fk_customers_linked_user_id و fk_customers_user_id

  ## الإصلاح
  1. إعادة تسمية `fk_customers_linked_user_id` إلى `customers_linked_user_id_fkey`
  2. إعادة تسمية `fk_customers_user_id` إلى `customers_user_id_fkey`
  
  ## التأثير
  - سيسمح هذا لـ Supabase بإيجاد العلاقات بشكل صحيح عند استخدام الاستعلامات المتداخلة
*/

-- إعادة تسمية foreign key للـ linked_user_id
ALTER TABLE customers
DROP CONSTRAINT IF EXISTS fk_customers_linked_user_id;

ALTER TABLE customers
ADD CONSTRAINT customers_linked_user_id_fkey
FOREIGN KEY (linked_user_id)
REFERENCES app_security(id)
ON DELETE SET NULL;

-- إعادة تسمية foreign key للـ user_id  
ALTER TABLE customers
DROP CONSTRAINT IF EXISTS fk_customers_user_id;

ALTER TABLE customers
ADD CONSTRAINT customers_user_id_fkey
FOREIGN KEY (user_id)
REFERENCES app_security(id)
ON DELETE CASCADE;
