ALTER TABLE public.letterhead_settings
  ADD COLUMN IF NOT EXISTS english_name text NOT NULL DEFAULT 'Company Name',
  ADD COLUMN IF NOT EXISTS address_ar text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS address_en text NOT NULL DEFAULT '';