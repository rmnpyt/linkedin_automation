-- Phase 0A: contact_enrichment_attempt
-- One ContactEnrichmentProvider call for a selected qualified candidate (CONTRACT.md
-- sec.36,39). NO_RESULT is a valid, non-blocking outcome -- missing email never blocks
-- LinkedIn connection flow in V1 (CONTRACT.md sec.40).

create table if not exists contact_enrichment_attempt (
  id uuid primary key default extensions.gen_random_uuid(),
  campaign_id uuid not null references campaign (id) on delete restrict,
  campaign_revision_id uuid not null references campaign_revision (id) on delete restrict,
  campaign_candidate_id uuid not null references campaign_candidate (id) on delete restrict,
  person_id uuid not null references person (id) on delete restrict,
  external_profile_id uuid not null references external_profile (id) on delete restrict,
  provider text not null,
  requested_contact_type text not null default 'email',
  state text not null default 'QUEUED'
    check (state in ('QUEUED', 'RUNNING', 'COMPLETED', 'NO_RESULT', 'FAILED', 'BUDGET_BLOCKED')),
  contacts_found integer not null default 0 check (contacts_found >= 0),
  estimated_cost_usd numeric,
  actual_cost_usd numeric,
  trace_id text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  error_code text,
  error_message text,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists contact_enrichment_attempt_campaign_id_idx on contact_enrichment_attempt (campaign_id);
create index if not exists contact_enrichment_attempt_campaign_revision_id_idx on contact_enrichment_attempt (campaign_revision_id);
create index if not exists contact_enrichment_attempt_campaign_candidate_id_idx on contact_enrichment_attempt (campaign_candidate_id);
create index if not exists contact_enrichment_attempt_trace_id_idx on contact_enrichment_attempt (trace_id);

comment on table contact_enrichment_attempt is
  'One ContactEnrichmentProvider call for a qualified candidate (CONTRACT.md sec.36,39). NO_RESULT is a valid, non-blocking outcome.';
