-- Phase 0A: campaign
-- A long-lived acquisition objective. Holds stable identity/objective only -- material
-- execution configuration belongs to campaign_revision, never to campaign itself
-- (CONTRACT.md sec.13).

create table if not exists campaign (
  id uuid primary key default extensions.gen_random_uuid(),
  operator_id uuid not null references operator (id) on delete restrict,
  name text not null,
  objective text,
  state text not null default 'DRAFT'
    check (state in ('DRAFT', 'ACTIVE', 'PAUSED', 'COMPLETED', 'ARCHIVED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists campaign_operator_id_idx on campaign (operator_id);

create trigger campaign_set_updated_at
before update on campaign
for each row execute function set_updated_at();

comment on table campaign is
  'A long-lived acquisition objective; stable identity only, not mutable execution config (CONTRACT.md sec.13).';
