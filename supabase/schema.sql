-- CedCommerce Marketplace Acquisition Hub — full schema (v2.0.0, 2026-10)
-- Rebuilds the backend from scratch on a fresh Supabase project. Idempotent.
-- Supersedes schema_migration.sql (v1.1.0 delta) + the never-committed setup_schema_v4.sql.
--
-- Security model (enforced in Postgres, not just the UI):
--   * Only signed-in Google accounts on @threecolts.com can read anything (is_staff()).
--   * Writes need a team_permissions grant (editor flags) or super_admin.
--   * hsrivastava@threecolts.com is super_admin by exact match (never substring).

create extension if not exists pgcrypto;

-- ============================================================ core tables
create table if not exists programs (
  id               text primary key,
  name             text not null,
  market           text,
  region           text,
  incentive_amount numeric not null default 0,
  currency         text not null default 'USD',
  color            text,
  affiliate_link   text,
  notes            text,
  meta             jsonb not null default '{}',
  created_at       timestamptz not null default now()
);

create table if not exists sellers (
  id          text primary key default gen_random_uuid()::text,
  program_id  text not null references programs(id) on delete cascade,
  email       text,
  company     text,
  status      text,
  sources     text[] not null default '{}',
  associate   text,
  store_id    text,
  tags        text[] not null default '{}',
  phone       text,
  remarks     text,
  website     text,
  qualified   boolean not null default false,
  campaign    text,
  meta        jsonb not null default '{}',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_sellers_program on sellers(program_id);
create index if not exists idx_sellers_email on sellers(lower(email));
create index if not exists idx_sellers_store on sellers(store_id);

create table if not exists qualified_sellers (
  id               text primary key default gen_random_uuid()::text,
  program_id       text not null references programs(id) on delete cascade,
  store_name       text not null,
  email            text,
  store_id         text,
  bda              text,
  first_sale_month text,              -- 'YYYY-MM'
  amount           numeric,
  currency         text,
  temu_paid_ced    text not null default 'pending',   -- marketplace paid CedCommerce
  ced_paid_csa     text not null default 'pending',   -- CedCommerce paid the associate
  bd_incentive     text default 'pending',
  notes            text,
  created_at       timestamptz not null default now()
);
create index if not exists idx_qual_program on qualified_sellers(program_id);

create table if not exists payments (
  id           text primary key default gen_random_uuid()::text,
  program_id   text not null references programs(id) on delete cascade,
  period       text not null,          -- 'YYYY-MM'
  amount       numeric not null default 0,
  seller_count int not null default 0,
  received     boolean not null default false,
  stores_note  text,
  created_at   timestamptz not null default now()
);

create table if not exists campaigns (
  id            text primary key default gen_random_uuid()::text,
  program_id    text not null references programs(id) on delete cascade,
  name          text not null,
  campaign_date date,
  segment       text,
  sent          int not null default 0,
  opens         int not null default 0,
  clicks        int not null default 0,
  replies       int not null default 0,
  created_at    timestamptz not null default now()
);

create table if not exists team_permissions (
  email              text primary key check (email = lower(email)),
  role               text not null default 'viewer' check (role in ('viewer','editor','super_admin')),
  can_edit_sellers   boolean not null default false,
  can_edit_revenue   boolean not null default false,
  can_edit_campaigns boolean not null default false,
  can_import         boolean not null default false,
  created_at         timestamptz not null default now()
);

create table if not exists bd_associates (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists seller_statuses (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  market      text,                     -- null = shared by Temu programs; 'SHEIN' = SHEIN funnel
  color       text,
  order_index int not null default 0,
  created_at  timestamptz not null default now(),
  unique nulls not distinct (name, market)
);

create table if not exists email_templates (
  id         uuid primary key default gen_random_uuid(),
  status     text not null unique,
  subject    text not null,
  body       text not null,
  updated_at timestamptz not null default now()
);

create table if not exists audit_log (
  id          uuid primary key default gen_random_uuid(),
  user_email  text not null,
  action      text not null check (action in ('insert','update','delete','bulk_update')),
  table_name  text not null,
  record_id   text,
  before      jsonb,
  after       jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists idx_audit_log_created on audit_log(created_at desc);

-- SHEIN A/B brand list (confidential — staff-only via RLS, never a static asset)
create table if not exists ab_brands (
  brand_code        text primary key,
  brand_name        text not null,
  brand_norm        text not null,
  brand_level       text not null,      -- 'A' | 'B' | 'B-'
  tier              text not null,      -- 'A' | 'B'
  last_brand_level  text,
  level_update_date date,
  list_version      text not null default 'v4.29'
);
create index if not exists idx_ab_brands_norm on ab_brands(brand_norm);

-- ============================================================ auth helpers
create or replace function public.jwt_email() returns text
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function public.is_staff() returns boolean
language sql stable as $$
  select auth.role() = 'authenticated'
     and split_part(public.jwt_email(), '@', 2) = 'threecolts.com'
$$;

create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_staff() and (
    public.jwt_email() = 'hsrivastava@threecolts.com'
    or exists (select 1 from team_permissions t where t.email = public.jwt_email() and t.role = 'super_admin')
  )
$$;

create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super_admin() or (public.is_staff() and exists (
    select 1 from team_permissions t
    where t.email = public.jwt_email() and t.role = 'editor'
      and case p when 'sellers'   then t.can_edit_sellers
                 when 'revenue'   then t.can_edit_revenue
                 when 'campaigns' then t.can_edit_campaigns
                 when 'import'    then t.can_import
                 else false end))
$$;

-- ============================================================ RLS
do $$
declare t text;
begin
  foreach t in array array['programs','sellers','qualified_sellers','payments','campaigns','team_permissions',
                           'bd_associates','seller_statuses','email_templates','audit_log','ab_brands'] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
  end loop;
end $$;

-- drop + recreate policies so re-runs pick up changes
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy %I on %I', r.policyname, r.tablename);
  end loop;
end $$;

-- read: every staff member (this is the "view access" for anyone @threecolts.com)
create policy staff_read on programs          for select to authenticated using (public.is_staff());
create policy staff_read on sellers           for select to authenticated using (public.is_staff());
create policy staff_read on qualified_sellers for select to authenticated using (public.is_staff());
create policy staff_read on payments          for select to authenticated using (public.is_staff());
create policy staff_read on campaigns         for select to authenticated using (public.is_staff());
create policy staff_read on bd_associates     for select to authenticated using (public.is_staff());
create policy staff_read on seller_statuses   for select to authenticated using (public.is_staff());
create policy staff_read on email_templates   for select to authenticated using (public.is_staff());
create policy staff_read on ab_brands         for select to authenticated using (public.is_staff());
-- team_permissions: you can read your own row; super admins read all
create policy self_read  on team_permissions  for select to authenticated using (email = public.jwt_email() or public.is_super_admin());
create policy admin_read on audit_log         for select to authenticated using (public.is_super_admin());

-- writes
create policy sellers_ins on sellers for insert to authenticated with check (public.has_perm('sellers') or public.has_perm('import'));
create policy sellers_upd on sellers for update to authenticated using (public.has_perm('sellers') or public.has_perm('import') or public.has_perm('revenue'))
                                                             with check (public.has_perm('sellers') or public.has_perm('import') or public.has_perm('revenue'));
create policy sellers_del on sellers for delete to authenticated using (public.is_super_admin());

create policy rev_write on qualified_sellers for all to authenticated using (public.has_perm('revenue')) with check (public.has_perm('revenue'));
create policy rev_write on payments          for all to authenticated using (public.has_perm('revenue')) with check (public.has_perm('revenue'));
create policy camp_write on campaigns        for all to authenticated using (public.has_perm('campaigns')) with check (public.has_perm('campaigns'));

create policy admin_write on programs         for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy admin_write on team_permissions for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy admin_write on bd_associates    for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy admin_write on seller_statuses  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy admin_write on email_templates  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy admin_write on ab_brands        for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());

-- audit: any staff member may append rows attributed to themselves; nobody edits history
create policy audit_append on audit_log for insert to authenticated with check (public.is_staff() and user_email = public.jwt_email());

-- anon gets nothing: no policies for the anon role on any table.
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- ============================================================ seed: lookups
insert into team_permissions (email, role, can_edit_sellers, can_edit_revenue, can_edit_campaigns, can_import) values
  ('hsrivastava@threecolts.com', 'super_admin', true, true, true, true),
  ('kgupta@threecolts.com',      'super_admin', true, true, true, true)
on conflict (email) do nothing;

insert into bd_associates (name) values
  ('Sarina Sufiyan'), ('Suryansh Chauhan'), ('Nadeem Khan'), ('Shaim kumar'),
  ('Divyam Gupta'), ('Rishu Agarwal'), ('Shivangi Tiwari'), ('Aditi Sinha'),
  ('Mohd Fahad Khan'), ('Kartikey Mishra'), ('Raju Sah'), ('Yashi Rastogi'),
  ('Mohd Shadab'), ('Gaurav Mishra'), ('Abhijeet Srivastava'), ('Siddhartha Raj'),
  ('Yashwita'), ('Yogesh'), ('Akshay Singh'), ('Mobin Rana'),
  ('Sahil Pandey'), ('Khushi Bhasin'), ('Mannu Pratap Singh'),
  ('Dhruv Prashant'), ('Prashant Srivastava'), ('Harsh Singh'), ('Vishal Kumar Tyagi'),
  ('Hrithik Srivastava'), ('Abhinav Singh Dogra')
on conflict (name) do nothing;

insert into seller_statuses (name, market, order_index) values
  ('Opened', null, 2), ('Clicked', null, 4), ('Replied', null, 6),
  ('EMAIL FOLLOW UP IN PROGRESS', null, 10), ('WHATSAPP FOLLOW UP IN PROGRESS', null, 20),
  ('REGISTRATION DONE', null, 30), ('INCOMMUNICATION', null, 40), ('NOT INTERESTED', null, 50),
  ('STUCK', null, 60), ('Document Verification', null, 70), ('Payment Verification', null, 75),
  ('1st Sign Up Done', null, 80), ('Engagement', null, 90), ('Product Setup', null, 100),
  ('MANUAL LISTING IN PROGRESS', null, 110), ('LISTING VIA APP IN PROGRESS', null, 120),
  ('SALES AWAITING', null, 130), ('ONBOARDING COMPLETE', null, 140), ('APP CONNECTED', null, 150),
  ('FRAMEWORK NOT SUPPORTED', null, 160), ('Not eligible', null, 170),
  ('LEAD IDENTIFIED', 'SHEIN', 10), ('SCREENING (BRAND MATCH)', 'SHEIN', 20),
  ('QUALIFIED – PENDING OUTREACH', 'SHEIN', 30), ('OUTREACH IN PROGRESS', 'SHEIN', 40),
  ('INTERESTED', 'SHEIN', 50), ('APPLICATION IN PROGRESS', 'SHEIN', 60),
  ('BRAND AUTHORIZATION (INVOICES)', 'SHEIN', 70), ('APPROVED BY SHEIN', 'SHEIN', 80),
  ('LIVE (FIRST LISTING)', 'SHEIN', 90), ('FIRST SALE', 'SHEIN', 100),
  ('NOT QUALIFIED', 'SHEIN', 110), ('NOT INTERESTED', 'SHEIN', 120)
on conflict (name, market) do nothing;

insert into email_templates (status, subject, body) values
  ('EMAIL FOLLOW UP IN PROGRESS',
   'Grow your sales on Temu — exclusive programme via CedCommerce',
   E'Hi [NAME],\n\nI am reaching out from CedCommerce regarding a funded seller programme on Temu that we are running.\n\nWe help sellers list their products on Temu with free onboarding, product listing support, and a dedicated account manager throughout.\n\nCould we have a quick 15-minute call this week to walk you through the details?\n\nBest,\n[YOUR NAME]\nCedCommerce'),
  ('DEFAULT',
   'Following up — your onboarding',
   E'Hi [NAME],\n\nI am following up from CedCommerce regarding your marketplace onboarding. Please let me know if there is anything I can help with.\n\nBest,\n[YOUR NAME]\nCedCommerce')
on conflict (status) do nothing;
