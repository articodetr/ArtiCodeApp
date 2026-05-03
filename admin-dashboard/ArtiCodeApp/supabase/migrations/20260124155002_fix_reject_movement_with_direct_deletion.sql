/*
  # إصلاح نظام رفض الحركات - حذف مباشر مع إشعار

  1. Changes
    - إنشاء دالة جديدة `reject_movement_with_reason` لرفض وحذف الحركة مباشرة
    - المستقبِل يمكنه رفض الحركة وحذفها مباشرة بدون انتظار موافقة
    - إرسال إشعار للمنشئ مع سبب الرفض
    - الإشعار يحتوي على كل تفاصيل الحركة وسبب الرفض

  2. Security
    - SECURITY DEFINER لضمان الصلاحيات الصحيحة
    - التحقق من أن المستخدم موجود
    - التحقق من وجود الحركة
*/

-- دالة رفض الحركة مع حذف مباشر وإشعار
CREATE OR REPLACE FUNCTION reject_movement_with_reason(
  p_movement_id uuid,
  p_user_name text,
  p_reject_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_movement record;
  v_customer record;
  v_creator_user record;
  v_result json;
BEGIN
  -- الحصول على معرف المستخدم الذي يرفض
  SELECT id INTO v_user_id
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'المستخدم غير موجود: %', p_user_name;
  END IF;

  -- الحصول على الحركة مع معلومات العميل
  SELECT 
    am.*,
    c.name as customer_name
  INTO v_movement
  FROM account_movements am
  LEFT JOIN customers c ON c.id = am.customer_id
  WHERE am.id = p_movement_id;

  IF v_movement IS NULL THEN
    RAISE EXCEPTION 'الحركة غير موجودة';
  END IF;

  -- الحصول على معلومات المنشئ
  SELECT user_name INTO v_creator_user
  FROM app_security
  WHERE id = v_movement.created_by_user_id;

  -- حذف الحركة المرآة إن وجدت
  IF v_movement.mirror_movement_id IS NOT NULL THEN
    DELETE FROM account_movements 
    WHERE id = v_movement.mirror_movement_id;
  END IF;

  -- حذف أي حركات مرتبطة (مثل حركات العمولة)
  DELETE FROM account_movements 
  WHERE linked_movement_id = p_movement_id;

  -- حذف الحركة الأساسية
  DELETE FROM account_movements WHERE id = p_movement_id;

  -- إرسال إشعار للمنشئ مع سبب الرفض
  IF v_movement.created_by_user_id IS NOT NULL THEN
    PERFORM create_notification(
      p_movement_id := p_movement_id,
      p_user_id := v_movement.created_by_user_id,
      p_notification_type := 'movement_rejected',
      p_message := 'تم رفض الحركة رقم ' || v_movement.movement_number,
      p_movement_number := v_movement.movement_number,
      p_amount := v_movement.amount,
      p_currency := v_movement.currency,
      p_customer_name := v_movement.customer_name,
      p_actor_name := p_user_name,
      p_movement_type := v_movement.movement_type,
      p_extra_data := jsonb_build_object(
        'reject_reason', p_reject_reason,
        'rejected_by', p_user_name,
        'rejected_at', now()
      )
    );
  END IF;

  v_result := json_build_object(
    'success', true,
    'message', 'تم رفض وحذف الحركة بنجاح',
    'deleted', true,
    'notification_sent', true,
    'reject_reason', p_reject_reason
  );

  RETURN v_result;
END;
$$;
