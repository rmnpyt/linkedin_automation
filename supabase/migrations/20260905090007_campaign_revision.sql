-- Phase 0A: campaign_revision
-- An immutable-once-frozen version of execution configuration for a Campaign
-- (CONTRACT.md sec.14). A revision MUST become immutable as soon as an execution starts
-- using it, before the first provider call or child domain record depends on it.
--
-- Within the tables that exist in Phase 0A, the earliest such dependency is an Evaluation
-- row (Phase 1.2's SearchRun will be an earlier real-world dependency once it exists --
-- see the note on evaluation_before_insert_freeze_revision in the evaluation migration;
-- Phase 1.2 MUST add the same freeze call to search_run on insert).

create table if not exists campaign_revision (
  id uuid primary key default extensions.gen_random_uuid(),
  campaign_id uuid not null references campaign (id) on delete restrict,
  version integer not null,
  target_definition jsonb not null default '{}'::jsonb,
  kpi_weights jsonb not null default
    '{"kpi1": 25, "kpi2": 20, "kpi3": 15, "kpi4": 20, "kpi5": 10, "kpi6": 10}'::jsonb,
  require_field boolean not null default true,
  require_location boolean not null default true,
  qualification_threshold numeric not null default 60,
  search_policy jsonb not null default '{}'::jsonb,
  budget_policy jsonb not null default '{}'::jsonb,
  contact_enrichment_policy jsonb not null default '{}'::jsonb,
  note_strategy jsonb not null default '{}'::jsonb,
  frozen_at timestamptz,
  created_at timestamptz not null default now(),
  created_by text,
  constraint campaign_revision_version_positive check (version > 0),
  constraint campaign_revision_threshold_range check (
    qualification_threshold >= 0 and qualification_threshold <= 100
  )
);

create unique index if not exists campaign_revision_campaign_id_version_key
  on campaign_revision (campaign_id, version);

create index if not exists campaign_revision_campaign_id_idx on campaign_revision (campaign_id);

-- Enforce the freeze: once frozen_at is set, no material configuration column may change,
-- and frozen_at itself may never be un-set or re-set to a different value.
create or replace function enforce_campaign_revision_freeze()
returns trigger
language plpgsql
as $$
begin
  if old.frozen_at is not null then
    if new.frozen_at is distinct from old.frozen_at then
      raise exception 'campaign_revision % is frozen; frozen_at cannot change', old.id;
    end if;
    if new.target_definition is distinct from old.target_definition
       or new.kpi_weights is distinct from old.kpi_weights
       or new.require_field is distinct from old.require_field
       or new.require_location is distinct from old.require_location
       or new.qualification_threshold is distinct from old.qualification_threshold
       or new.search_policy is distinct from old.search_policy
       or new.budget_policy is distinct from old.budget_policy
       or new.contact_enrichment_policy is distinct from old.contact_enrichment_policy
       or new.note_strategy is distinct from old.note_strategy
    then
      raise exception 'campaign_revision % is frozen and cannot be materially modified', old.id;
    end if;
  elsif new.frozen_at is not null then
    -- Freezing in this same statement must not be combined with a material policy edit:
    -- the frozen snapshot must reflect exactly the config that governed execution up to
    -- this point, not a value changed in the same breath as the freeze.
    if new.target_definition is distinct from old.target_definition
       or new.kpi_weights is distinct from old.kpi_weights
       or new.require_field is distinct from old.require_field
       or new.require_location is distinct from old.require_location
       or new.qualification_threshold is distinct from old.qualification_threshold
       or new.search_policy is distinct from old.search_policy
       or new.budget_policy is distinct from old.budget_policy
       or new.contact_enrichment_policy is distinct from old.contact_enrichment_policy
       or new.note_strategy is distinct from old.note_strategy
    then
      raise exception 'campaign_revision % cannot be frozen and materially modified in the same statement', old.id;
    end if;
  end if;
  return new;
end;
$$;

create trigger campaign_revision_enforce_freeze
before update on campaign_revision
for each row execute function enforce_campaign_revision_freeze();

-- Idempotent freeze: safe to call multiple times / from multiple concurrent callers.
create or replace function freeze_campaign_revision(p_revision_id uuid)
returns void
language sql
as $$
  update campaign_revision
  set frozen_at = now()
  where id = p_revision_id
    and frozen_at is null;
$$;

comment on table campaign_revision is
  'Immutable-once-frozen execution configuration for a Campaign (CONTRACT.md sec.14).';
comment on function freeze_campaign_revision(uuid) is
  'Idempotently freezes a campaign_revision. Safe to call multiple times or concurrently.';
