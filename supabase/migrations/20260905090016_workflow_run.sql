-- Phase 0A: workflow_run
-- Durable record of a major n8n workflow execution (CONTRACT.md sec.61).

create table if not exists workflow_run (
  id uuid primary key default extensions.gen_random_uuid(),
  trace_id text not null,
  workflow_type text not null,
  entity_type text,
  entity_id uuid,
  state text not null default 'RUNNING' check (state in ('RUNNING', 'COMPLETED', 'FAILED')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  error_code text,
  error_message text,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists workflow_run_trace_id_idx on workflow_run (trace_id);
create index if not exists workflow_run_workflow_type_idx on workflow_run (workflow_type);
create index if not exists workflow_run_entity_idx on workflow_run (entity_type, entity_id);

comment on table workflow_run is
  'Durable record of a major n8n workflow execution (CONTRACT.md sec.61).';
