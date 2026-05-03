/*
  # Void Movement and Mirror Function

  ## Description
  Unified function to void (soft-delete) a movement and its mirror, handling both
  reject and delete actions. Updates balances automatically and sends notifications.

  ## Function
  void_movement_and_mirror(
    p_movement_id uuid,
    p_user_name text,
    p_action text,  -- 'rejected' or 'deleted'
    p_reason text   -- optional explanation
  )

  ## Behavior
  1. Validates user exists and has permission
  2. Loads movement and ensures not already voided
  3. Finds mirror movement (bidirectional lookup)
  4. Voids both movements with audit trail
  5. Voids any related commission movements
  6. Creates notification for other party with snapshot data
  7. Returns success status and details

  ## Security
  - SECURITY DEFINER to update movements across users
  - Validates user_name against app_security
  - Ensures user owns one of the movements
*/

CREATE OR REPLACE FUNCTION void_movement_and_mirror(
  p_movement_id uuid,
  p_user_name text,
  p_action text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user record;
  v_movement record;
  v_mirror record;
  v_customer record;
  v_other_user record;
  v_notification_id uuid;
  v_void_type text;
BEGIN
  -- Validate action
  IF p_action NOT IN ('rejected', 'deleted') THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Invalid action. Must be rejected or deleted'
    );
  END IF;

  v_void_type := p_action;

  -- Get user
  SELECT * INTO v_user
  FROM app_security
  WHERE user_name = p_user_name;

  IF v_user IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not found'
    );
  END IF;

  -- Get movement with customer info
  SELECT 
    am.*,
    c.name as customer_name,
    c.user_id as customer_user_id,
    c.linked_user_id
  INTO v_movement
  FROM account_movements am
  JOIN customers c ON am.customer_id = c.id
  WHERE am.id = p_movement_id;

  IF v_movement IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Movement not found'
    );
  END IF;

  -- Check if already voided
  IF v_movement.is_voided THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Movement already voided'
    );
  END IF;

  -- Verify user has permission (owns the customer or the linked account)
  IF v_movement.customer_user_id != v_user.id 
     AND v_movement.linked_user_id != v_user.id THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Permission denied'
    );
  END IF;

  -- Find mirror movement (bidirectional lookup)
  IF v_movement.mirror_movement_id IS NOT NULL THEN
    -- Direct mirror reference
    SELECT 
      am.*,
      c.name as customer_name,
      c.user_id as customer_user_id
    INTO v_mirror
    FROM account_movements am
    JOIN customers c ON am.customer_id = c.id
    WHERE am.id = v_movement.mirror_movement_id;
  ELSE
    -- Reverse lookup
    SELECT 
      am.*,
      c.name as customer_name,
      c.user_id as customer_user_id
    INTO v_mirror
    FROM account_movements am
    JOIN customers c ON am.customer_id = c.id
    WHERE am.mirror_movement_id = p_movement_id;
  END IF;

  -- Void the original movement
  UPDATE account_movements
  SET 
    is_voided = true,
    voided_at = now(),
    voided_by_user_id = v_user.id,
    void_type = v_void_type,
    void_reason = p_reason,
    updated_at = now()
  WHERE id = p_movement_id;

  -- Void the mirror movement if exists
  IF v_mirror.id IS NOT NULL THEN
    UPDATE account_movements
    SET 
      is_voided = true,
      voided_at = now(),
      voided_by_user_id = v_user.id,
      void_type = v_void_type,
      void_reason = p_reason,
      updated_at = now()
    WHERE id = v_mirror.id;
  END IF;

  -- Void any related commission movements
  UPDATE account_movements
  SET 
    is_voided = true,
    voided_at = now(),
    voided_by_user_id = v_user.id,
    void_type = v_void_type,
    void_reason = COALESCE(p_reason, 'Related movement voided'),
    updated_at = now()
  WHERE related_commission_movement_id IN (p_movement_id, v_mirror.id)
    AND is_voided = false;

  -- Determine who to notify (the other party)
  IF v_mirror.id IS NOT NULL THEN
    SELECT * INTO v_other_user
    FROM app_security
    WHERE id = v_mirror.customer_user_id;

    -- Create notification for the other party
    INSERT INTO movement_notifications (
      movement_id,
      user_id,
      notification_type,
      message,
      movement_number,
      amount,
      currency,
      movement_type,
      customer_name,
      actor_name,
      extra_data,
      is_read,
      created_at
    ) VALUES (
      p_movement_id,
      v_other_user.id,
      CASE 
        WHEN p_action = 'rejected' THEN 'movement_rejected'
        WHEN p_action = 'deleted' THEN 'movement_deleted'
      END,
      CASE 
        WHEN p_action = 'rejected' THEN 
          v_user.user_name || ' رفض الحركة رقم ' || v_movement.movement_number
        WHEN p_action = 'deleted' THEN 
          v_user.user_name || ' حذف الحركة رقم ' || v_movement.movement_number
      END,
      v_movement.movement_number,
      v_movement.amount,
      v_movement.currency,
      v_movement.movement_type,
      v_movement.customer_name,
      v_user.user_name,
      jsonb_build_object(
        'reason', p_reason,
        'voided_at', now()
      ),
      false,
      now()
    )
    RETURNING id INTO v_notification_id;
  END IF;

  -- Return success
  RETURN jsonb_build_object(
    'success', true,
    'movement_id', p_movement_id,
    'mirror_id', v_mirror.id,
    'notification_id', v_notification_id,
    'action', p_action
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

COMMENT ON FUNCTION void_movement_and_mirror IS 
  'Voids (soft-deletes) a movement and its mirror for reject/delete flows';
