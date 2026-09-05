-- Phase 0A: evaluation
-- Historical, append-only KPI evaluation record (CONTRACT.md sec.18-25). Six KPIs; only
-- KPI 5 may be null under the framework's missing-data rule (KPI-FRAMEWORK.md, CONTRACT.md
-- sec.20-20.1). Missing evidence for KPI 1/2/3/4/6 makes the evaluation status = INCOMPLETE
-- rather than fabricating a score or silently qualifying the candidate.

create table if not exists evaluation (
  id uuid primary key default extensions.gen_random_uuid(),
  campaign_candidate_id uuid not null references campaign_candidate (id) on delete restrict,
  campaign_revision_id uuid not null references campaign_revision (id) on delete restrict,
  profile_snapshot_id uuid not null references profile_snapshot (id) on delete restrict,
  status text not null check (status in ('COMPLETE', 'INCOMPLETE', 'FAILED')),
  raw_judgment jsonb,
  score_adjustments jsonb,

  kpi_1_score integer check (kpi_1_score is null or (kpi_1_score between 0 and 100)),
  kpi_1_reason text,
  kpi_2_score integer check (kpi_2_score is null or (kpi_2_score between 0 and 100)),
  kpi_2_reason text,
  kpi_3_score integer check (kpi_3_score is null or (kpi_3_score between 0 and 100)),
  kpi_3_reason text,
  kpi_4_score integer check (kpi_4_score is null or (kpi_4_score between 0 and 100)),
  kpi_4_reason text,
  kpi_5_score integer check (kpi_5_score is null or (kpi_5_score between 0 and 100)),
  kpi_5_reason text,
  kpi_6_score integer check (kpi_6_score is null or (kpi_6_score between 0 and 100)),
  kpi_6_reason text,

  effective_weights jsonb,
  filter_results jsonb,
  composite_score numeric,
  hard_filter_passed boolean,
  qualified boolean,
  qualification_threshold numeric,

  model_provider text,
  model_name text,
  prompt_version text,
  rubric_version text,
  evaluation_version text,
  scoring_engine_version text,
  trace_id text,
  created_at timestamptz not null default now(),

  -- V1: only KPI 5 may be absent from a COMPLETE evaluation (CONTRACT.md sec.20.1).
  constraint evaluation_complete_requires_kpis check (
    status <> 'COMPLETE' or (
      kpi_1_score is not null and kpi_2_score is not null and kpi_3_score is not null
      and kpi_4_score is not null and kpi_6_score is not null
    )
  ),
  -- An incomplete/failed evaluation MUST NOT authorize qualification (CONTRACT.md sec.20.1).
  constraint evaluation_qualified_requires_complete check (
    qualified is not true or status = 'COMPLETE'
  )
);

create index if not exists evaluation_campaign_candidate_id_idx on evaluation (campaign_candidate_id);
create index if not exists evaluation_campaign_revision_id_idx on evaluation (campaign_revision_id);
create index if not exists evaluation_profile_snapshot_id_idx on evaluation (profile_snapshot_id);
create index if not exists evaluation_trace_id_idx on evaluation (trace_id);
create index if not exists evaluation_created_at_idx on evaluation (created_at);

create trigger evaluation_append_only
before update or delete on evaluation
for each row execute function reject_mutation();

-- Inserting an Evaluation is, within the tables that exist in Phase 0A, the first point a
-- CampaignRevision is actually used for a real decision -- so it freezes the revision here.
-- Phase 1.2 MUST add an equivalent freeze call when search_run is introduced, since a real
-- paid search batch is an earlier use in the full pipeline.
create or replace function evaluation_freeze_revision_on_insert()
returns trigger
language plpgsql
as $$
begin
  perform freeze_campaign_revision(new.campaign_revision_id);
  return new;
end;
$$;

create trigger evaluation_before_insert_freeze_revision
before insert on evaluation
for each row execute function evaluation_freeze_revision_on_insert();

comment on table evaluation is
  'Historical, append-only KPI evaluation record (CONTRACT.md sec.18-25). Inserting a row freezes its campaign_revision.';
