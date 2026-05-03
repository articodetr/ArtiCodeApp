/*
  # Fix customer_balances_by_currency View - Remove User Filter

  ## Problem
  The view was filtering by current_setting('app.current_user') which is not set
  in the application context, causing balances to not show.

  ## Solution
  Remove the WHERE clause from the view and let the application handle filtering
  by user_id. The application already filters with .eq('user_id', currentUser.userId).

  ## Changes
  - Remove WHERE user_id = ... filter from view
  - Let application handle filtering at query time
*/

DROP VIEW IF EXISTS customer_balances_by_currency CASCADE;

CREATE VIEW customer_balances_by_currency AS
SELECT 
  c.id AS customer_id,
  c.name AS customer_name,
  c.user_id,
  c.account_number,
  c.is_profit_loss_account,
  am.currency,
  SUM(
    CASE 
      WHEN am.movement_type = 'incoming' THEN am.amount
      WHEN am.movement_type = 'outgoing' THEN -am.amount
      ELSE 0
    END
  ) AS balance,
  MAX(am.created_at) AS last_movement_date,
  COUNT(am.id) AS movement_count
FROM customers c
LEFT JOIN account_movements am 
  ON c.id = am.customer_id 
  AND am.is_voided = false
GROUP BY 
  c.id, 
  c.name, 
  c.user_id, 
  c.account_number, 
  c.is_profit_loss_account,
  am.currency
HAVING 
  am.currency IS NOT NULL
  AND (
    SUM(
      CASE 
        WHEN am.movement_type = 'incoming' THEN am.amount
        WHEN am.movement_type = 'outgoing' THEN -am.amount
        ELSE 0
      END
    ) != 0 
    OR c.is_profit_loss_account = true
  );

COMMENT ON VIEW customer_balances_by_currency IS 
  'Customer balances by currency - application filters by user_id';
