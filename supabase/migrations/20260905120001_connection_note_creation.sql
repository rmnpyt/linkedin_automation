-- Phase 1.4: 30-day evaluation freshness (CONTRACT.md sec.25, pending since Phase 1.1) and
-- atomic connection-note creation (CONTRACT.md sec.41.1,44,94).

-- The current score trust window is 30 days (doc/KPI-FRAMEWORK.md "Scoring Freshness",
-- CONTRACT.md sec.25). An Evaluation older than this MUST NOT be used to make a new
-- outreach decision without re-evaluation.
create or replace function is_evaluation_fresh(p_evaluation_id uuid)
returns boolean
language sql
stable
set search_path = public, extensions
as $$
  select created_at >= now() - interval '30 days'
  from evaluation
  where id = p_evaluation_id;
$$;

comment on function is_evaluation_fresh(uuid) is
  'True when the given evaluation is within the 30-day freshness window (CONTRACT.md sec.25). False (not an error) if the evaluation does not exist.';

-- LinkedIn's own connection-note character limit (doc/prompts/connection-note/v1.md) is
-- enforced here too, not only as an LLM instruction, per CONTRACT.md sec.69 ("workflow/tool
-- code MUST NOT be the sole defense for an invariant Postgres can enforce").
alter table connection_note
  add constraint connection_note_body_length check (length(body) <= 300);

-- At most one active (non-superseded) note per Connection, enforced at the schema level as
-- a backstop independent of the locking discipline inside
-- create_connection_note_and_mark_ready below (CONTRACT.md sec.41.1,69,70).
create unique index if not exists connection_note_one_active_per_connection
  on connection_note (connection_id)
  where superseded_at is null;

-- Atomically creates a durable ConnectionNote and moves the Connection to NOTE_READY, but
-- only when the exact authorizing Evaluation is COMPLETE, qualified, fresh, and still the
-- candidate's CURRENT governing evaluation -- re-verified here rather than trusted from the
-- caller/LLM step (CONTRACT.md sec.69). Locks the Connection row up front (mirroring
-- set_governing_evaluation's and lock_connection_note_before_attempt's existing patterns)
-- so two concurrent calls for the same connection_id -- a realistic duplicate-retry
-- scenario, not just a theoretical one (CONTRACT.md sec.70) -- cannot both see "no active
-- note yet" and both insert one; the second caller waits for the first to commit and then
-- sees its result. The partial unique index above is a second, independent backstop.
-- Fails fast on connection-state ineligibility before touching connection_note at all, so a
-- rejected call never leaves any partial note/state behind (CONTRACT.md sec.94 "note
-- generation failure is recoverable").
create or replace function create_connection_note_and_mark_ready(
  p_connection_id uuid,
  p_campaign_candidate_id uuid,
  p_campaign_revision_id uuid,
  p_evaluation_id uuid,
  p_body text,
  p_model_provider text,
  p_model_name text,
  p_prompt_version text,
  p_trace_id text
)
returns uuid
language plpgsql
set search_path = public, extensions
as $$
declare
  v_connection_state text;
  v_evaluation evaluation%rowtype;
  v_note_id uuid;
begin
  select request_state into v_connection_state
  from connection
  where id = p_connection_id
  for update;

  if not found then
    raise exception 'connection % not found', p_connection_id;
  end if;

  if v_connection_state not in ('NOT_PLANNED', 'NOTE_READY') then
    raise exception 'CONNECTION_NOT_NOTE_ELIGIBLE: connection % is not in a state that can (re)enter NOTE_READY (current state: %)',
      p_connection_id, v_connection_state;
  end if;

  if p_body is null or length(trim(p_body)) = 0 then
    raise exception 'connection note body must not be empty';
  end if;
  if length(p_body) > 300 then
    raise exception 'connection note body exceeds the 300-character limit (% characters)', length(p_body);
  end if;

  select * into v_evaluation
  from evaluation
  where id = p_evaluation_id and campaign_candidate_id = p_campaign_candidate_id;

  if not found then
    raise exception 'evaluation % does not belong to candidate %', p_evaluation_id, p_campaign_candidate_id;
  end if;

  if v_evaluation.status <> 'COMPLETE' or v_evaluation.qualified is not true then
    raise exception 'NOTE_REQUIRES_QUALIFIED_EVALUATION: evaluation % is not a qualifying COMPLETE evaluation', p_evaluation_id;
  end if;

  if not is_evaluation_fresh(p_evaluation_id) then
    raise exception 'EVALUATION_STALE: evaluation % is older than the 30-day freshness window', p_evaluation_id;
  end if;

  if not exists (
    select 1 from campaign_candidate
    where id = p_campaign_candidate_id and current_evaluation_id = p_evaluation_id
  ) then
    raise exception 'EVALUATION_NOT_GOVERNING: evaluation % is not the current governing evaluation for candidate %',
      p_evaluation_id, p_campaign_candidate_id;
  end if;

  update connection_note
  set superseded_at = now()
  where connection_id = p_connection_id and superseded_at is null;

  insert into connection_note (
    connection_id, campaign_candidate_id, campaign_revision_id, evaluation_id, body,
    model_provider, model_name, prompt_version, trace_id
  ) values (
    p_connection_id, p_campaign_candidate_id, p_campaign_revision_id, p_evaluation_id, p_body,
    p_model_provider, p_model_name, p_prompt_version, p_trace_id
  )
  returning id into v_note_id;

  update connection
  set request_state = 'NOTE_READY'
  where id = p_connection_id;

  return v_note_id;
end;
$$;

comment on function create_connection_note_and_mark_ready(uuid, uuid, uuid, uuid, text, text, text, text, text) is
  'Atomically creates a ConnectionNote and moves the Connection to NOTE_READY, re-verifying the authorizing Evaluation is qualified, fresh, and still governing (CONTRACT.md sec.41.1,44,69). Locks the Connection row to prevent concurrent double-active-notes.';
