-- Include movement creator fields in customer movements RPC so the UI can
-- correctly display whether the creator was the current account user or the
-- linked customer.

CREATE OR REPLACE FUNCTION get_customer_movements_with_user(
  p_user_name text,
  p_customer_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM set_config('app.current_user', p_user_name, false);

  SELECT jsonb_agg(
    jsonb_build_object(
      'id', am.id,
      'movement_number', am.movement_number,
      'customer_id', am.customer_id,
      'movement_type', am.movement_type,
      'amount', am.amount,
      'currency', am.currency,
      'notes', am.notes,
      'created_at', am.created_at,
      'sender_name', am.sender_name,
      'beneficiary_name', am.beneficiary_name,
      'commission', am.commission,
      'commission_currency', am.commission_currency,
      'commission_recipient_id', am.commission_recipient_id,
      'is_commission_movement', am.is_commission_movement,
      'receipt_number', am.receipt_number,
      'account_statement_number', am.account_statement_number,
      'transfer_number', am.transfer_number,
      'from_customer_id', am.from_customer_id,
      'to_customer_id', am.to_customer_id,
      'transfer_direction', am.transfer_direction,
      'related_transfer_id', am.related_transfer_id,
      'mirror_movement_id', am.mirror_movement_id,
      'source_user_id', am.source_user_id,
      'related_commission_movement_id', am.related_commission_movement_id,
      'created_by_user_id', am.created_by_user_id,
      'created_by_user_name', am.created_by_user_name,
      'pending_approval', COALESCE(am.pending_approval, false),
      'approval_status', COALESCE(am.approval_status, 'approved'),
      'approved_at', am.approved_at,
      'is_voided', COALESCE(am.is_voided, false),
      'is_internal_transfer', CASE
        WHEN am.from_customer_id IS NOT NULL OR am.to_customer_id IS NOT NULL THEN true
        ELSE false
      END,
      'customer', jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'linked_user_id', c.linked_user_id,
        'linked_user', CASE
          WHEN c.linked_user_id IS NOT NULL THEN
            jsonb_build_object(
              'id', lu.id,
              'user_name', lu.user_name,
              'full_name', lu.full_name,
              'account_number', lu.account_number
            )
          ELSE NULL
        END
      )
    )
    ORDER BY am.created_at DESC
  )
  INTO v_result
  FROM account_movements am
  LEFT JOIN customers c ON am.customer_id = c.id
  LEFT JOIN app_security lu ON c.linked_user_id = lu.id
  WHERE am.customer_id = p_customer_id
    AND COALESCE(am.is_voided, false) = false;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_customer_movements_with_user(text, uuid) TO anon, authenticated;

COMMENT ON FUNCTION get_customer_movements_with_user IS
  'Returns customer movements with creator fields so the UI can show whether the movement was created by the current user or the linked customer.';
