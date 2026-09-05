-- Phase 0A: person
-- A real-world individual, independent of any Campaign or platform (CONTRACT.md sec.10, sec.245).

create table if not exists person (
  id uuid primary key default extensions.gen_random_uuid(),
  display_name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger person_set_updated_at
before update on person
for each row execute function set_updated_at();

comment on table person is
  'A real-world individual, independent of any Campaign or platform. Kept intentionally small (PLAN.md sec.10).';
