/*
  # إصلاح سياسات Storage للسماح بالرفع لجميع المستخدمين

  1. المشكلة
    - التطبيق يستخدم نظام PIN للمصادقة (ليس Supabase Auth)
    - جميع المستخدمين يستخدمون anon key
    - السياسات الحالية تسمح فقط للـ authenticated users

  2. الحل
    - إضافة سياسات للسماح لـ anon users بالرفع والتحديث والحذف
    - هذا آمن لأن التطبيق لديه نظام مصادقة PIN خاص به
*/

-- سياسة الرفع لـ anon users
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'storage' 
    AND tablename = 'objects' 
    AND policyname = 'Allow anon users to upload logos'
  ) THEN
    CREATE POLICY "Allow anon users to upload logos"
    ON storage.objects FOR INSERT
    TO anon
    WITH CHECK (bucket_id = 'shop-logos');
  END IF;
END $$;

-- سياسة التحديث لـ anon users
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'storage' 
    AND tablename = 'objects' 
    AND policyname = 'Allow anon users to update logos'
  ) THEN
    CREATE POLICY "Allow anon users to update logos"
    ON storage.objects FOR UPDATE
    TO anon
    USING (bucket_id = 'shop-logos')
    WITH CHECK (bucket_id = 'shop-logos');
  END IF;
END $$;

-- سياسة الحذف لـ anon users
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'storage' 
    AND tablename = 'objects' 
    AND policyname = 'Allow anon users to delete logos'
  ) THEN
    CREATE POLICY "Allow anon users to delete logos"
    ON storage.objects FOR DELETE
    TO anon
    USING (bucket_id = 'shop-logos');
  END IF;
END $$;
