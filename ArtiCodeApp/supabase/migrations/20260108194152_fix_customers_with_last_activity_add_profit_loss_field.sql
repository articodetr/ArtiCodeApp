/*
  # إصلاح VIEW customers_with_last_activity لإضافة حقل is_profit_loss_account

  ## المشكلة

  الكود في `app/(tabs)/customers.tsx` يحاول الترتيب حسب `is_profit_loss_account`:
  ```typescript
  .order('is_profit_loss_account', { ascending: false })
  ```

  لكن VIEW `customers_with_last_activity` لا يحتوي على هذا الحقل، مما يسبب خطأ ويؤدي إلى شاشة بيضاء.

  ## الحل

  تحديث VIEW لإضافة حقل `is_profit_loss_account` بناءً على رقم الهاتف.

  ## الأمان

  - VIEW للقراءة فقط
  - لا يؤثر على البيانات المخزنة
*/

-- حذف VIEW القديم
DROP VIEW IF EXISTS customers_with_last_activity CASCADE;

-- إنشاء VIEW جديد مع حقل is_profit_loss_account
CREATE OR REPLACE VIEW customers_with_last_activity AS
SELECT
  c.id,
  c.name,
  c.phone,
  c.notes,
  c.created_at,
  MAX(am.created_at) as last_activity,
  -- إضافة حقل للتحقق من حساب الأرباح والخسائر
  (c.phone = 'PROFIT_LOSS_ACCOUNT') as is_profit_loss_account
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
WHERE c.phone != 'PROFIT_LOSS_ACCOUNT' OR c.phone IS NULL
GROUP BY c.id, c.name, c.phone, c.notes, c.created_at
ORDER BY 
  (c.phone = 'PROFIT_LOSS_ACCOUNT') DESC,
  last_activity DESC NULLS LAST, 
  c.created_at DESC;

-- تعيين المالك
ALTER VIEW customers_with_last_activity OWNER TO postgres;

-- إضافة تعليق توضيحي
COMMENT ON VIEW customers_with_last_activity IS 'عرض العملاء مع آخر نشاط - يتضمن حقل is_profit_loss_account للترتيب';
