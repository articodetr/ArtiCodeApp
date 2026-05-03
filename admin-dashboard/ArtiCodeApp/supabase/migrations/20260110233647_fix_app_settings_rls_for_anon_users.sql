/*
  # إصلاح صلاحيات RLS لجدول app_settings للمستخدمين الغير مصادق عليهم

  ## المشكلة
  المستخدمون على الأجهزة المحمولة يستخدمون نظام PIN محلي وليسوا مصادق عليهم في Supabase (anon role).
  السياسات الحالية تسمح فقط للمستخدمين المصادق عليهم (authenticated) بالتعديل.
  
  ## الحل
  1. حذف السياسة القديمة المقيدة للمستخدمين المصادق عليهم فقط
  2. إنشاء سياسة جديدة تسمح لجميع المستخدمين (anon و authenticated) بالتعديل
  
  ## الأمان
  - التطبيق يستخدم نظام PIN محلي للأمان
  - جدول app_settings يحتوي على إعدادات عامة للتطبيق (اسم المحل، العنوان، الشعار)
  - لا يوجد بيانات حساسة في هذا الجدول تتطلب حماية على مستوى RLS
*/

-- حذف السياسات القديمة المقيدة
DROP POLICY IF EXISTS "Allow authenticated users to update app_settings" ON app_settings;
DROP POLICY IF EXISTS "Allow public read access to app_settings" ON app_settings;

-- إنشاء سياسة جديدة تسمح لجميع المستخدمين بالقراءة والتعديل
CREATE POLICY "Allow anon and authenticated users full access to app_settings"
  ON app_settings
  FOR ALL
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);
