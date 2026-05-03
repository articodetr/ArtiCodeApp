/*
  # إضافة حقول تتبع حركات العمولة

  ## الهدف
  دمج عرض العمولة مع المبلغ الأساسي في قائمة الحركات، مع الحفاظ على الفصل في قاعدة البيانات

  ## السيناريو المثالي
  
  **مثال: جلال يرسل لعماد 5000$ والعمولة 50$ تذهب لجلال**
  
  **في قاعدة البيانات (3 حركات منفصلة):**
  1. جلال: outgoing 5000$ (الحركة الأساسية)
  2. عماد: incoming 5000$ (الحركة الأساسية)
  3. الأرباح: outgoing 50$ (حركة العمولة)
  4. جلال: incoming 50$ (حركة العمولة) - مرتبطة بالحركة #1
  
  **في واجهة المستخدم:**
  - جلال يرى: "أرسلت 5000$" فقط (الحركة #4 مخفية، تظهر كتفصيل فقط)
  - عماد يرى: "استلمت 5050$" (مدمج: 5000$ أساسي + 50$ عمولة)
  - الأرباح ترى: "دفعت 50$" (حركة منفصلة)

  ## التغييرات

  1. حقل جديد: `is_commission_movement`
    - نوع: boolean
    - افتراضي: false
    - يحدد ما إذا كانت هذه الحركة عبارة عن حركة عمولة منفصلة

  2. حقل جديد: `related_commission_movement_id`
    - نوع: uuid
    - افتراضي: null
    - مرجع: account_movements(id)
    - يربط حركة العمولة بالحركة الأساسية التي تسببت فيها

  ## الأمان
  - لا تغييرات على RLS (الصلاحيات الحالية تنطبق على الحقول الجديدة)
*/

-- إضافة الحقول الجديدة
ALTER TABLE account_movements 
ADD COLUMN IF NOT EXISTS is_commission_movement boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS related_commission_movement_id uuid REFERENCES account_movements(id) ON DELETE SET NULL;

-- إنشاء فهرس للأداء
CREATE INDEX IF NOT EXISTS account_movements_is_commission_idx ON account_movements(is_commission_movement) WHERE is_commission_movement = true;
CREATE INDEX IF NOT EXISTS account_movements_related_commission_idx ON account_movements(related_commission_movement_id) WHERE related_commission_movement_id IS NOT NULL;

-- إضافة تعليق على الحقول
COMMENT ON COLUMN account_movements.is_commission_movement IS 'يحدد ما إذا كانت هذه الحركة عبارة عن حركة عمولة منفصلة (true) أو حركة عادية (false)';
COMMENT ON COLUMN account_movements.related_commission_movement_id IS 'معرف الحركة الأساسية التي تسببت في هذه العمولة (للربط بين الحركة الأساسية وحركة العمولة)';