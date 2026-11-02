-- WorkGuide v1.1 — personalized access, groups, assignments, and dual sign-off
-- Apply AFTER workguide_schema.sql in Supabase SQL Editor.
-- Review with your database administrator before production use.

create type public.document_visibility as enum ('company','assigned','restricted');

alter table public.documents
  add column if not exists visibility public.document_visibility not null default 'company';

-- Flexible work groups (not departments). A person can belong to multiple groups.
create table public.employee_groups (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  description text,
  created_by uuid references public.employees(id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(company_id, id),
  unique(company_id, name)
);

create table public.employee_group_members (
  company_id uuid not null references public.companies(id) on delete cascade,
  group_id uuid not null,
  employee_id uuid not null,
  added_at timestamptz not null default now(),
  primary key(group_id, employee_id),
  foreign key(company_id, group_id) references public.employee_groups(company_id, id) on delete cascade,
  foreign key(company_id, employee_id) references public.employees(company_id, id) on delete cascade
);

-- A training campaign is the manager's one action to assign a skill/procedure
-- to one employee, selected employees, a group, or the whole company.
create table public.training_campaigns (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  instructions text,
  skill_id uuid not null,
  linked_document_id uuid,
  document_version_id uuid,
  assigned_by uuid not null,
  due_date date,
  target_type text not null check (target_type in ('employee','group','company','selected_employees')),
  created_at timestamptz not null default now(),
  foreign key(company_id, skill_id) references public.skills(company_id, id) on delete restrict,
  foreign key(company_id, linked_document_id) references public.documents(company_id, id) on delete restrict,
  foreign key(company_id, document_version_id) references public.document_versions(company_id, id) on delete restrict,
  foreign key(company_id, assigned_by) references public.employees(company_id, id) on delete restrict,
  unique(company_id, id)
);

create table public.training_campaign_employees (
  company_id uuid not null references public.companies(id) on delete cascade,
  campaign_id uuid not null,
  employee_id uuid not null,
  source_group_id uuid,
  assignment_id uuid,
  added_at timestamptz not null default now(),
  primary key(campaign_id, employee_id),
  foreign key(company_id, campaign_id) references public.training_campaigns(company_id, id) on delete cascade,
  foreign key(company_id, employee_id) references public.employees(company_id, id) on delete cascade,
  foreign key(company_id, source_group_id) references public.employee_groups(company_id, id) on delete restrict,
  foreign key(company_id, assignment_id) references public.training_assignments(company_id, id) on delete set null
);

-- Acknowledgement is separate from trainer approval so each party has a distinct,
-- timestamped record. A typed name is not a cryptographic signature; production
-- should bind this action to the authenticated account and retain audit metadata.
create table public.training_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  signoff_id uuid not null,
  employee_id uuid not null,
  acknowledgement_text text not null,
  acknowledged_at timestamptz not null default now(),
  auth_user_id uuid not null references auth.users(id),
  foreign key(company_id, signoff_id) references public.training_signoffs(company_id, id) on delete restrict,
  foreign key(company_id, employee_id) references public.employees(company_id, id) on delete restrict,
  unique(signoff_id)
);

-- Document-level audience grants. Assigned users/groups can see assigned-only
-- documents; restricted documents require an explicit grant.
create table public.document_employee_access (
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null,
  employee_id uuid not null,
  granted_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(document_id, employee_id),
  foreign key(company_id, document_id) references public.documents(company_id, id) on delete cascade,
  foreign key(company_id, employee_id) references public.employees(company_id, id) on delete cascade
);

create table public.document_group_access (
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null,
  group_id uuid not null,
  granted_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(document_id, group_id),
  foreign key(company_id, document_id) references public.documents(company_id, id) on delete cascade,
  foreign key(company_id, group_id) references public.employee_groups(company_id, id) on delete cascade
);

create index group_members_employee_idx on public.employee_group_members(company_id, employee_id);
create index campaign_employees_employee_idx on public.training_campaign_employees(company_id, employee_id);
create index campaigns_due_idx on public.training_campaigns(company_id, due_date);
create index doc_employee_access_idx on public.document_employee_access(company_id, employee_id);

-- Helper used by RLS: manager/supervisor can see organization-wide training data.
create or replace function public.is_training_manager()
returns boolean language sql stable security definer set search_path = public
as $$
  select public.has_role(array['admin','supervisor']::public.employee_role[])
$$;

-- Replace broad policies from v1 with per-user policies.
drop policy if exists "employees read training assignments" on public.training_assignments;
drop policy if exists "managers manage training assignments" on public.training_assignments;
create policy "employees see own assignments managers see all"
on public.training_assignments for select
using (
  company_id = public.current_company_id()
  and (employee_id = (public.current_employee()).id or public.is_training_manager())
);
create policy "managers create and manage assignments"
on public.training_assignments for all
using (company_id = public.current_company_id() and public.is_training_manager())
with check (company_id = public.current_company_id() and public.is_training_manager());

drop policy if exists "employees read training signoffs" on public.training_signoffs;
create policy "employee and managers read signoffs"
on public.training_signoffs for select
using (
  company_id = public.current_company_id()
  and (employee_id = (public.current_employee()).id or public.is_training_manager())
);

-- Keep trainer approval restricted to authorized managers/supervisors.
drop policy if exists "authorized trainers create signoffs" on public.training_signoffs;
create policy "managers create trainer signoffs"
on public.training_signoffs for insert
with check (company_id = public.current_company_id() and public.is_training_manager());

-- Employee can acknowledge only their own sign-off, and the auth identity must match.
alter table public.training_acknowledgements enable row level security;
create policy "employee sees own acknowledgement managers see all"
on public.training_acknowledgements for select
using (
  company_id = public.current_company_id()
  and (employee_id = (public.current_employee()).id or public.is_training_manager())
);
create policy "employee acknowledges own training"
on public.training_acknowledgements for insert
with check (
  company_id = public.current_company_id()
  and employee_id = (public.current_employee()).id
  and auth_user_id = auth.uid()
);

-- Groups and group membership: all employees can see group names/members only if
-- the product chooses to show team membership; only managers administer groups.
alter table public.employee_groups enable row level security;
alter table public.employee_group_members enable row level security;
create policy "members read own company groups" on public.employee_groups
for select using (company_id = public.current_company_id());
create policy "managers manage groups" on public.employee_groups
for all using (company_id = public.current_company_id() and public.is_training_manager())
with check (company_id = public.current_company_id() and public.is_training_manager());
create policy "members read company group membership" on public.employee_group_members
for select using (company_id = public.current_company_id());
create policy "managers manage group membership" on public.employee_group_members
for all using (company_id = public.current_company_id() and public.is_training_manager())
with check (company_id = public.current_company_id() and public.is_training_manager());

-- Campaigns are visible to managers and employees targeted by the campaign.
alter table public.training_campaigns enable row level security;
alter table public.training_campaign_employees enable row level security;
create policy "campaign visible to managers or targeted employee"
on public.training_campaigns for select
using (
  company_id = public.current_company_id()
  and (
    public.is_training_manager()
    or exists (
      select 1 from public.training_campaign_employees ce
      where ce.company_id = training_campaigns.company_id
        and ce.campaign_id = training_campaigns.id
        and ce.employee_id = (public.current_employee()).id
    )
  )
);
create policy "managers manage campaigns" on public.training_campaigns
for all using (company_id = public.current_company_id() and public.is_training_manager())
with check (company_id = public.current_company_id() and public.is_training_manager());
create policy "employee sees own campaign membership managers see all"
on public.training_campaign_employees for select
using (
  company_id = public.current_company_id()
  and (employee_id = (public.current_employee()).id or public.is_training_manager())
);
create policy "managers manage campaign recipients"
on public.training_campaign_employees for all
using (company_id = public.current_company_id() and public.is_training_manager())
with check (company_id = public.current_company_id() and public.is_training_manager());

-- Document audience access.
alter table public.document_employee_access enable row level security;
alter table public.document_group_access enable row level security;
create policy "employee reads own document grants managers read all"
on public.document_employee_access for select
using (company_id = public.current_company_id()
  and (employee_id = (public.current_employee()).id or public.is_training_manager()));
create policy "managers manage employee document grants"
on public.document_employee_access for all
using (company_id = public.current_company_id() and public.is_training_manager())
with check (company_id = public.current_company_id() and public.is_training_manager());
create policy "company members read group document grants"
on public.document_group_access for select
using (company_id = public.current_company_id());
create policy "managers manage group document grants"
on public.document_group_access for all
using (company_id = public.current_company_id() and public.is_training_manager())
with check (company_id = public.current_company_id() and public.is_training_manager());

-- Replace v1's company-wide document SELECT with visibility-aware access.
drop policy if exists "members read documents" on public.documents;
create policy "employees see documents allowed for them"
on public.documents for select
using (
  company_id = public.current_company_id()
  and (
    public.is_training_manager()
    or (
      status = 'published'
      and (
        visibility = 'company'
        or exists (
          select 1 from public.document_employee_access dea
          where dea.company_id = documents.company_id
            and dea.document_id = documents.id
            and dea.employee_id = (public.current_employee()).id
        )
        or exists (
          select 1 from public.document_group_access dga
          join public.employee_group_members egm
            on egm.company_id = dga.company_id and egm.group_id = dga.group_id
          where dga.company_id = documents.company_id
            and dga.document_id = documents.id
            and egm.employee_id = (public.current_employee()).id
        )
      )
    )
    or (
      status = 'draft'
      and created_by = (public.current_employee()).id
    )
  )
);

-- Production implementation must expand campaign targets into individual assignments
-- transactionally on the server. Do not trust the browser to select recipients or set
-- company_id. The server function should snapshot group membership at assignment time.
