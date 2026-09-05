-- Phase 0A: profile_snapshot
-- Point-in-time evidence for an ExternalProfile (CONTRACT.md sec.12). Every evaluation MUST
-- reference the exact snapshot it was based on. Historical snapshots are never destructively
-- overwritten -- this table is append-only at the database level.

create table if not exists profile_snapshot (
  id uuid primary key default extensions.gen_random_uuid(),
  external_profile_id uuid not null references external_profile (id) on delete restrict,
  source_provider text not null,
  raw_data jsonb not null,
  normalized_data jsonb not null,
  captured_at timestamptz not null default now(),
  source_reference text,
  trace_id text,
  created_at timestamptz not null default now()
);

create index if not exists profile_snapshot_external_profile_id_idx on profile_snapshot (external_profile_id);
create index if not exists profile_snapshot_captured_at_idx on profile_snapshot (captured_at);
create index if not exists profile_snapshot_trace_id_idx on profile_snapshot (trace_id);

create trigger profile_snapshot_append_only
before update or delete on profile_snapshot
for each row execute function reject_mutation();

comment on table profile_snapshot is
  'Point-in-time evidence for an ExternalProfile (CONTRACT.md sec.12). Append-only: a new snapshot is inserted rather than an old one edited.';
