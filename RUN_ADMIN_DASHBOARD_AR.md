# تشغيل لوحة تحكم ArtiCodeApp المستقلة

تمت إضافة لوحة تحكم ويب مستقلة داخل مجلد:

```txt
admin-dashboard
```

## الترتيب الصحيح

1. افتح Supabase SQL Editor.
2. شغل ملف:

```txt
supabase/migrations/20260501000000_admin_dashboard_subscriptions.sql
```

3. افتح التيرمنال داخل المشروع:

```bash
cd admin-dashboard
npm install
npm run dev
```

4. افتح الرابط:

```txt
http://localhost:5173
```

5. سجل الدخول بحساب Admin من جدول `app_security`.

## ملاحظة

تم وضع ملف `.env.local` داخل مجلد `admin-dashboard` بنفس بيانات Supabase الموجودة في `app.json`، حتى يعمل مع نفس قاعدة البيانات.

## ملف SQL الإضافي لحركة الحوالات

بعد تحديث الداش بورد الحالي، شغّل هذا الملف داخل Supabase SQL Editor:

```txt
supabase/migrations/20260501010000_admin_dashboard_transfer_movements.sql
```

ثم أعد تشغيل الداش بورد:

```bash
cd admin-dashboard
npm run dev
```
