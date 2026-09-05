-- Phase 1.5: safe connection sending -- atomic queue-claim, idempotent attempt creation,
-- send-attempted transition, terminal result recording, UNKNOWN_SEND_RESULT reconciliation,
-- explicit FAILED retry, and per-operator daily/operating-window limits
-- (CONTRACT.md sec.45-48,64-65,69-70,95).

-- CONTRACT.md sec.48: "The implementation MUST support an explicit daily maximum [and] an
-- allowed operating window." These are properties of the operator's LinkedIn account (the
-- real-world thing being rate-limited), not of any one campaign, so they live on Operator.
-- Both are optional (null = uncapped/unrestricted by this specific mechanism) for
-- consistency with every other CONTRACT-mandated limit in this project (a missing limit
-- means "not configured," never an invented default). The window is expressed in UTC hours
-- for V1 -- a per-operator local-timezone business day is a documented future refinement,
-- not a Contract requirement.
alter table operator
  add column max_daily_connection_sends integer
    check (max_daily_connection_sends is null or max_daily_connection_sends > 0),
  add column send_window_start_hour_utc integer
    check (send_window_start_hour_utc is null or send_window_start_hour_utc between 0 and 23),
  add column send_window_end_hour_utc integer
    check (send_window_end_hour_utc is null or send_window_end_hour_utc between 0 and 23);

comment on column operator.max_daily_connection_sends is
  'Optional hard cap on real (non-idempotent-replay) connection sends per UTC calendar day for this operator (CONTRACT.md sec.48). Null = uncapped by this mechanism.';
comment on column operator.send_window_start_hour_utc is
  'Optional allowed-sending-window start hour (0-23, UTC). Paired with send_window_end_hour_utc; a start > end is treated as a window that wraps past midnight. Null on either disables window enforcement (CONTRACT.md sec.48).';

-- Atomically claims a Connection for sending: verifies it has a current active
-- ConnectionNote whose authorizing Evaluation is still fresh (CONTRACT.md sec.44), then
-- either returns the connection's existing in-flight (QUEUED/SEND_ATTEMPTED) attempt for
-- this exact note (true idempotent replay, CONTRACT.md sec.46 -- a retry/duplicate trigger
-- must never create a second in-flight attempt), or -- if no in-flight attempt exists,
-- whether because none was ever made or because a prior one reached FAILED and was
-- explicitly reset via retry_failed_connection_attempt -- enforces the operator's
-- daily/window limits and creates a new ConnectionAttempt with the next attempt_number.
-- SENT/ALREADY_CONNECTED are correctly permanent and never reach this "create a new
-- attempt" path (create_connection_note_and_mark_ready only accepts NOT_PLANNED/NOTE_READY
-- connections, so a new claim cannot occur while the connection is in either state).
create or replace function claim_connection_for_sending(
  p_connection_id uuid,
  p_trace_id text
)
returns uuid
language plpgsql
set search_path = public, extensions
as $$
declare
  v_connection connection%rowtype;
  v_note connection_note%rowtype;
  v_idempotency_key text;
  v_existing_attempt_id uuid;
  v_attempt_id uuid;
  v_attempt_number integer;
  v_max_daily integer;
  v_window_start integer;
  v_window_end integer;
  v_current_hour integer;
  v_daily_count integer;
begin
  select * into v_connection from connection where id = p_connection_id for update;
  if not found then
    raise exception 'connection % not found', p_connection_id;
  end if;

  select * into v_note
  from connection_note
  where connection_id = p_connection_id and superseded_at is null;

  if not found then
    raise exception 'NO_ACTIVE_NOTE: connection % has no active connection_note to send', p_connection_id;
  end if;

  if not is_evaluation_fresh(v_note.evaluation_id) then
    raise exception 'EVALUATION_STALE: the active note''s authorizing evaluation is no longer fresh; re-evaluate and regenerate the note before sending';
  end if;

  select id into v_existing_attempt_id
  from connection_attempt
  where connection_note_id = v_note.id and state in ('QUEUED', 'SEND_ATTEMPTED');

  if found then
    return v_existing_attempt_id;
  end if;

  select max_daily_connection_sends, send_window_start_hour_utc, send_window_end_hour_utc
  into v_max_daily, v_window_start, v_window_end
  from operator
  where id = v_connection.operator_id;

  if v_window_start is not null and v_window_end is not null then
    v_current_hour := extract(hour from (now() at time zone 'UTC'))::integer;
    if v_window_start <= v_window_end then
      if v_current_hour < v_window_start or v_current_hour >= v_window_end then
        raise exception 'OUTSIDE_SEND_WINDOW: current UTC hour % is outside the allowed window [%,%)',
          v_current_hour, v_window_start, v_window_end;
      end if;
    else
      -- Window wraps past midnight (e.g. 22 -> 6).
      if v_current_hour < v_window_start and v_current_hour >= v_window_end then
        raise exception 'OUTSIDE_SEND_WINDOW: current UTC hour % is outside the allowed overnight window [%,%)',
          v_current_hour, v_window_start, v_window_end;
      end if;
    end if;
  end if;

  if v_max_daily is not null then
    select count(*) into v_daily_count
    from connection_attempt ca
    join connection c on c.id = ca.connection_id
    where c.operator_id = v_connection.operator_id
      and ca.started_at >= date_trunc('day', now() at time zone 'UTC');

    if v_daily_count >= v_max_daily then
      raise exception 'DAILY_SEND_LIMIT_REACHED: operator % has already reached max_daily_connection_sends=% for today (UTC)',
        v_connection.operator_id, v_max_daily;
    end if;
  end if;

  select coalesce(max(attempt_number), 0) + 1 into v_attempt_number
  from connection_attempt
  where connection_id = p_connection_id;

  v_idempotency_key := 'connection_send:' || v_note.id::text || ':' || v_attempt_number::text;

  insert into connection_attempt (
    connection_id, campaign_candidate_id, campaign_revision_id, evaluation_id, connection_note_id,
    idempotency_key, attempt_number, state, trace_id
  ) values (
    p_connection_id, v_note.campaign_candidate_id, v_note.campaign_revision_id, v_note.evaluation_id, v_note.id,
    v_idempotency_key, v_attempt_number, 'QUEUED', p_trace_id
  )
  returning id into v_attempt_id;

  update connection
  set request_state = 'QUEUED'
  where id = p_connection_id and request_state = 'NOTE_READY';

  if not found then
    raise exception 'CONNECTION_NOT_QUEUEABLE: connection % is not in NOTE_READY state', p_connection_id;
  end if;

  return v_attempt_id;
end;
$$;

comment on function claim_connection_for_sending(uuid, text) is
  'Atomically claims a Connection for sending and idempotently returns/creates its ConnectionAttempt, enforcing evaluation freshness and the operator''s daily/window limits (CONTRACT.md sec.44,46,48,69).';

-- Marks the moment the external send action (the PowerShell/browser ConnectionSender) is
-- actually about to be invoked. Kept as a separate step from claim so a real caller can
-- distinguish "queued, not yet dispatched" from "actively calling the external system" in
-- its own retry/timeout handling.
create or replace function mark_connection_attempt_send_attempted(p_attempt_id uuid)
returns void
language plpgsql
set search_path = public, extensions
as $$
declare
  v_connection_id uuid;
begin
  select connection_id into v_connection_id
  from connection_attempt
  where id = p_attempt_id
  for update;

  if not found then
    raise exception 'connection_attempt % not found', p_attempt_id;
  end if;

  update connection_attempt
  set state = 'SEND_ATTEMPTED'
  where id = p_attempt_id and state = 'QUEUED';

  if not found then
    raise exception 'ATTEMPT_NOT_QUEUED: connection_attempt % is not in QUEUED state', p_attempt_id;
  end if;

  update connection
  set request_state = 'SEND_ATTEMPTED', requested_at = now()
  where id = v_connection_id;
end;
$$;

comment on function mark_connection_attempt_send_attempted(uuid) is
  'Transitions a claimed ConnectionAttempt to SEND_ATTEMPTED immediately before the external send call (CONTRACT.md sec.43,45).';

-- Records the terminal (or ambiguous) result of a dispatched send attempt. p_result is one
-- of the normalized ConnectionSender outcomes (PROPOSAL.md sec.19): SENT, FAILED,
-- ALREADY_CONNECTED, or UNKNOWN (mapped here to the Connection's UNKNOWN_SEND_RESULT
-- state). Deliberately does NOT set connection.connected_at/relationship_state on SENT --
-- "sent a request" is not "they connected"; observing actual acceptance is a separate,
-- future reconciliation concern (PLAN.md sec.24) outside this phase's scope.
create or replace function record_connection_attempt_result(
  p_attempt_id uuid,
  p_result text,
  p_error_code text,
  p_error_message text,
  p_result_metadata jsonb
)
returns void
language plpgsql
set search_path = public, extensions
as $$
declare
  v_connection_id uuid;
  v_new_state text;
begin
  if p_result not in ('SENT', 'FAILED', 'ALREADY_CONNECTED', 'UNKNOWN') then
    raise exception 'invalid result %; expected SENT, FAILED, ALREADY_CONNECTED, or UNKNOWN', p_result;
  end if;

  select connection_id into v_connection_id
  from connection_attempt
  where id = p_attempt_id
  for update;

  if not found then
    raise exception 'connection_attempt % not found', p_attempt_id;
  end if;

  v_new_state := case p_result
    when 'UNKNOWN' then 'UNKNOWN_SEND_RESULT'
    else p_result
  end;

  update connection_attempt
  set state = v_new_state,
      finished_at = now(),
      result_metadata = p_result_metadata,
      error_code = p_error_code,
      error_message = p_error_message
  where id = p_attempt_id and state = 'SEND_ATTEMPTED';

  if not found then
    raise exception 'ATTEMPT_NOT_IN_PROGRESS: connection_attempt % is not in SEND_ATTEMPTED state', p_attempt_id;
  end if;

  update connection
  set request_state = v_new_state
  where id = v_connection_id;
end;
$$;

comment on function record_connection_attempt_result(uuid, text, text, text, jsonb) is
  'Records the terminal or ambiguous result of a dispatched ConnectionAttempt (CONTRACT.md sec.43,45,47).';

-- Resolves a previously UNKNOWN_SEND_RESULT attempt once its true outcome has been
-- determined by an external check or human review (CONTRACT.md sec.47: unknown results
-- "MUST instead: reconcile external state when safe and technically possible; or require
-- human resolution" -- never a blind resend). Only transitions FROM UNKNOWN_SEND_RESULT,
-- never from any other state, and never back to UNKNOWN.
create or replace function reconcile_connection_attempt(
  p_attempt_id uuid,
  p_resolved_result text,
  p_resolution_notes text
)
returns void
language plpgsql
set search_path = public, extensions
as $$
declare
  v_connection_id uuid;
  v_metadata jsonb;
begin
  if p_resolved_result not in ('SENT', 'FAILED', 'ALREADY_CONNECTED') then
    raise exception 'invalid resolved_result %; expected SENT, FAILED, or ALREADY_CONNECTED', p_resolved_result;
  end if;

  select connection_id into v_connection_id
  from connection_attempt
  where id = p_attempt_id
  for update;

  if not found then
    raise exception 'connection_attempt % not found', p_attempt_id;
  end if;

  select coalesce(result_metadata, '{}'::jsonb) || jsonb_build_object('reconciliation_notes', p_resolution_notes)
  into v_metadata
  from connection_attempt
  where id = p_attempt_id;

  update connection_attempt
  set state = p_resolved_result,
      result_metadata = v_metadata
  where id = p_attempt_id and state = 'UNKNOWN_SEND_RESULT';

  if not found then
    raise exception 'ATTEMPT_NOT_UNKNOWN: connection_attempt % is not in UNKNOWN_SEND_RESULT state', p_attempt_id;
  end if;

  update connection
  set request_state = p_resolved_result
  where id = v_connection_id;
end;
$$;

comment on function reconcile_connection_attempt(uuid, text, text) is
  'Resolves an UNKNOWN_SEND_RESULT attempt to its true outcome once determined; never a blind resend (CONTRACT.md sec.47).';

-- Explicitly authorizes retrying a FAILED send: resets the Connection back to NOTE_READY
-- (reusing the same still-active note -- no need to regenerate it) so a subsequent
-- claim_connection_for_sending creates a genuinely NEW ConnectionAttempt (a new
-- attempt_number and idempotency_key), rather than the request being permanently stuck.
-- This is a deliberate, explicit, one-at-a-time decision (CONTRACT.md sec.65 "Retryable
-- operations SHOULD use backoff" is only reachable through an explicit call like this one,
-- never automatically -- CONTRACT.md sec.46 still requires duplicate-sensitive sends to
-- never auto-retry). SENT and ALREADY_CONNECTED are correctly permanent and cannot be
-- retried this way; UNKNOWN_SEND_RESULT has its own reconcile_connection_attempt path.
-- The prior FAILED attempt's history is preserved untouched (CONTRACT.md sec.65 "A retry
-- MUST NOT erase the history of earlier failed attempts").
create or replace function retry_failed_connection_attempt(p_connection_id uuid)
returns void
language plpgsql
set search_path = public, extensions
as $$
begin
  update connection
  set request_state = 'NOTE_READY'
  where id = p_connection_id and request_state = 'FAILED';

  if not found then
    raise exception 'CONNECTION_NOT_RETRYABLE: connection % is not in FAILED state', p_connection_id;
  end if;
end;
$$;

comment on function retry_failed_connection_attempt(uuid) is
  'Explicitly authorizes retrying a FAILED connection send; resets to NOTE_READY so the next claim creates a new attempt. Never automatic (CONTRACT.md sec.46,65).';
