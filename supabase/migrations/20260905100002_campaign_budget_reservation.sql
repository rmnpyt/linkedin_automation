-- Phase 1.2: campaign_budget_reservation + atomic reserve/settle/release functions.
-- Implements CONTRACT.md sec.33's "Atomic Reservation or Serialization" requirement: two
-- concurrent workers must not be able to independently spend the same remaining budget.
-- A transaction-scoped advisory lock keyed on the campaign_revision_id serializes
-- concurrent reservation attempts for the same revision, closing the read-then-write race
-- a plain SELECT-remaining-then-INSERT pattern would have.

create table if not exists campaign_budget_reservation (
  id uuid primary key default extensions.gen_random_uuid(),
  campaign_id uuid not null references campaign (id) on delete restrict,
  campaign_revision_id uuid not null references campaign_revision (id) on delete restrict,
  budget_type text not null check (budget_type in ('SEARCH', 'EVALUATION', 'EMAIL_ENRICHMENT')),
  reserved_amount_usd numeric not null check (reserved_amount_usd >= 0),
  actual_cost_usd numeric check (actual_cost_usd is null or actual_cost_usd >= 0),
  state text not null default 'RESERVED' check (state in ('RESERVED', 'SETTLED', 'RELEASED')),
  trace_id text,
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  constraint campaign_budget_reservation_settled_has_cost check (
    state <> 'SETTLED' or actual_cost_usd is not null
  )
);

create index if not exists campaign_budget_reservation_revision_type_idx
  on campaign_budget_reservation (campaign_revision_id, budget_type);
create index if not exists campaign_budget_reservation_campaign_id_idx
  on campaign_budget_reservation (campaign_id);

comment on table campaign_budget_reservation is
  'Atomic budget reservation/settlement ledger per CampaignRevision and budget dimension (CONTRACT.md sec.33).';

-- Reserves `p_requested_amount_usd` against both the budget_type-specific limit
-- (max_search_cost_usd / max_evaluation_cost_usd / max_email_enrichment_cost_usd, read
-- from campaign_revision.budget_policy) AND the total-campaign limit
-- (max_total_campaign_cost_usd), since every operation type is campaign-attributable
-- (CONTRACT.md sec.32). Returns the new reservation id, or NULL if either limit would be
-- exceeded (the caller must not proceed with the paid operation in that case). A missing
-- (null) limit in budget_policy means that dimension is uncapped. Committed spend is
-- aggregated across every CampaignRevision belonging to the same Campaign, not just the
-- requesting revision -- see the campaign-wide-spend comment in the function body.
create or replace function reserve_campaign_budget(
  p_campaign_revision_id uuid,
  p_budget_type text,
  p_requested_amount_usd numeric,
  p_trace_id text
)
returns uuid
language plpgsql
set search_path = public, extensions
as $$
declare
  v_campaign_id uuid;
  v_policy jsonb;
  v_type_limit numeric;
  v_total_limit numeric;
  v_type_committed numeric;
  v_total_committed numeric;
  v_reservation_id uuid;
begin
  if p_budget_type not in ('SEARCH', 'EVALUATION', 'EMAIL_ENRICHMENT') then
    raise exception 'invalid budget_type %', p_budget_type;
  end if;
  if p_requested_amount_usd < 0 then
    raise exception 'requested_amount_usd must be >= 0, got %', p_requested_amount_usd;
  end if;

  -- Read campaign_id first (unlocked -- a revision's campaign_id FK never changes after
  -- creation, so this is safe without a lock), then lock and aggregate spend by
  -- campaign_id rather than campaign_revision_id. CONTRACT.md sec.14 forces a new
  -- CampaignRevision on ANY material rule change, not only a budget-policy change, and
  -- sec.30 requires hard budgets to remain enforceable ("MUST NOT allow an effectively
  -- unbounded paid search by accident") -- scoping spend to one revision would let every
  -- unrelated revision bump (e.g. a qualification-threshold tweak) silently reset the
  -- campaign's spend counters to zero, making the cap trivially bypassable. Limits
  -- themselves still come from the CURRENT (requesting) revision's budget_policy, since
  -- that reflects the operator's active configuration; only the committed-spend
  -- aggregation is campaign-wide.
  select campaign_id into v_campaign_id
  from campaign_revision
  where id = p_campaign_revision_id;

  if not found then
    raise exception 'campaign_revision % not found', p_campaign_revision_id;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_campaign_id::text, 0));

  select budget_policy into v_policy
  from campaign_revision
  where id = p_campaign_revision_id;

  v_type_limit := case p_budget_type
    when 'SEARCH' then (v_policy ->> 'max_search_cost_usd')::numeric
    when 'EVALUATION' then (v_policy ->> 'max_evaluation_cost_usd')::numeric
    when 'EMAIL_ENRICHMENT' then (v_policy ->> 'max_email_enrichment_cost_usd')::numeric
  end;
  v_total_limit := (v_policy ->> 'max_total_campaign_cost_usd')::numeric;

  select coalesce(sum(
    case
      when state = 'RELEASED' then 0
      when state = 'SETTLED' then actual_cost_usd
      else reserved_amount_usd
    end
  ), 0)
  into v_type_committed
  from campaign_budget_reservation
  where campaign_id = v_campaign_id
    and budget_type = p_budget_type;

  select coalesce(sum(
    case
      when state = 'RELEASED' then 0
      when state = 'SETTLED' then actual_cost_usd
      else reserved_amount_usd
    end
  ), 0)
  into v_total_committed
  from campaign_budget_reservation
  where campaign_id = v_campaign_id;

  if v_type_limit is not null and v_type_committed + p_requested_amount_usd > v_type_limit then
    return null;
  end if;
  if v_total_limit is not null and v_total_committed + p_requested_amount_usd > v_total_limit then
    return null;
  end if;

  insert into campaign_budget_reservation (
    campaign_id, campaign_revision_id, budget_type, reserved_amount_usd, state, trace_id
  ) values (
    v_campaign_id, p_campaign_revision_id, p_budget_type, p_requested_amount_usd, 'RESERVED', p_trace_id
  )
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$$;

comment on function reserve_campaign_budget(uuid, text, numeric, text) is
  'Atomically reserves campaign budget against both the type-specific and total-campaign limits; returns NULL (not an exception) when the request would exceed either.';

-- Settles a reservation against actual provider-reported cost after execution
-- (CONTRACT.md sec.33 "Actual Cost Reconciliation").
create or replace function settle_campaign_budget_reservation(
  p_reservation_id uuid,
  p_actual_cost_usd numeric
)
returns void
language plpgsql
set search_path = public, extensions
as $$
begin
  if p_actual_cost_usd < 0 then
    raise exception 'actual_cost_usd must be >= 0, got %', p_actual_cost_usd;
  end if;

  update campaign_budget_reservation
  set state = 'SETTLED', actual_cost_usd = p_actual_cost_usd, settled_at = now()
  where id = p_reservation_id and state = 'RESERVED';

  if not found then
    raise exception 'reservation % not found or not in RESERVED state', p_reservation_id;
  end if;
end;
$$;

-- Releases an unused reservation (e.g. the operation was skipped or the campaign stopped
-- before executing it) so it stops counting toward committed budget.
create or replace function release_campaign_budget_reservation(p_reservation_id uuid)
returns void
language plpgsql
set search_path = public, extensions
as $$
begin
  update campaign_budget_reservation
  set state = 'RELEASED', settled_at = now()
  where id = p_reservation_id and state = 'RESERVED';

  if not found then
    raise exception 'reservation % not found or not in RESERVED state', p_reservation_id;
  end if;
end;
$$;
