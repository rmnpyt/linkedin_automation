-- Phase 0A: workflow_step_run
-- Per-step observability for external, expensive, or failure-prone workflow steps
-- (CONTRACT.md sec.62).

create table if not exists workflow_step_run (
  id uuid primary key default extensions.gen_random_uuid(),
  workflow_run_id uuid not null references workflow_run (id) on delete cascade,
  trace_id text not null,
  step_name text not null,
  attempt_number integer not null default 1 check (attempt_number > 0),
  state text not null default 'RUNNING'
    check (state in ('RUNNING', 'COMPLETED', 'FAILED', 'RETRYING')),
  provider text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  latency_ms integer,
  cost_usd numeric,
  error_code text,
  error_message text,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists workflow_step_run_workflow_run_id_idx on workflow_step_run (workflow_run_id);
create index if not exists workflow_step_run_trace_id_idx on workflow_step_run (trace_id);

comment on table workflow_step_run is
  'Per-step observability for expensive/failure-prone workflow steps (CONTRACT.md sec.62).';
