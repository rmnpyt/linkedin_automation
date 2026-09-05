-- Phase 0A: provider_usage
-- Actual attributable external provider cost/usage ledger (CONTRACT.md sec.63). Source of
-- truth for actual campaign-attributable cost used by budget reconciliation (CONTRACT.md
-- sec.33).

create table if not exists provider_usage (
  id uuid primary key default extensions.gen_random_uuid(),
  campaign_id uuid references campaign (id) on delete restrict,
  campaign_revision_id uuid references campaign_revision (id) on delete restrict,
  trace_id text not null,
  provider text not null,
  operation_type text not null,
  quantity numeric,
  unit text,
  cost_usd numeric not null default 0 check (cost_usd >= 0),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists provider_usage_campaign_id_idx on provider_usage (campaign_id);
create index if not exists provider_usage_campaign_revision_id_idx on provider_usage (campaign_revision_id);
create index if not exists provider_usage_trace_id_idx on provider_usage (trace_id);
create index if not exists provider_usage_provider_operation_idx on provider_usage (provider, operation_type);

comment on table provider_usage is
  'Actual attributable external provider cost/usage ledger (CONTRACT.md sec.63).';
