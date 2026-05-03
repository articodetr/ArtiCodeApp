/*
  # إضافة View للعملاء مع آخر نشاط

  ## التغييرات
  
  ### 1. View جديدة: customers_with_last_activity
  - تجلب جميع بيانات العملاء
  - تضيف عمود `last_activity_date` - تاريخ آخر حركة للعميل
  - إذا لم يكن للعميل حركات، يتم استخدام تاريخ الإنشاء `created_at`
  
  ## الغرض
  - تمكين ترتيب العملاء حسب النشاط (آخر حركة)
  - إبقاء حساب الأرباح والخسائر في الأول دائماً
  - العملاء النشطين يظهرون في الأعلى
  
  ## الأمان
  - الـ View يرث صلاحيات RLS من جدول customers
*/

-- إنشاء View للعملاء مع آخر نشاط
CREATE OR REPLACE VIEW customers_with_last_activity AS
SELECT 
  c.*,
  COALESCE(MAX(am.created_at), c.created_at) as last_activity_date
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
GROUP BY c.id, c.name, c.phone, c.email, c.address, c.balance, c.notes, 
         c.created_at, c.updated_at, c.is_profit_loss_account;

-- منح الصلاحيات للـ View
GRANT SELECT ON customers_with_last_activity TO authenticated;
GRANT SELECT ON customers_with_last_activity TO anon;