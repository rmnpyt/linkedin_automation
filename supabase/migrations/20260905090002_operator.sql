-- Phase 0A: operator
-- Represents a person operating the system; owns campaigns and content context (PLAN.md sec.10).

create table if not exists operator (
  id uuid primary key default extensions.gen_random_uuid(),
  display_name text not null,
  primary_goal text,
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'INACTIVE')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger operator_set_updated_at
before update on operator
for each row execute function set_updated_at();

comment on table operator is
  'A person operating the system; owns campaigns and content context (PLAN.md sec.10). Intentionally has no rigid goal enum (MINDSET.md sec.4).';
