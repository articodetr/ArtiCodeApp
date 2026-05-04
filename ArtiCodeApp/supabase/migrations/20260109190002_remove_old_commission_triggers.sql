/*
  # حذف الـ triggers القديمة للعمولات

  ## المشكلة
  هناك triggers قديمة لا تزال نشطة تسبب تسجيل العمولة مرتين.

  ## الحل
  حذف جميع الـ triggers القديمة وإبقاء فقط record_commission_for_profit_loss_trigger.
*/

-- حذف جميع الـ triggers القديمة
DROP TRIGGER IF EXISTS record_commission_trigger_v4 ON account_movements;
DROP TRIGGER IF EXISTS record_commission_trigger_v3 ON account_movements;
DROP TRIGGER IF EXISTS record_commission_trigger_v2 ON account_movements;
DROP TRIGGER IF EXISTS record_commission_trigger ON account_movements;
DROP TRIGGER IF EXISTS calculate_net_amount_trigger ON account_movements;

-- حذف الدوال القديمة
DROP FUNCTION IF EXISTS record_commission_to_profit_loss_v4() CASCADE;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss_v3() CASCADE;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss_v2() CASCADE;
DROP FUNCTION IF EXISTS record_commission_to_profit_loss() CASCADE;
DROP FUNCTION IF EXISTS calculate_net_amount_before_insert() CASCADE;