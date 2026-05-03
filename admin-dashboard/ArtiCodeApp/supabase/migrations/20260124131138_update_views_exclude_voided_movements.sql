/*
  # Update All Views to Exclude Voided Movements

  ## Description
  Update all balance calculation views and customer activity views to exclude
  voided movements from calculations. This ensures rejected or deleted movements
  don't affect balances.

  ## Updated Views
  1. customer_balances_by_currency - Main balance calculation view
  2. customers_with_last_activity - Customer list with last activity
  3. Any other views that query account_movements

  ## Key Change
  Add WHERE is_voided = false to all account_movements queries
*/

-- Drop and recreate customer_balances_by_currency to exclude voided movements
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
  AND am.is_voided = false  -- EXCLUDE VOIDED MOVEMENTS
WHERE c.user_id = (
  SELECT id 
  FROM app_security 
  WHERE user_name = current_setting('app.current_user', true)
)
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

-- Drop and recreate customers_with_last_activity to exclude voided movements
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
        AND am.is_voided = false  -- EXCLUDE VOIDED MOVEMENTS
    ),
    c.created_at
  ) AS last_activity,
  (
    SELECT COUNT(*)
    FROM account_movements am
    WHERE am.customer_id = c.id
      AND am.is_voided = false  -- EXCLUDE VOIDED MOVEMENTS
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
          AND am.is_voided = false  -- EXCLUDE VOIDED MOVEMENTS
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
WHERE c.user_id = (
  SELECT id 
  FROM app_security 
  WHERE user_name = current_setting('app.current_user', true)
)
ORDER BY last_activity DESC;

COMMENT ON VIEW customer_balances_by_currency IS 
  'Customer balances by currency - excludes voided movements';

COMMENT ON VIEW customers_with_last_activity IS 
  'Customers with last activity and balances - excludes voided movements';
