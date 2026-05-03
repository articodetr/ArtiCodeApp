/*
  # Fix customer_balances View to Exclude Voided Movements

  ## Problem
  The `customer_balances` view was not filtering out voided (rejected) movements,
  causing rejected movements to still appear in balance calculations.

  ## Changes
  - Update `customer_balances` view to exclude movements where `is_voided = true`
  - This ensures rejected movements don't affect balances or totals
  - Matches the behavior of `customer_balances_by_currency` view

  ## Impact
  - Rejected movements will no longer appear in balance calculations
  - Users will see accurate balances without rejected movements
*/

-- Drop and recreate the view with is_voided filter
DROP VIEW IF EXISTS customer_balances;

CREATE OR REPLACE VIEW customer_balances AS
SELECT 
  c.id,
  c.name,
  c.phone,
  c.user_id,
  c.linked_user_id,
  c.is_profit_loss_account,
  
  -- Total incoming (excluding commission movements and voided movements)
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' 
          AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
          AND (am.is_voided IS NULL OR am.is_voided = false)
        THEN am.amount 
        ELSE 0 
      END
    ), 0
  ) AS total_incoming,
  
  -- Total outgoing (excluding commission movements and voided movements)
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'outgoing' 
          AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
          AND (am.is_voided IS NULL OR am.is_voided = false)
        THEN am.amount 
        ELSE 0 
      END
    ), 0
  ) AS total_outgoing,
  
  -- Balance (incoming - outgoing, excluding commission movements and voided movements)
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' 
          AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
          AND (am.is_voided IS NULL OR am.is_voided = false)
        THEN am.amount
        WHEN am.movement_type = 'outgoing' 
          AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
          AND (am.is_voided IS NULL OR am.is_voided = false)
        THEN -am.amount
        ELSE 0 
      END
    ), 0
  ) AS balance,
  
  am.currency,
  MAX(am.created_at) AS last_activity
  
FROM customers c
LEFT JOIN account_movements am ON c.id = am.customer_id
  
GROUP BY c.id, c.name, c.phone, c.user_id, c.linked_user_id, c.is_profit_loss_account, am.currency

-- Always show profit/loss account, or show customers with non-zero balance
HAVING 
  c.is_profit_loss_account = true
  OR 
  COALESCE(
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' 
          AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
          AND (am.is_voided IS NULL OR am.is_voided = false)
        THEN am.amount
        WHEN am.movement_type = 'outgoing' 
          AND (am.is_commission_movement IS NULL OR am.is_commission_movement = false)
          AND (am.is_voided IS NULL OR am.is_voided = false)
        THEN -am.amount
        ELSE 0 
      END
    ), 0
  ) != 0;

COMMENT ON VIEW customer_balances IS 'عرض أرصدة العملاء مع استثناء الحركات الملغاة والمرفوضة';
