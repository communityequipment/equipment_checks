-- Ward Equipment Checks – database schema
-- Run this first in Supabase: SQL Editor > New query > paste > Run.
-- Then run seed.sql.

create extension if not exists pgcrypto;

-- A checklist = one piece of equipment (Homebirth bag now; resus trolley etc. later)
create table checklists (
  id             uuid primary key default gen_random_uuid(),
  slug           text unique not null,
  name           text not null,
  description    text,
  due_every_days numeric not null default 4,   -- "twice a week" = overdue after 4 days
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

create table checklist_items (
  id              uuid primary key default gen_random_uuid(),
  checklist_id    uuid not null references checklists(id) on delete cascade,
  position        int  not null,                -- order shown on the check screen
  section         text not null,                -- pocket / pouch / box
  label           text not null,
  requires_expiry boolean not null default false,
  active          boolean not null default true,
  unique (checklist_id, position)
);

-- One row per completed check
create table checks (
  id            uuid primary key default gen_random_uuid(),
  checklist_id  uuid not null references checklists(id),
  check_type    text not null check (check_type in ('routine', 'after_use')),
  checked_by    text not null,
  completed_at  timestamptz not null default now(),
  items_missing int  not null default 0,
  notes         text
);

-- One row per item per check
create table check_results (
  id          uuid primary key default gen_random_uuid(),
  check_id    uuid not null references checks(id) on delete cascade,
  item_id     uuid not null references checklist_items(id),
  status      text not null check (status in ('present', 'restocked', 'missing')),
  expiry_date date,
  note        text
);

-- "Bag has been used" reports – flags the bag as needing a check
create table usage_events (
  id           uuid primary key default gen_random_uuid(),
  checklist_id uuid not null references checklists(id),
  reported_by  text not null check (length(trim(reported_by)) > 0),
  reported_at  timestamptz not null default now(),
  note         text
);

create index on checks (checklist_id, completed_at desc);
create index on check_results (check_id);
create index on usage_events (checklist_id, reported_at desc);

-- Submits a whole check in one go (all-or-nothing) and insists every item is recorded
create or replace function submit_check(
  p_checklist_id uuid, p_check_type text, p_checked_by text, p_notes text, p_results jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_missing int;
  v_expected int;
begin
  if coalesce(trim(p_checked_by), '') = '' then
    raise exception 'Please enter your name';
  end if;

  select count(*) into v_expected
  from checklist_items where checklist_id = p_checklist_id and active;

  if jsonb_array_length(p_results) <> v_expected then
    raise exception 'Every item must be checked (% of % recorded)', jsonb_array_length(p_results), v_expected;
  end if;

  select count(*) into v_missing
  from jsonb_array_elements(p_results) r where r->>'status' = 'missing';

  insert into checks (checklist_id, check_type, checked_by, notes, items_missing)
  values (p_checklist_id, p_check_type, trim(p_checked_by), nullif(trim(p_notes), ''), v_missing)
  returning id into v_id;

  insert into check_results (check_id, item_id, status, expiry_date, note)
  select v_id, (r->>'item_id')::uuid, r->>'status',
         nullif(r->>'expiry_date', '')::date, nullif(trim(r->>'note'), '')
  from jsonb_array_elements(p_results) r;

  return v_id;
end $$;

-- Dashboard summary: latest check and latest use for each checklist
create or replace view checklist_status with (security_invoker = true) as
select c.id, c.slug, c.name, c.description, c.due_every_days,
       lc.completed_at  as last_check_at,
       lc.checked_by    as last_checked_by,
       lc.check_type    as last_check_type,
       lc.items_missing as last_items_missing,
       lu.reported_at   as last_used_at,
       lu.reported_by   as last_used_by,
       (select min(cr.expiry_date) from check_results cr
         where cr.check_id = lc.id and cr.expiry_date is not null) as soonest_expiry
from checklists c
left join lateral (select * from checks k where k.checklist_id = c.id
                   order by k.completed_at desc limit 1) lc on true
left join lateral (select * from usage_events u where u.checklist_id = c.id
                   order by u.reported_at desc limit 1) lu on true
where c.active;

-- Security: anyone with the page can READ and SUBMIT, but nobody can edit or delete records
alter table checklists      enable row level security;
alter table checklist_items enable row level security;
alter table checks          enable row level security;
alter table check_results   enable row level security;
alter table usage_events    enable row level security;

create policy "read checklists" on checklists      for select using (true);
create policy "read items"      on checklist_items for select using (true);
create policy "read checks"     on checks          for select using (true);
create policy "read results"    on check_results   for select using (true);
create policy "read usage"      on usage_events    for select using (true);
create policy "report usage"    on usage_events    for insert with check (true);

grant select on checklist_status to anon, authenticated;
grant execute on function submit_check(uuid, text, text, text, jsonb) to anon, authenticated;
