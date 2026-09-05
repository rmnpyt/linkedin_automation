-- Phase 0A: contact_point
-- Contact information for a Person, modeled independently from Person and ExternalProfile
-- (CONTRACT.md sec.37). A Person may have multiple ContactPoints. Initial type: email.

create table if not exists contact_point (
  id uuid primary key default extensions.gen_random_uuid(),
  person_id uuid not null references person (id) on delete restrict,
  type text not null check (type in ('email')),
  value text not null,
  normalized_value text not null,
  source_provider text not null,
  verification_status text not null default 'UNVERIFIED'
    check (verification_status in (
      'UNVERIFIED', 'PROVIDER_VERIFIED', 'VERIFIED', 'INVALID', 'STALE'
    )),
  confidence numeric,
  discovered_at timestamptz not null default now(),
  last_verified_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Trivial duplicate contact points for the same Person/type/normalized value are prevented
-- (CONTRACT.md sec.37).
create unique index if not exists contact_point_person_type_normalized_key
  on contact_point (person_id, type, normalized_value);

create index if not exists contact_point_person_id_idx on contact_point (person_id);

create trigger contact_point_set_updated_at
before update on contact_point
for each row execute function set_updated_at();

comment on table contact_point is
  'Contact information for a Person, independent of platform identity (CONTRACT.md sec.37).';
