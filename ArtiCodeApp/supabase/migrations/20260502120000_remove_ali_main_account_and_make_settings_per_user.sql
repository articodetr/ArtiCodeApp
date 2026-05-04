-- supabase/migrations/20260502120000_remove_ali_main_account_and_make_settings_per_user.sql

begin;

-- 1) إلغاء حماية الحساب الرئيسي المرتبطة باسم Ali / A
drop trigger if exists prevent_ali_deletion_trigger on app_security;
drop function if exists prevent_ali_deletion();

-- لو عندك trigger/function أخرى مرتبطة بالحساب الرئيسي، احذفها هنا أيضًا
-- مثال:
-- drop trigger if exists prevent_main_admin_deletion_trigger on app_security;
-- drop function if exists prevent_main_admin_deletion();

-- 2) جعل إعدادات التطبيق لكل مستخدم
alter table app_settings
  add column if not exists user_id uuid references app_security(id) on delete cascade;

create unique index if not exists app_settings_user_id_uidx
  on app_settings(user_id)
  where user_id is not null;

-- 3) نسخ الإعدادات العامة الحالية إلى كل مستخدم موجود
do $$
declare
  v_seed record;
begin
  select
    shop_name,
    shop_phone,
    shop_address,
    selected_receipt_logo
  into v_seed
  from app_settings
  order by created_at asc
  limit 1;

  insert into app_settings (
    id,
    user_id,
    shop_name,
    shop_phone,
    shop_address,
    selected_receipt_logo
  )
  select
    gen_random_uuid(),
    u.id,
    coalesce(v_seed.shop_name, 'ArtiCode'),
    coalesce(v_seed.shop_phone, ''),
    coalesce(v_seed.shop_address, ''),
    v_seed.selected_receipt_logo
  from app_security u
  where not exists (
    select 1
    from app_settings s
    where s.user_id = u.id
  );
end $$;

-- 4) دالة تجيب أو تنشئ إعدادات المستخدم
create or replace function get_or_create_user_settings(p_user_id uuid)
returns app_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings app_settings;
begin
  select *
  into v_settings
  from app_settings
  where user_id = p_user_id
  limit 1;

  if found then
    return v_settings;
  end if;

  insert into app_settings (
    id,
    user_id,
    shop_name,
    shop_phone,
    shop_address,
    selected_receipt_logo
  )
  values (
    gen_random_uuid(),
    p_user_id,
    'ArtiCode',
    '',
    '',
    null
  )
  returning * into v_settings;

  return v_settings;
end;
$$;

-- 5) تثبيت ملكية الحركات بالمستخدم الحقيقي
alter table movements
  add column if not exists created_by_user_id uuid references app_security(id),
  add column if not exists source_user_id uuid references app_security(id);

create index if not exists movements_created_by_user_id_idx
  on movements(created_by_user_id);

create index if not exists movements_source_user_id_idx
  on movements(source_user_id);

create index if not exists customers_user_id_idx
  on customers(user_id);

commit;