begin;

-- 1) Remove old fixed-owner protection tied to Ali/A
drop trigger if exists prevent_ali_deletion_trigger on public.app_security;
drop function if exists public.prevent_ali_deletion();

-- 2) Ensure app_settings has the current schema used by the app
alter table public.app_settings
  add column if not exists user_id uuid references public.app_security(id) on delete cascade,
  add column if not exists shop_logo text,
  add column if not exists header_layout text default 'centered',
  add column if not exists header_primary_color text default '#4F46E5',
  add column if not exists shop_name_en text,
  add column if not exists shop_phone_en text,
  add column if not exists shop_address_en text,
  add column if not exists selected_receipt_logo text,
  add column if not exists whatsapp_account_statement_template text,
  add column if not exists whatsapp_share_account_template text,
  add column if not exists created_at timestamptz default now(),
  add column if not exists updated_at timestamptz default now();

create unique index if not exists app_settings_user_id_unique_idx
  on public.app_settings(user_id)
  where user_id is not null;

-- 3) Copy any old shared settings row into per-user settings rows
do $$
declare
  v_shared record;
begin
  select *
  into v_shared
  from public.app_settings
  where user_id is null
  order by updated_at desc nulls last, id
  limit 1;

  if v_shared is null then
    insert into public.app_settings (id, shop_name, created_at, updated_at)
    values ('00000000-0000-0000-0000-000000000000', 'ArtiCode', now(), now())
    on conflict (id) do nothing;

    select *
    into v_shared
    from public.app_settings
    where id = '00000000-0000-0000-0000-000000000000'
    limit 1;
  end if;

  insert into public.app_settings (
    id,
    user_id,
    shop_name,
    shop_logo,
    shop_phone,
    shop_address,
    selected_receipt_logo,
    header_layout,
    header_primary_color,
    shop_name_en,
    shop_phone_en,
    shop_address_en,
    whatsapp_account_statement_template,
    whatsapp_share_account_template,
    created_at,
    updated_at
  )
  select
    gen_random_uuid(),
    u.id,
    coalesce(v_shared.shop_name, 'ArtiCode'),
    v_shared.shop_logo,
    v_shared.shop_phone,
    v_shared.shop_address,
    v_shared.selected_receipt_logo,
    coalesce(v_shared.header_layout, 'centered'),
    coalesce(v_shared.header_primary_color, '#4F46E5'),
    v_shared.shop_name_en,
    v_shared.shop_phone_en,
    v_shared.shop_address_en,
    v_shared.whatsapp_account_statement_template,
    v_shared.whatsapp_share_account_template,
    coalesce(v_shared.created_at, now()),
    now()
  from public.app_security u
  where not exists (
    select 1 from public.app_settings s where s.user_id = u.id
  );
end $$;

-- 4) Helper function used by the app to fetch/create current-user settings
create or replace function public.get_or_create_user_settings(p_user_id uuid)
returns public.app_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.app_settings;
begin
  select *
  into v_settings
  from public.app_settings
  where user_id = p_user_id
  limit 1;

  if found then
    return v_settings;
  end if;

  insert into public.app_settings (
    user_id,
    shop_name,
    header_layout,
    header_primary_color,
    created_at,
    updated_at
  ) values (
    p_user_id,
    'ArtiCode',
    'centered',
    '#4F46E5',
    now(),
    now()
  )
  returning * into v_settings;

  return v_settings;
end;
$$;

-- 5) Make app_settings private per user instead of globally shared
alter table public.app_settings enable row level security;

drop policy if exists "Allow all operations on app_settings" on public.app_settings;
drop policy if exists "Allow anon and authenticated users full access to app_settings" on public.app_settings;
drop policy if exists "Allow read access to app_settings" on public.app_settings;
drop policy if exists "Allow update access to app_settings" on public.app_settings;
drop policy if exists "Allow insert access to app_settings" on public.app_settings;
drop policy if exists "Allow app settings read" on public.app_settings;
drop policy if exists "Allow app settings update" on public.app_settings;
drop policy if exists "Users can read own app settings" on public.app_settings;
drop policy if exists "Users can insert own app settings" on public.app_settings;
drop policy if exists "Users can update own app settings" on public.app_settings;

create policy "Users can read own app settings"
  on public.app_settings for select
  to anon, authenticated
  using (
    user_id = (
      select id
      from public.app_security
      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))
      limit 1
    )
    or exists (
      select 1
      from public.app_security
      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))
        and role = 'admin'
    )
  );

create policy "Users can insert own app settings"
  on public.app_settings for insert
  to anon, authenticated
  with check (
    user_id = (
      select id
      from public.app_security
      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))
      limit 1
    )
    or exists (
      select 1
      from public.app_security
      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))
        and role = 'admin'
    )
  );

create policy "Users can update own app settings"
  on public.app_settings for update
  to anon, authenticated
  using (
    user_id = (
      select id
      from public.app_security
      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))
      limit 1
    )
    or exists (
      select 1
      from public.app_security
      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))
        and role = 'admin'
    )
  )
  with check (
    user_id = (
      select id
      from public.app_security
      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))
      limit 1
    )
    or exists (
      select 1
      from public.app_security
      where lower(user_name) = lower(coalesce(current_setting('app.current_user', true), ''))
        and role = 'admin'
    )
  );

-- 6) Keep delete_user_by_id free from Ali-specific restrictions
create or replace function public.delete_user_by_id(p_user_id uuid)
returns json
language plpgsql
as $$
declare
  v_user_name text;
  v_result json;
begin
  select user_name into v_user_name
  from public.app_security
  where id = p_user_id;

  if v_user_name is null then
    return json_build_object(
      'success', false,
      'message', 'المستخدم غير موجود'
    );
  end if;

  delete from public.app_security where id = p_user_id;

  v_result := json_build_object(
    'success', true,
    'message', 'تم حذف المستخدم بنجاح',
    'user_name', v_user_name
  );

  return v_result;
end;
$$;

commit;
