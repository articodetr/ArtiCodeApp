/*
  ArtiCode App - Cleanup duplicate statistics RPC functions
  Purpose:
    - Remove every old overloaded/cached version of get_app_statistics and get_app_period_statistics.
    - This fixes: ERROR 42725: function public.get_app_statistics(uuid) is not unique.

  Safe for existing production database:
    - Does not delete tables.
    - Does not delete customer/movement data.
*/

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'get_app_statistics',
        'get_app_period_statistics'
      )
  LOOP
    EXECUTE format(
      'DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE',
      r.schema_name,
      r.function_name,
      r.args
    );
  END LOOP;
END $$;

SELECT 'old_duplicate_statistics_functions_removed' AS status;
