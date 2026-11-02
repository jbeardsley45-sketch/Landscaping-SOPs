-- WorkGuide v1 — Supabase PostgreSQL schema
-- Run in a NEW Supabase project's SQL Editor.
-- This establishes tenant-aware data tables and RLS.
-- Authentication provisioning (email-less username/password and device PIN)
-- must be implemented server-side with Supabase Edge Functions before production.

create extension if not exists pgcrypto;

create type public.employee_role as enum ('admin','supervisor','contributor','viewer');
create type public.document_status as enum ('draft','published','archived');
create type public.media_type as enum ('photo','video','file');

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  company_code text not null unique,
  name text not null,
  logo_path text,
  default_language text not null default 'en' check (default_language in ('en','es')),
  created_at timestamptz not null default now()
);

create table public.employees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  username text not null,
  display_name text not null,
  preferred_language text not null default 'en' check (preferred_language in ('en','es')),
  role public.employee_role not null default 'viewer',
  is_active boolean not null default true,
  must_change_password boolean not null default true,
  created_at timestamptz not null default now(),
  last_login_at timestamptz,
  unique(company_id, username),
  unique(company_id, id)
);

create table public.account_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  requested_username text not null,
  requested_name text not null,
  preferred_language text not null default 'es' check (preferred_language in ('en','es')),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.employees(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  parent_id uuid,
  name_en text not null,
  name_es text,
  icon text not null default '📁',
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  foreign key(company_id, parent_id) references public.categories(company_id, id) on delete restrict,
  unique(company_id, id)
);

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  category_id uuid,
  title text not null,
  equipment text,
  document_code text,
  status public.document_status not null default 'draft',
  created_by uuid references public.employees(id) on delete set null,
  current_revision integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  foreign key(company_id, category_id) references public.categories(company_id, id) on delete restrict
);

create table public.document_versions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null,
  revision integer not null,
  title_en text not null,
  title_es text,
  summary_en text,
  summary_es text,
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  unique(document_id, revision),
  foreign key(company_id, document_id) references public.documents(company_id, id) on delete cascade
);

create table public.document_steps (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  version_id uuid not null references public.document_versions(id) on delete cascade,
  step_number integer not null,
  title_en text,
  title_es text,
  instruction_en text,
  instruction_es text,
  caution_en text,
  caution_es text,
  created_at timestamptz not null default now(),
  unique(version_id, step_number),
  unique(company_id, id)
);

create table public.media_assets (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  storage_path text not null,
  media_kind public.media_type not null,
  original_filename text,
  mime_type text,
  byte_size bigint,
  thumbnail_path text,
  uploaded_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(company_id, storage_path),
  unique(company_id, id)
);

create table public.step_media (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  step_id uuid not null,
  media_id uuid not null,
  caption_en text,
  caption_es text,
  sort_order integer not null default 0,
  unique(step_id, media_id),
  foreign key(company_id, step_id) references public.document_steps(company_id, id) on delete cascade,
  foreign key(company_id, media_id) references public.media_assets(company_id, id) on delete cascade
);

create table public.tags (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  unique(company_id, name),
  unique(company_id, id)
);

create table public.document_tags (
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null,
  tag_id uuid not null,
  primary key(document_id, tag_id),
  foreign key(company_id, document_id) references public.documents(company_id, id) on delete cascade,
  foreign key(company_id, tag_id) references public.tags(company_id, id) on delete cascade
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index documents_company_status_idx on public.documents(company_id, status);
create index documents_category_idx on public.documents(company_id, category_id);
create index document_steps_version_idx on public.document_steps(version_id, step_number);
create index audit_log_company_date_idx on public.audit_log(company_id, created_at desc);

-- Helper: resolve the signed-in Supabase Auth user to their active employee record.
create or replace function public.current_employee()
returns public.employees
language sql stable security definer
set search_path = public
as $$
  select e.* from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active = true
  limit 1
$$;

create or replace function public.current_company_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select e.company_id from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active = true
  limit 1
$$;

create or replace function public.has_role(allowed public.employee_role[])
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.employees e
    where e.auth_user_id = auth.uid()
      and e.is_active = true
      and e.role = any(allowed)
  )
$$;

-- Enable RLS on every tenant-owned table.
alter table public.companies enable row level security;
alter table public.employees enable row level security;
alter table public.account_requests enable row level security;
alter table public.categories enable row level security;
alter table public.documents enable row level security;
alter table public.document_versions enable row level security;
alter table public.document_steps enable row level security;
alter table public.media_assets enable row level security;
alter table public.step_media enable row level security;
alter table public.tags enable row level security;
alter table public.document_tags enable row level security;
alter table public.audit_log enable row level security;

-- Company members can read their own company. Only admins update company settings.
create policy "company members read own company" on public.companies
for select using (id = public.current_company_id());
create policy "admins update own company" on public.companies
for update using (id = public.current_company_id() and public.has_role(array['admin']::public.employee_role[]))
with check (id = public.current_company_id());

create policy "employees read own company" on public.employees
for select using (company_id = public.current_company_id());
create policy "admins manage employees" on public.employees
for all using (company_id = public.current_company_id() and public.has_role(array['admin']::public.employee_role[]))
with check (company_id = public.current_company_id() and public.has_role(array['admin']::public.employee_role[]));

create policy "members read categories" on public.categories
for select using (company_id = public.current_company_id());
create policy "editors manage categories" on public.categories
for all using (company_id = public.current_company_id() and public.has_role(array['admin','supervisor']::public.employee_role[]))
with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor']::public.employee_role[]));

create policy "members read documents" on public.documents
for select using (company_id = public.current_company_id());
create policy "contributors create documents" on public.documents
for insert with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]));
create policy "contributors update documents" on public.documents
for update using (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]))
with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]));
create policy "admins supervisors delete documents" on public.documents
for delete using (company_id = public.current_company_id() and public.has_role(array['admin','supervisor']::public.employee_role[]));

-- Related records inherit the company boundary. Production workflow should additionally
-- restrict publishing and immutable version edits through server-side functions.
create policy "members read versions" on public.document_versions for select using (company_id = public.current_company_id());
create policy "editors create versions" on public.document_versions for insert with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]));
create policy "members read steps" on public.document_steps for select using (company_id = public.current_company_id());
create policy "editors manage steps" on public.document_steps for all using (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[])) with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]));
create policy "members read media" on public.media_assets for select using (company_id = public.current_company_id());
create policy "editors add media" on public.media_assets for insert with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]));
create policy "members read step media" on public.step_media for select using (company_id = public.current_company_id());
create policy "editors manage step media" on public.step_media for all using (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[])) with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]));
create policy "members read tags" on public.tags for select using (company_id = public.current_company_id());
create policy "editors manage tags" on public.tags for all using (company_id = public.current_company_id() and public.has_role(array['admin','supervisor']::public.employee_role[])) with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor']::public.employee_role[]));
create policy "members read document tags" on public.document_tags for select using (company_id = public.current_company_id());
create policy "editors manage document tags" on public.document_tags for all using (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[])) with check (company_id = public.current_company_id() and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]));
create policy "admins read audit log" on public.audit_log for select using (company_id = public.current_company_id() and public.has_role(array['admin']::public.employee_role[]));
create policy "authenticated users append audit log" on public.audit_log for insert with check (company_id = public.current_company_id());

-- Storage bucket is private. Upload/download policies must validate the company path prefix.
insert into storage.buckets (id, name, public, file_size_limit)
values ('workguide-media','workguide-media',false,524288000)
on conflict (id) do nothing;

create policy "company members read own media" on storage.objects
for select to authenticated
using (bucket_id = 'workguide-media' and (storage.foldername(name))[1] = public.current_company_id()::text);

create policy "contributors upload own company media" on storage.objects
for insert to authenticated
with check (bucket_id = 'workguide-media'
  and (storage.foldername(name))[1] = public.current_company_id()::text
  and public.has_role(array['admin','supervisor','contributor']::public.employee_role[]));

-- IMPORTANT implementation notes:
-- 1) Create companies and first admin through a trusted server-side provisioning function.
-- 2) Do not expose Supabase service-role keys in browser code.
-- 3) Username/password login without employee email should be implemented by an Edge Function:
--    resolve company_code + username to the auth identity, then exchange credentials securely.
--    Never verify passwords in client JavaScript or store plaintext passwords.
-- 4) Device PIN must be bound to an approved device/session and rate-limited server-side.
-- 5) Add storage UPDATE/DELETE policies and stricter document publishing/version immutability
--    before production rollout.
