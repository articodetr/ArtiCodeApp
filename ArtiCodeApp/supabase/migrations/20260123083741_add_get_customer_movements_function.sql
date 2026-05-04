/*
  # إضافة دالة لجلب حركات العميل مع سياق المستخدم

  ## المشكلة
  - سياسات RLS تعتمد على `app.current_user` المعيّن عبر `set_config()`
  - بسبب Connection Pooling في Supabase، قد تستخدم الاستعلامات المتتالية اتصالات مختلفة
  - عند استدعاء `set_current_user` ثم جلب البيانات، قد يستخدم الاستعلام الثاني اتصال مختلف بدون السياق
  - هذا يؤدي إلى فشل RLS وعدم إرجاع أي نتائج

  ## الحل
  إنشاء دالة محمية (SECURITY DEFINER) تقوم بـ:
  1. تعيين المستخدم في السياق
  2. جلب حركات العميل في نفس المعاملة
  3. إرجاع النتائج

  ## الدالة
  - `get_customer_movements_with_user`: جلب جميع حركات عميل معين مع تعيين سياق المستخدم
*/

-- دالة لجلب حركات العميل مع تعيين المستخدم في السياق
CREATE OR REPLACE FUNCTION get_customer_movements_with_user(
  p_user_name text,
  p_customer_id uuid
)
RETURNS TABLE(
  id uuid,
  movement_number text,
  customer_id uuid,
  movement_type text,
  amount numeric,
  currency text,
  notes text,
  created_at timestamptz,
  sender_name text,
  beneficiary_name text,
  commission numeric,
  commission_currency text,
  commission_recipient_id uuid,
  is_commission_movement boolean,
  receipt_number text,
  account_statement_number text,
  transfer_number text,
  from_customer_id uuid,
  to_customer_id uuid,
  transfer_direction text,
  related_transfer_id uuid,
  mirror_movement_id uuid,
  source_user_id uuid,
  related_commission_movement_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- تعيين المستخدم الحالي في السياق
  PERFORM set_config('app.current_user', p_user_name, false);
  
  -- جلب وإرجاع جميع حركات العميل
  RETURN QUERY
  SELECT 
    am.id,
    am.movement_number,
    am.customer_id,
    am.movement_type,
    am.amount,
    am.currency,
    am.notes,
    am.created_at,
    am.sender_name,
    am.beneficiary_name,
    am.commission,
    am.commission_currency,
    am.commission_recipient_id,
    am.is_commission_movement,
    am.receipt_number,
    am.account_statement_number,
    am.transfer_number,
    am.from_customer_id,
    am.to_customer_id,
    am.transfer_direction,
    am.related_transfer_id,
    am.mirror_movement_id,
    am.source_user_id,
    am.related_commission_movement_id
  FROM account_movements am
  WHERE am.customer_id = p_customer_id
  ORDER BY am.created_at DESC;
END;
$$;

-- منح الصلاحيات
GRANT EXECUTE ON FUNCTION get_customer_movements_with_user(text, uuid) TO anon, authenticated;
