-- Phase 1.2: search_run
-- One incremental SearchProvider batch call (PLAN.md sec.9,14, CONTRACT.md sec.26-29,34).
-- Not part of Phase 0A's entity list (PLAN.md sec.27) -- it belongs to Phase 1.2's
-- budgeted-discovery scope. Mutable (state progresses RUNNING -> COMPLETED/FAILED as the
-- batch executes), unlike the append-only evaluation/profile_snapshot tables.

create table if not exists search_run (
  id uuid primary key default extensions.gen_random_uuid(),
  campaign_id uuid not null references campaign (id) on delete restrict,
  campaign_revision_id uuid not null references campaign_revision (id) on delete restrict,
  provider text not null,
  provider_run_id text,
  cursor_before text,
  cursor_after text,
  raw_count integer not null default 0 check (raw_count >= 0),
  unique_count integer not null default 0 check (unique_count >= 0),
  new_candidate_count integer not null default 0 check (new_candidate_count >= 0),
  estimated_cost_usd numeric,
  actual_cost_usd numeric,
  provider_exhausted boolean not null default false,
  state text not null default 'RUNNING' check (state in ('RUNNING', 'COMPLETED', 'FAILED')),
  stop_reason text check (
    stop_reason is null or stop_reason in (
      'STOP_MAX_UNIQUE_CANDIDATES', 'STOP_SEARCH_COST_LIMIT', 'STOP_TOTAL_CAMPAIGN_COST_LIMIT',
      'STOP_QUALIFIED_TARGET_REACHED', 'STOP_PROVIDER_EXHAUSTED', 'STOP_MANUAL'
    )
  ),
  trace_id text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  error_code text,
  error_message text,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists search_run_campaign_id_idx on search_run (campaign_id);
create index if not exists search_run_campaign_revision_id_idx on search_run (campaign_revision_id);
create index if not exists search_run_trace_id_idx on search_run (trace_id);

-- As noted in the Phase 0A evaluation migration: a real paid search batch is an earlier
-- real use of a CampaignRevision than an Evaluation is, in the full pipeline. Reuse the
-- same generic freeze-on-insert function (it only depends on a campaign_revision_id
-- column, nothing evaluation-specific, despite its name).
create trigger search_run_before_insert_freeze_revision
before insert on search_run
for each row execute function evaluation_freeze_revision_on_insert();

comment on table search_run is
  'One incremental SearchProvider batch call, durable per CONTRACT.md sec.26-29,34.';
