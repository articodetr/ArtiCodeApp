تعديلات الاشتراكات وحد العملاء - ArtiCodeApp

ما تم إضافته:
1) إصلاح Build للداشبورد بإضافة vite-env.d.ts و @types/react-dom.
2) إضافة max_customers للاشتراكات حتى تحدد عدد العملاء المسموح لكل مستخدم.
3) إضافة دوال Supabase المطلوبة:
   - admin_dashboard_get_user_quota
   - admin_dashboard_cancel_subscription
   - admin_dashboard_save_subscription مع p_max_customers
   - create_regular_customer_with_quota_check
4) عند عدم وجود اشتراك نشط يكون الحد المجاني 5 عملاء.
5) إذا وصل المستخدم للحد، لن يستطيع إضافة عميل جديد من التطبيق وستظهر رسالة تطلب تفعيل/تجديد الاشتراك.
6) يمكن إلغاء الاشتراك يدويًا من لوحة الإدارة، وبعد الإلغاء يعود المستخدم للحد المجاني.
7) إضافة عرض حد العملاء في جدول المستخدمين والاشتراكات.
8) إضافة أزرار سريعة لاختيار حد العملاء: 5، 20، 50، 100، غير محدود.

طريقة تطبيق تحديث قاعدة البيانات:
- من Supabase Dashboard افتح SQL Editor.
- شغل الملف:
  APPLY_SUBSCRIPTION_QUOTA_PATCH.sql
أو شغل migration:
  supabase/migrations/20260502010000_subscription_quota_ready.sql

طريقة تشغيل الداشبورد:
cd admin-dashboard
npm install
npm run dev

طريقة بناء الداشبورد:
cd admin-dashboard
npm run build

ملاحظة مهمة:
تم اختبار بناء الداشبورد بنجاح. ظهر تحذير بسيط فقط أن tsconfig الجذر يعتمد على expo/tsconfig.base، وهذا لا يمنع بناء الداشبورد.
