/*
  # إضافة حقل اختيار الشعار للسندات

  1. التغييرات
    - إضافة حقل `selected_receipt_logo` إلى جدول `app_settings`
    - هذا الحقل يحفظ رابط الشعار الذي سيظهر في جميع السندات
    - القيمة الافتراضية NULL (سيستخدم النظام الشعار الافتراضي)
  
  2. ملاحظات
    - إذا كان الحقل NULL، سيستخدم النظام الشعار من حقل `shop_logo`
    - إذا كان الحقل يحتوي على قيمة، سيستخدم هذا الشعار في جميع السندات
*/

-- إضافة حقل selected_receipt_logo إلى جدول app_settings
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_settings' AND column_name = 'selected_receipt_logo'
  ) THEN
    ALTER TABLE app_settings 
    ADD COLUMN selected_receipt_logo text;
    
    COMMENT ON COLUMN app_settings.selected_receipt_logo IS 'رابط الشعار الذي يظهر في جميع السندات. NULL = استخدام shop_logo';
  END IF;
END $$;