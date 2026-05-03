/*
  # حذف الدالة القديمة create_notification
  
  يتم حذف جميع الإصدارات القديمة من الدالة لإعادة إنشائها بشكل صحيح
*/

-- حذف جميع إصدارات الدالة
DROP FUNCTION IF EXISTS create_notification(uuid, uuid, text, text, text, numeric, text, text, text);
DROP FUNCTION IF EXISTS create_notification(uuid, uuid, text, text);
