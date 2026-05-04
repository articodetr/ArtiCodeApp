/*
  # Fix customers_with_last_activity View - Remove User Filter

  ## Problem
  The view was filtering by current_setting('app.current_user') which is not set
  in the application context, causing customers to disappear.

  ## Solution
  Remove the WHERE clause from the view and let the application handle filtering
  by user_id. The RLS policies and application-level filtering will ensure
  users only see their own customers.

  ## Changes
  - Remove WHERE user_id = ... filter from view
  - Let application handle filtering with .or() clause
*/

DROP VIEW IF EXISTS customers_with_last_activity CASCADE;

CREATE VIEW customers_with_last_activity AS
SELECT 
  c.id,
  c.name,
  c.account_number,
  c.phone,
  c.notes,
  c.is_profit_loss_account,
  c.user_id,
  c.linked_user_id,
  c.created_at,
  c.updated_at,
  COALESCE(
    (
      SELECT MAX(am.created_at)
      FROM account_movements am
      WHERE am.customer_id = c.id
        AND am.is_voided = false
    ),
    c.created_at
  ) AS last_activity,
  (
    SELECT COUNT(*)
    FROM account_movements am
    WHERE am.customer_id = c.id
      AND am.is_voided = false
  ) AS movement_count,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object(
          'currency', currency,
          'balance', balance
        )
      )
      FROM (
        SELECT 
          am.currency,
          SUM(
            CASE 
              WHEN am.movement_type = 'incoming' THEN am.amount
              WHEN am.movement_type = 'outgoing' THEN -am.amount
              ELSE 0
            END
          ) AS balance
        FROM account_movements am
        WHERE am.customer_id = c.id
          AND am.is_voided = false
        GROUP BY am.currency
        HAVING SUM(
          CASE 
            WHEN am.movement_type = 'incoming' THEN am.amount
            WHEN am.movement_type = 'outgoing' THEN -am.amount
            ELSE 0
          END
        ) != 0
      ) balances
    ),
    '[]'::json
  ) AS balances
FROM customers c
ORDER BY last_activity DESC;

COMMENT ON VIEW customers_with_last_activity IS 
  'Customers with last activity and balances - application filters by user_id';
