-- Phase 1.3: atomic contact-enrichment attempt claiming with a count-cap, mirroring the
-- Phase 1.2 pattern for max_unique_candidates (CONTRACT.md sec.39,69). max_email_enrichments
-- is a COUNT limit (distinct from the EMAIL_ENRICHMENT cost budget already enforced by
-- reserve_campaign_budget) -- both must independently hold per CONTRACT.md sec.39's
-- eligibility conditions.

create or replace function claim_contact_enrichment_attempt(
  p_campaign_id uuid,
  p_campaign_revision_id uuid,
  p_campaign_candidate_id uuid,
  p_person_id uuid,
  p_external_profile_id uuid,
  p_provider text,
  p_trace_id text
)
returns uuid
language plpgsql
set search_path = public, extensions
as $$
declare
  v_max integer;
  v_current_count integer;
  v_attempt_id uuid;
begin
  -- Lock and count by campaign_id, not campaign_revision_id: CONTRACT.md sec.14 forces a
  -- new CampaignRevision on ANY material rule change, not only an enrichment-policy
  -- change, so a revision-scoped count would silently reset to zero on an unrelated
  -- revision bump -- making the cap trivially bypassable, the same class of bug fixed in
  -- reserve_campaign_budget (see that migration's comment). The limit VALUE still comes
  -- from the current (requesting) revision's budget_policy; only the count is
  -- campaign-wide.
  perform pg_advisory_xact_lock(hashtextextended(p_campaign_id::text, 2));

  select (budget_policy ->> 'max_email_enrichments')::integer into v_max
  from campaign_revision
  where id = p_campaign_revision_id;

  if not found then
    raise exception 'campaign_revision % not found', p_campaign_revision_id;
  end if;

  -- Only attempts that actually ran (or are running) count against the cap; a
  -- budget-blocked attempt never executed and must not consume count capacity.
  select count(*) into v_current_count
  from contact_enrichment_attempt
  where campaign_id = p_campaign_id
    and state <> 'BUDGET_BLOCKED';

  -- Unlike resolve_or_create_campaign_candidate's hard exception (a candidate MUST NOT
  -- exceed the qualification-pipeline cap), a cap-reached enrichment attempt returns NULL
  -- so the caller can simply skip enrichment for this one candidate and continue the batch
  -- -- email enrichment is optional and non-blocking for the LinkedIn connection flow
  -- (CONTRACT.md sec.40), so an exception here would incorrectly abort an entire batch's
  -- unrelated candidates over an optional, best-effort operation.
  if v_max is not null and v_current_count >= v_max then
    return null;
  end if;

  insert into contact_enrichment_attempt (
    campaign_id, campaign_revision_id, campaign_candidate_id, person_id, external_profile_id,
    provider, state, trace_id
  ) values (
    p_campaign_id, p_campaign_revision_id, p_campaign_candidate_id, p_person_id, p_external_profile_id,
    p_provider, 'RUNNING', p_trace_id
  )
  returning id into v_attempt_id;

  return v_attempt_id;
end;
$$;

comment on function claim_contact_enrichment_attempt(uuid, uuid, uuid, uuid, uuid, text, text) is
  'Atomically claims one contact-enrichment attempt slot against max_email_enrichments, returning NULL (not an exception) when the count cap is reached (CONTRACT.md sec.39).';
