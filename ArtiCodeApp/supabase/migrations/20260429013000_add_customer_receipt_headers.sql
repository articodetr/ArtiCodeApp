alter table public.customers
  add column if not exists receipt_header_mode text not null default 'default'
    check (receipt_header_mode in ('default', 'full_banner', 'generated')),
  add column if not exists receipt_header_banner_url text null,
  add column if not exists receipt_header_logo_url text null,
  add column if not exists receipt_header_left_title text null,
  add column if not exists receipt_header_left_subtitle text null,
  add column if not exists receipt_header_right_title text null,
  add column if not exists receipt_header_right_subtitle text null,
  add column if not exists receipt_header_primary_color text null default '#0F766E',
  add column if not exists receipt_header_secondary_color text null default '#115E59',
  add column if not exists receipt_header_text_color text null default '#FFFFFF';

comment on column public.customers.receipt_header_mode is 'default | full_banner | generated';
comment on column public.customers.receipt_header_banner_url is 'Full uploaded customer banner URL';
comment on column public.customers.receipt_header_logo_url is 'Centered logo URL for generated banner';
