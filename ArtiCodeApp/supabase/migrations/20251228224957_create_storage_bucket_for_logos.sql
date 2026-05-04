/*
  # إنشاء Storage Bucket للشعارات

  1. إنشاء Bucket
    - إنشاء bucket عام بالاسم "shop-logos" لتخزين شعارات المحلات

  2. سياسات الأمان
    - سياسة قراءة عامة: السماح لجميع المستخدمين بقراءة الصور
    - سياسة رفع: السماح للمستخدمين المصادق عليهم برفع الصور
    - سياسة حذف: السماح للمستخدمين المصادق عليهم بحذف الصور
*/

-- إنشاء bucket للشعارات (public)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'shop-logos',
  'shop-logos',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

-- سياسة القراءة العامة
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'storage' 
    AND tablename = 'objects' 
    AND policyname = 'Public Access'
  ) THEN
    CREATE POLICY "Public Access"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'shop-logos');
  END IF;
END $$;

-- سياسة الرفع للمستخدمين المصادق عليهم
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'storage' 
    AND tablename = 'objects' 
    AND policyname = 'Enable upload for authenticated users'
  ) THEN
    CREATE POLICY "Enable upload for authenticated users"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (bucket_id = 'shop-logos');
  END IF;
END $$;

-- سياسة التحديث للمستخدمين المصادق عليهم
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'storage' 
    AND tablename = 'objects' 
    AND policyname = 'Enable update for authenticated users'
  ) THEN
    CREATE POLICY "Enable update for authenticated users"
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (bucket_id = 'shop-logos')
    WITH CHECK (bucket_id = 'shop-logos');
  END IF;
END $$;

-- سياسة الحذف للمستخدمين المصادق عليهم
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'storage' 
    AND tablename = 'objects' 
    AND policyname = 'Enable delete for authenticated users'
  ) THEN
    CREATE POLICY "Enable delete for authenticated users"
    ON storage.objects FOR DELETE
    TO authenticated
    USING (bucket_id = 'shop-logos');
  END IF;
END $$;