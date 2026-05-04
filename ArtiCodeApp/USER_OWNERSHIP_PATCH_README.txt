تم تطبيق ملفات التعديل داخل المشروع الحالي.

الملفات التي تم تحديثها:
- contexts/AuthContext.tsx
- components/QuickAddMovementSheet.tsx
- services/logoService.ts
- utils/logoHelper.ts
- utils/whatsappTemplates.ts
- app/whatsapp-templates.tsx
- types/database.ts
- supabase/migrations/20260502021500_reconcile_app_settings_schema_and_user_ownership.sql

الخطوات التالية:
1) راجع التغييرات عبر git diff
2) شغّل migration الجديدة على قاعدة البيانات
3) شغّل:
   npm run typecheck
4) ثم شغّل التطبيق

مهم:
- هذا السكربت ينشئ نسخة احتياطية داخل:
  .user-ownership-patch-backup/<timestamp>
- إذا كان عندك تعديلات محلية غير محفوظة، اعمل commit أو copy قبل التشغيل.