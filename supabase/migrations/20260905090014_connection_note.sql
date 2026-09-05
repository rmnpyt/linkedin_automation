-- Phase 0A: connection_note
-- Durable, versioned outreach note tied to the exact authorizing Evaluation (CONTRACT.md
-- sec.41.1). Immutability once referenced by a connection_attempt is enforced in the
-- connection_attempt migration, since that trigger needs connection_attempt to exist.

create table if not exists connection_note (
  id uuid primary key default extensions.gen_random_uuid(),
  connection_id uuid not null references connection (id) on delete restrict,
  campaign_candidate_id uuid not null references campaign_candidate (id) on delete restrict,
  campaign_revision_id uuid not null references campaign_revision (id) on delete restrict,
  evaluation_id uuid not null references evaluation (id) on delete restrict,
  body text not null,
  model_provider text,
  model_name text,
  prompt_version text,
  trace_id text,
  created_at timestamptz not null default now(),
  superseded_at timestamptz
);

create index if not exists connection_note_connection_id_idx on connection_note (connection_id);
create index if not exists connection_note_campaign_candidate_id_idx on connection_note (campaign_candidate_id);
create index if not exists connection_note_evaluation_id_idx on connection_note (evaluation_id);

comment on table connection_note is
  'Durable, versioned outreach note tied to the exact authorizing Evaluation (CONTRACT.md sec.41.1). Immutable once referenced by a connection_attempt, except for superseded_at.';
