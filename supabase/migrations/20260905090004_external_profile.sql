-- Phase 0A: external_profile
-- Platform identity for a Person (initially LinkedIn), separate from Person (CONTRACT.md sec.11).
-- Identity resolution prefers a stable external_id, then a canonicalized profile URL.
-- Name-only automatic merging is never allowed (CONTRACT.md sec.10).

create table if not exists external_profile (
  id uuid primary key default extensions.gen_random_uuid(),
  person_id uuid not null references person (id) on delete restrict,
  platform text not null,
  external_id text,
  canonical_url text,
  username text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint external_profile_identity_present check (
    external_id is not null or canonical_url is not null
  )
);

-- Prefer a stable platform id when the provider supplies one.
create unique index if not exists external_profile_platform_external_id_key
  on external_profile (platform, external_id)
  where external_id is not null;

-- Fall back to a canonicalized URL. Callers are expected to normalize (scheme/host/
-- trailing-slash/query-string) before insert; this constraint does not itself normalize.
create unique index if not exists external_profile_platform_canonical_url_key
  on external_profile (platform, canonical_url)
  where canonical_url is not null;

create index if not exists external_profile_person_id_idx on external_profile (person_id);

create trigger external_profile_set_updated_at
before update on external_profile
for each row execute function set_updated_at();

comment on table external_profile is
  'Platform identity for a Person (initial platform: LinkedIn), separate from Person (CONTRACT.md sec.11).';
