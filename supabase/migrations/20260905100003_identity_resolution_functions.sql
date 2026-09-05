-- Phase 1.2: identity resolution and unique-candidate-cap enforcement.
-- Implements CONTRACT.md sec.10 (prefer stable external_id, then canonical_url; never
-- merge by name alone) and sec.29 (candidate ingestion must never exceed
-- max_unique_candidates, even for an oversized provider batch) as atomic, concurrency-safe
-- database functions rather than leaving these invariants to workflow code
-- (CONTRACT.md sec.69).

-- Resolves an incoming raw candidate identity to an existing Person/ExternalProfile, or
-- creates both if no stable identifier matches an existing row. Concurrent duplicate
-- search results (two workers processing overlapping pages) are handled by catching the
-- unique_violation from a genuinely simultaneous insert and re-resolving, rather than
-- failing the caller.
create or replace function resolve_or_create_person_by_external_profile(
  p_platform text,
  p_external_id text,
  p_canonical_url text,
  p_display_name text
)
returns table (person_id uuid, external_profile_id uuid, created boolean)
language plpgsql
set search_path = public, extensions
as $$
declare
  v_profile_id uuid;
  v_person_id uuid;
begin
  -- Treat an empty/whitespace-only string the same as absent: a caller bug that renders a
  -- missing id as '' (common in JS/n8n expressions) must never be treated as a real,
  -- distinct identifier -- that would silently merge unrelated people who all resolve to
  -- (platform, external_id='') (CONTRACT.md sec.10).
  p_external_id := nullif(trim(p_external_id), '');
  p_canonical_url := nullif(trim(p_canonical_url), '');

  if p_external_id is null and p_canonical_url is null then
    raise exception 'at least one of external_id or canonical_url is required';
  end if;

  if p_external_id is not null then
    select ep.id, ep.person_id into v_profile_id, v_person_id
    from external_profile ep
    where ep.platform = p_platform and ep.external_id = p_external_id;
  end if;

  if v_profile_id is null and p_canonical_url is not null then
    select ep.id, ep.person_id into v_profile_id, v_person_id
    from external_profile ep
    where ep.platform = p_platform and ep.canonical_url = p_canonical_url;
  end if;

  if v_profile_id is not null then
    return query select v_person_id, v_profile_id, false;
    return;
  end if;

  begin
    insert into person (display_name) values (p_display_name) returning id into v_person_id;

    insert into external_profile (person_id, platform, external_id, canonical_url)
    values (v_person_id, p_platform, p_external_id, p_canonical_url)
    returning id into v_profile_id;

    return query select v_person_id, v_profile_id, true;
  exception
    when unique_violation then
      -- Another concurrent caller won the race and created this external_profile between
      -- our lookup and our insert. Clean up the Person we speculatively created above --
      -- concurrent duplicate search-result ingestion is an expected, routine occurrence
      -- (CONTRACT.md sec.77), not a rare edge case, so leaving orphaned Person rows behind
      -- would accumulate as a real data-quality problem for any future person-level
      -- reporting (CONTRACT.md sec.63,103) -- then re-resolve to the row that won the race.
      delete from person where id = v_person_id;

      if p_external_id is not null then
        select ep.id, ep.person_id into v_profile_id, v_person_id
        from external_profile ep
        where ep.platform = p_platform and ep.external_id = p_external_id;
      end if;
      if v_profile_id is null and p_canonical_url is not null then
        select ep.id, ep.person_id into v_profile_id, v_person_id
        from external_profile ep
        where ep.platform = p_platform and ep.canonical_url = p_canonical_url;
      end if;
      if v_profile_id is null then
        raise;
      end if;
      return query select v_person_id, v_profile_id, false;
  end;
end;
$$;

comment on function resolve_or_create_person_by_external_profile(text, text, text, text) is
  'Identity resolution preferring external_id then canonical_url; never merges by name alone (CONTRACT.md sec.10).';

-- Atomically resolves-or-creates a CampaignCandidate, enforcing max_unique_candidates
-- (from campaign_revision.budget_policy) so an oversized provider batch cannot create
-- more candidates than the configured cap (CONTRACT.md sec.29). A transaction-scoped
-- advisory lock keyed on campaign_id serializes concurrent candidate creation for the same
-- campaign so the count check is race-safe.
create or replace function resolve_or_create_campaign_candidate(
  p_campaign_id uuid,
  p_campaign_revision_id uuid,
  p_person_id uuid,
  p_external_profile_id uuid
)
returns table (candidate_id uuid, created boolean)
language plpgsql
set search_path = public, extensions
as $$
declare
  v_existing uuid;
  v_max integer;
  v_current_count integer;
  v_new_id uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_campaign_id::text, 1));

  select cc.id into v_existing
  from campaign_candidate cc
  where cc.campaign_id = p_campaign_id and cc.person_id = p_person_id;

  if found then
    return query select v_existing, false;
    return;
  end if;

  select (budget_policy ->> 'max_unique_candidates')::integer into v_max
  from campaign_revision
  where id = p_campaign_revision_id;

  select count(*) into v_current_count
  from campaign_candidate
  where campaign_id = p_campaign_id;

  if v_max is not null and v_current_count >= v_max then
    -- Raising here (rather than returning a sentinel) is deliberate: a caller MUST NOT
    -- proceed past the cap. Whoever builds the n8n batch-ingestion caller MUST account for
    -- this being a hard exception that aborts the enclosing transaction -- call this once
    -- per candidate in its own transaction/savepoint (or check campaign_policy's
    -- adjustedBatchSize before the batch, not just per-row) so hitting the cap mid-batch
    -- cannot silently roll back an earlier candidate's already-inserted side effects in the
    -- same transaction.
    raise exception 'CAMPAIGN_CANDIDATE_CAP_REACHED: campaign % already has % candidates (max_unique_candidates=%)',
      p_campaign_id, v_current_count, v_max;
  end if;

  insert into campaign_candidate (campaign_id, person_id, external_profile_id)
  values (p_campaign_id, p_person_id, p_external_profile_id)
  returning id into v_new_id;

  return query select v_new_id, true;
end;
$$;

comment on function resolve_or_create_campaign_candidate(uuid, uuid, uuid, uuid) is
  'Atomically resolves-or-creates a CampaignCandidate and enforces max_unique_candidates so an oversized provider batch cannot exceed the cap (CONTRACT.md sec.29).';
