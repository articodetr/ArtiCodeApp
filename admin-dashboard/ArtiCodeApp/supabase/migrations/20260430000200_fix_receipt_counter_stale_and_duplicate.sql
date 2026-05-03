BEGIN;

-- 1) Sync per-customer counters with existing movements
UPDATE customers c
SET last_receipt_number = COALESCE(src.max_num, 0)
FROM (
  SELECT customer_id, MAX(CAST(receipt_number AS integer)) AS max_num
  FROM account_movements
  WHERE customer_id IS NOT NULL
    AND receipt_number IS NOT NULL
    AND receipt_number ~ '^\d+$'
  GROUP BY customer_id
) src
WHERE c.id = src.customer_id;

UPDATE customers
SET last_receipt_number = 0
WHERE last_receipt_number IS NULL;

-- 2) Ensure linked pairs exist and their counters are synced to the max receipt used by either side
INSERT INTO linked_account_pairs (
  user_id_1,
  user_id_2,
  customer_id_1,
  customer_id_2,
  last_receipt_number
)
SELECT DISTINCT
  LEAST(c1.user_id, c2.user_id) AS user_id_1,
  GREATEST(c1.user_id, c2.user_id) AS user_id_2,
  CASE WHEN c1.user_id < c2.user_id THEN c1.id ELSE c2.id END AS customer_id_1,
  CASE WHEN c1.user_id < c2.user_id THEN c2.id ELSE c1.id END AS customer_id_2,
  COALESCE((
    SELECT MAX(CAST(am.receipt_number AS integer))
    FROM account_movements am
    WHERE (am.customer_id = c1.id OR am.customer_id = c2.id)
      AND am.receipt_number IS NOT NULL
      AND am.receipt_number ~ '^\d+$'
  ), 0) AS last_receipt_number
FROM customers c1
JOIN customers c2
  ON c1.linked_user_id = c2.user_id
 AND c2.linked_user_id = c1.user_id
WHERE c1.linked_user_id IS NOT NULL
  AND c1.user_id < c2.user_id
ON CONFLICT (user_id_1, user_id_2) DO UPDATE
SET last_receipt_number = EXCLUDED.last_receipt_number,
    customer_id_1 = EXCLUDED.customer_id_1,
    customer_id_2 = EXCLUDED.customer_id_2,
    updated_at = now();

-- 3) Safer per-customer generator: self-heals if last_receipt_number is stale
CREATE OR REPLACE FUNCTION generate_customer_receipt_number(p_customer_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_current_max integer;
  v_next_number integer;
BEGIN
  SELECT COALESCE(MAX(CAST(receipt_number AS integer)), 0)
  INTO v_current_max
  FROM account_movements
  WHERE customer_id = p_customer_id
    AND receipt_number IS NOT NULL
    AND receipt_number ~ '^\d+$';

  UPDATE customers
  SET last_receipt_number = GREATEST(COALESCE(last_receipt_number, 0), v_current_max) + 1
  WHERE id = p_customer_id
  RETURNING last_receipt_number INTO v_next_number;

  IF v_next_number IS NULL THEN
    RAISE EXCEPTION 'Customer not found while generating receipt number: %', p_customer_id;
  END IF;

  RETURN LPAD(v_next_number::text, 5, '0');
END;
$$;

-- 4) Safer shared generator for linked accounts: self-heals pair counter before incrementing
CREATE OR REPLACE FUNCTION generate_shared_receipt_number(p_customer_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_customer record;
  v_linked_customer_id uuid;
  v_pair_id uuid;
  v_current_max integer;
  v_next_number integer;
BEGIN
  SELECT * INTO v_customer
  FROM customers
  WHERE id = p_customer_id;

  IF v_customer IS NULL THEN
    RAISE EXCEPTION 'Customer not found: %', p_customer_id;
  END IF;

  IF v_customer.linked_user_id IS NULL THEN
    RETURN generate_customer_receipt_number(p_customer_id);
  END IF;

  SELECT id INTO v_linked_customer_id
  FROM customers
  WHERE user_id = v_customer.linked_user_id
    AND linked_user_id = v_customer.user_id
  LIMIT 1;

  IF v_linked_customer_id IS NULL THEN
    RETURN generate_customer_receipt_number(p_customer_id);
  END IF;

  v_pair_id := get_or_create_linked_pair(
    v_customer.user_id,
    v_customer.linked_user_id,
    p_customer_id,
    v_linked_customer_id
  );

  SELECT COALESCE(MAX(CAST(receipt_number AS integer)), 0)
  INTO v_current_max
  FROM account_movements
  WHERE (customer_id = p_customer_id OR customer_id = v_linked_customer_id)
    AND receipt_number IS NOT NULL
    AND receipt_number ~ '^\d+$';

  UPDATE linked_account_pairs
  SET last_receipt_number = GREATEST(COALESCE(last_receipt_number, 0), v_current_max) + 1,
      updated_at = now()
  WHERE id = v_pair_id
  RETURNING last_receipt_number INTO v_next_number;

  IF v_next_number IS NULL THEN
    RAISE EXCEPTION 'Linked pair not found while generating shared receipt number for customer: %', p_customer_id;
  END IF;

  RETURN LPAD(v_next_number::text, 6, '0');
END;
$$;

-- 5) Trigger generator should use the repaired functions above
CREATE OR REPLACE FUNCTION auto_generate_receipt_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.receipt_number IS NULL THEN
    IF NEW.customer_id IS NULL THEN
      RAISE EXCEPTION 'Cannot generate receipt number without customer_id';
    END IF;

    NEW.receipt_number := generate_shared_receipt_number(NEW.customer_id);
    NEW.receipt_generated_at := now();
  END IF;

  RETURN NEW;
END;
$$;

COMMIT;
