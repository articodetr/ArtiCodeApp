/*
  Restore automatic account number generation for regular customers.

  A legacy trigger on `customers` still calls `auto_generate_account_number()`.
  That trigger depended on `generate_customer_account_number()`, but a later
  migration dropped the generator. Plain customer inserts then fail with
  Postgres error 42883.

  This migration recreates the missing generator, refreshes the trigger
  function, and keeps linked customers untouched because they already insert
  an explicit `account_number`.
*/

CREATE SEQUENCE IF NOT EXISTS regular_customer_account_number_seq
  START WITH 1000000
  INCREMENT BY 1
  MINVALUE 1000000
  NO MAXVALUE
  CACHE 1;

DO $$
DECLARE
  v_next_value bigint;
BEGIN
  SELECT GREATEST(
    1000000,
    COALESCE(MAX(account_number::bigint) + 1, 1000000)
  )
  INTO v_next_value
  FROM customers
  WHERE linked_user_id IS NULL
    AND account_number ~ '^[0-9]{7,}$';

  PERFORM setval('regular_customer_account_number_seq', v_next_value, false);
END $$;

CREATE OR REPLACE FUNCTION generate_customer_account_number()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_number text;
  v_exists boolean;
  v_attempts integer := 0;
BEGIN
  LOOP
    v_account_number := LPAD(nextval('regular_customer_account_number_seq')::text, 7, '0');

    SELECT EXISTS (
      SELECT 1
      FROM customers
      WHERE account_number = v_account_number

      UNION ALL

      SELECT 1
      FROM app_security
      WHERE account_number = v_account_number
    )
    INTO v_exists;

    EXIT WHEN NOT v_exists;

    v_attempts := v_attempts + 1;
    IF v_attempts >= 1000 THEN
      RAISE EXCEPTION 'Failed to generate a unique customer account number';
    END IF;
  END LOOP;

  RETURN v_account_number;
END;
$$;

CREATE OR REPLACE FUNCTION auto_generate_account_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.account_number IS NULL THEN
    NEW.account_number := generate_customer_account_number();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_generate_account_number ON customers;

CREATE TRIGGER trigger_auto_generate_account_number
BEFORE INSERT ON customers
FOR EACH ROW
EXECUTE FUNCTION auto_generate_account_number();

COMMENT ON FUNCTION generate_customer_account_number() IS
  'Generates unique account numbers for regular customers when account_number is omitted on insert.';

COMMENT ON FUNCTION auto_generate_account_number() IS
  'Trigger function that restores automatic account number generation for regular customers.';
