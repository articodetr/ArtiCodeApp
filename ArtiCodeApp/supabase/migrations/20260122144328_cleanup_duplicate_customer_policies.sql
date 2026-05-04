/*
  # تنظيف السياسات المكررة على جدول customers
  
  ## المشكلة
  هناك سياسات RLS مكررة على جدول customers من migrations سابقة
  
  ## الحل
  حذف السياسات القديمة والإبقاء على السياسات الجديدة التي تستخدم get_current_user_id()
*/

-- حذف السياسات القديمة
DROP POLICY IF EXISTS "Users can view own customers and linked accounts" ON customers;
DROP POLICY IF EXISTS "Users can insert own customers" ON customers;
DROP POLICY IF EXISTS "Users can update own customers" ON customers;
DROP POLICY IF EXISTS "Users can delete own customers" ON customers;

-- التأكد من بقاء السياسات الجديدة فقط
COMMENT ON POLICY "Users can view their own customers" ON customers IS 'يسمح للمستخدم برؤية عملائه فقط أو العملاء المرتبطين به - محدث';
COMMENT ON POLICY "Users can insert their own customers" ON customers IS 'يسمح للمستخدم بإضافة عملاء له - محدث';
COMMENT ON POLICY "Users can update their own customers" ON customers IS 'يسمح للمستخدم بتحديث عملائه فقط - محدث';
COMMENT ON POLICY "Users can delete their own customers" ON customers IS 'يسمح للمستخدم بحذف عملائه فقط - محدث';
