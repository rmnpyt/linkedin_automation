-- Phase 1.5 database tests (CONTRACT.md sec.43,45-48,69-70,75,95). Run inside a
-- transaction that always rolls back, so this is safe to run repeatedly against the shared
-- linkedin_automation development project without leaving residue. All fixture data is
-- synthetic (CONTRACT.md sec.67.1).

begin;

select plan(26);

insert into operator (id, display_name) values
  ('40000000-0000-0000-0000-000000000001', 'Send Test Operator');
insert into campaign (id, operator_id, name) values
  ('40000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000001', 'Send Test Campaign');
insert into campaign_revision (id, campaign_id, version) values
  ('40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000002', 1);
insert into person (id, display_name) values
  ('40000000-0000-0000-0000-000000000004', 'Send Test Person');
insert into external_profile (id, person_id, platform, external_id) values
  ('40000000-0000-0000-0000-000000000005', '40000000-0000-0000-0000-000000000004', 'linkedin', 'send-ext-1');
insert into profile_snapshot (id, external_profile_id, source_provider, raw_data, normalized_data) values
  ('40000000-0000-0000-0000-000000000006', '40000000-0000-0000-0000-000000000005', 'synthetic_fixture', '{}'::jsonb, '{}'::jsonb);
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id, state) values
  ('40000000-0000-0000-0000-000000000007', '40000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000005', 'EVALUATED');
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '40000000-0000-0000-0000-000000000008', '40000000-0000-0000-0000-000000000007',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000006', 'COMPLETE',
  90, 90, 90, 90, 90, true, now()
);
select set_governing_evaluation('40000000-0000-0000-0000-000000000007', '40000000-0000-0000-0000-000000000008', 'QUALIFIED');
insert into connection (id, operator_id, person_id, external_profile_id) values
  ('40000000-0000-0000-0000-000000000010', '40000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000005');

-- 1: claiming a Connection with no active note is rejected.
select throws_ok(
  $$ select claim_connection_for_sending('40000000-0000-0000-0000-000000000010', 'trace-send-0') $$,
  'P0001', null, 'claiming a connection with no active note is rejected (NO_ACTIVE_NOTE)'
);

select create_connection_note_and_mark_ready(
  '40000000-0000-0000-0000-000000000010', '40000000-0000-0000-0000-000000000007',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000008',
  'Hi -- would love to connect given our shared field.',
  'openrouter', 'test-model', 'connection-note/v1', 'trace-note-send'
);

do $$
declare
  v_attempt_id uuid;
begin
  v_attempt_id := claim_connection_for_sending('40000000-0000-0000-0000-000000000010', 'trace-send-1');
  create temporary table if not exists tmp_attempt_id (id uuid);
  insert into tmp_attempt_id values (v_attempt_id);
end $$;

-- 2: claiming creates a real attempt.
select ok(
  (select id from tmp_attempt_id) is not null,
  'claim_connection_for_sending creates a ConnectionAttempt for a valid NOTE_READY connection'
);
-- 3: the connection is now QUEUED.
select is(
  (select request_state from connection where id = '40000000-0000-0000-0000-000000000010'),
  'QUEUED',
  'claiming transitions the connection to QUEUED'
);
-- 4: claiming again for the same connection/note is idempotent (same attempt id, no duplicate).
select is(
  claim_connection_for_sending('40000000-0000-0000-0000-000000000010', 'trace-send-1-retry'),
  (select id from tmp_attempt_id),
  'claiming again for the same active note returns the same attempt id (CONTRACT.md sec.46 idempotency)'
);
select is(
  (select count(*) from connection_attempt where connection_id = '40000000-0000-0000-0000-000000000010'),
  1::bigint,
  'the idempotent re-claim did not create a duplicate connection_attempt row'
);

-- 5: mark_connection_attempt_send_attempted transitions QUEUED -> SEND_ATTEMPTED.
select mark_connection_attempt_send_attempted((select id from tmp_attempt_id));
select is(
  (select state from connection_attempt where id = (select id from tmp_attempt_id)),
  'SEND_ATTEMPTED',
  'marking send-attempted transitions the attempt to SEND_ATTEMPTED'
);
select is(
  (select request_state from connection where id = '40000000-0000-0000-0000-000000000010'),
  'SEND_ATTEMPTED',
  'marking send-attempted transitions the connection to SEND_ATTEMPTED and sets requested_at'
);
-- 6: marking send-attempted a second time (already past QUEUED) is rejected.
select throws_ok(
  format($$ select mark_connection_attempt_send_attempted(%L) $$, (select id from tmp_attempt_id)),
  'P0001', null, 'marking an attempt send-attempted twice is rejected (not in QUEUED state)'
);

-- 7: recording a SENT result finalizes the attempt and the connection.
select record_connection_attempt_result((select id from tmp_attempt_id), 'SENT', null, null, '{}'::jsonb);
select is(
  (select state from connection_attempt where id = (select id from tmp_attempt_id)),
  'SENT',
  'recording SENT finalizes the connection_attempt'
);
select is(
  (select request_state from connection where id = '40000000-0000-0000-0000-000000000010'),
  'SENT',
  'recording SENT finalizes the connection request_state'
);
-- 8: "sent" MUST NOT be conflated with "they accepted" -- connected_at stays untouched.
select is(
  (select connected_at from connection where id = '40000000-0000-0000-0000-000000000010'),
  null,
  'recording a SENT result does not set connected_at -- sending a request is not acceptance'
);
-- 9: recording a result again (already terminal) is rejected.
select throws_ok(
  format($$ select record_connection_attempt_result(%L, 'SENT', null, null, '{}'::jsonb) $$, (select id from tmp_attempt_id)),
  'P0001', null, 'recording a result twice is rejected (attempt no longer SEND_ATTEMPTED)'
);

-- === UNKNOWN_SEND_RESULT -> reconciliation, on a fresh connection/attempt ===
insert into person (id, display_name) values
  ('40000000-0000-0000-0000-000000000020', 'Send Test Person 2');
insert into external_profile (id, person_id, platform, external_id) values
  ('40000000-0000-0000-0000-000000000021', '40000000-0000-0000-0000-000000000020', 'linkedin', 'send-ext-2');
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id, state) values
  ('40000000-0000-0000-0000-000000000022', '40000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000020', '40000000-0000-0000-0000-000000000021', 'EVALUATED');
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '40000000-0000-0000-0000-000000000023', '40000000-0000-0000-0000-000000000022',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000006', 'COMPLETE',
  90, 90, 90, 90, 90, true, now()
);
select set_governing_evaluation('40000000-0000-0000-0000-000000000022', '40000000-0000-0000-0000-000000000023', 'QUALIFIED');
insert into connection (id, operator_id, person_id, external_profile_id) values
  ('40000000-0000-0000-0000-000000000024', '40000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000020', '40000000-0000-0000-0000-000000000021');
select create_connection_note_and_mark_ready(
  '40000000-0000-0000-0000-000000000024', '40000000-0000-0000-0000-000000000022',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000023',
  'Hi -- would love to connect given our shared field.',
  'openrouter', 'test-model', 'connection-note/v1', 'trace-note-send-2'
);

do $$
declare
  v_attempt_id uuid;
begin
  v_attempt_id := claim_connection_for_sending('40000000-0000-0000-0000-000000000024', 'trace-send-2');
  perform mark_connection_attempt_send_attempted(v_attempt_id);
  perform record_connection_attempt_result(v_attempt_id, 'UNKNOWN', 'BROWSER_CRASHED', 'browser closed mid-action', '{}'::jsonb);
  create temporary table if not exists tmp_attempt_id_2 (id uuid);
  insert into tmp_attempt_id_2 values (v_attempt_id);
end $$;
-- 10: the attempt is UNKNOWN_SEND_RESULT and the connection mirrors it.
select is(
  (select request_state from connection where id = '40000000-0000-0000-0000-000000000024'),
  'UNKNOWN_SEND_RESULT',
  'recording an UNKNOWN result puts the connection in UNKNOWN_SEND_RESULT (CONTRACT.md sec.47)'
);
-- 11: reconciling resolves it to a real terminal outcome.
select reconcile_connection_attempt((select id from tmp_attempt_id_2), 'ALREADY_CONNECTED', 'checked profile manually, already connected');
select is(
  (select state from connection_attempt where id = (select id from tmp_attempt_id_2)),
  'ALREADY_CONNECTED',
  'reconciliation resolves an UNKNOWN_SEND_RESULT attempt to its true outcome'
);
select is(
  (select request_state from connection where id = '40000000-0000-0000-0000-000000000024'),
  'ALREADY_CONNECTED',
  'reconciliation updates the connection to the resolved outcome'
);
-- 12: reconciling an already-resolved attempt is rejected (no double reconciliation).
select throws_ok(
  format($$ select reconcile_connection_attempt(%L, 'SENT', 'trying again') $$, (select id from tmp_attempt_id_2)),
  'P0001', null, 'reconciling an attempt that is no longer UNKNOWN_SEND_RESULT is rejected'
);
-- 13: the reconciliation notes were preserved in result_metadata.
select isnt(
  (select result_metadata ->> 'reconciliation_notes' from connection_attempt where id = (select id from tmp_attempt_id_2)),
  null,
  'reconciliation notes are preserved in the attempt''s result_metadata'
);

-- 14: a FAILED result is also reachable end to end (distinct fixture to avoid state clashes).
insert into person (id, display_name) values
  ('40000000-0000-0000-0000-000000000030', 'Send Test Person 3');
insert into external_profile (id, person_id, platform, external_id) values
  ('40000000-0000-0000-0000-000000000031', '40000000-0000-0000-0000-000000000030', 'linkedin', 'send-ext-3');
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id, state) values
  ('40000000-0000-0000-0000-000000000032', '40000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000030', '40000000-0000-0000-0000-000000000031', 'EVALUATED');
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '40000000-0000-0000-0000-000000000033', '40000000-0000-0000-0000-000000000032',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000006', 'COMPLETE',
  90, 90, 90, 90, 90, true, now()
);
select set_governing_evaluation('40000000-0000-0000-0000-000000000032', '40000000-0000-0000-0000-000000000033', 'QUALIFIED');
insert into connection (id, operator_id, person_id, external_profile_id) values
  ('40000000-0000-0000-0000-000000000034', '40000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000030', '40000000-0000-0000-0000-000000000031');
select create_connection_note_and_mark_ready(
  '40000000-0000-0000-0000-000000000034', '40000000-0000-0000-0000-000000000032',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000033',
  'Hi -- would love to connect given our shared field.',
  'openrouter', 'test-model', 'connection-note/v1', 'trace-note-send-3'
);
do $$
declare
  v_attempt_id uuid;
begin
  v_attempt_id := claim_connection_for_sending('40000000-0000-0000-0000-000000000034', 'trace-send-3');
  perform mark_connection_attempt_send_attempted(v_attempt_id);
  perform record_connection_attempt_result(v_attempt_id, 'FAILED', 'INVALID_PROFILE', 'profile no longer exists', '{}'::jsonb);
end $$;
select is(
  (select request_state from connection where id = '40000000-0000-0000-0000-000000000034'),
  'FAILED',
  'recording a FAILED result finalizes the connection as FAILED'
);

-- 15: a stale evaluation blocks claiming even with an active note. evaluation is
-- append-only (Phase 0A), so this uses a dedicated fresh fixture with a backdated
-- created_at at INSERT time, rather than trying to mutate an existing evaluation row.
insert into person (id, display_name) values
  ('40000000-0000-0000-0000-000000000040', 'Send Test Person 4');
insert into external_profile (id, person_id, platform, external_id) values
  ('40000000-0000-0000-0000-000000000041', '40000000-0000-0000-0000-000000000040', 'linkedin', 'send-ext-4');
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id, state) values
  ('40000000-0000-0000-0000-000000000042', '40000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000040', '40000000-0000-0000-0000-000000000041', 'EVALUATED');
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '40000000-0000-0000-0000-000000000043', '40000000-0000-0000-0000-000000000042',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000006', 'COMPLETE',
  90, 90, 90, 90, 90, true, now() - interval '31 days'
);
select set_governing_evaluation('40000000-0000-0000-0000-000000000042', '40000000-0000-0000-0000-000000000043', 'QUALIFIED');
insert into connection (id, operator_id, person_id, external_profile_id) values
  ('40000000-0000-0000-0000-000000000044', '40000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000040', '40000000-0000-0000-0000-000000000041');
-- Note creation itself only requires the evaluation to be fresh AT CREATION TIME -- but
-- since this evaluation was already 31 days old when created, note creation itself must
-- also correctly refuse it (a useful additional confirmation, not just claim-time).
select throws_ok(
  $$ select create_connection_note_and_mark_ready(
       '40000000-0000-0000-0000-000000000044', '40000000-0000-0000-0000-000000000042',
       '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000043',
       'some note', 'openrouter', 'test-model', 'connection-note/v1', 'trace-note-send-4'
     ) $$,
  'P0001', null, 'note creation itself refuses an evaluation that is already stale at creation time'
);

-- === Explicit FAILED retry (review Finding 2): retrying reuses the same note but creates
-- a genuinely new attempt, and never erases the original failed attempt's history. ===

-- 16: retry_failed_connection_attempt resets the FAILED connection back to NOTE_READY.
select retry_failed_connection_attempt('40000000-0000-0000-0000-000000000034');
select is(
  (select request_state from connection where id = '40000000-0000-0000-0000-000000000034'),
  'NOTE_READY',
  'retry_failed_connection_attempt resets a FAILED connection back to NOTE_READY'
);

-- 17: retrying again immediately (now NOTE_READY, not FAILED) is rejected.
select throws_ok(
  $$ select retry_failed_connection_attempt('40000000-0000-0000-0000-000000000034') $$,
  'P0001', null, 'retrying a connection that is not currently FAILED is rejected'
);

do $$
declare
  v_first_attempt_id uuid;
  v_second_attempt_id uuid;
begin
  select id into v_first_attempt_id from connection_attempt
    where connection_id = '40000000-0000-0000-0000-000000000034' and state = 'FAILED';
  v_second_attempt_id := claim_connection_for_sending('40000000-0000-0000-0000-000000000034', 'trace-send-3-retry');
  create temporary table if not exists tmp_retry_ids (first_id uuid, second_id uuid);
  insert into tmp_retry_ids values (v_first_attempt_id, v_second_attempt_id);
end $$;
-- 18: claiming after retry creates a genuinely new second attempt, not a replay of the first.
select isnt(
  (select second_id from tmp_retry_ids),
  (select first_id from tmp_retry_ids),
  'claiming after an explicit retry creates a genuinely new attempt (CONTRACT.md sec.65)'
);
-- 19: the new attempt is numbered 2, keyed off the note's next attempt_number.
select is(
  (select attempt_number from connection_attempt where id = (select second_id from tmp_retry_ids)),
  2,
  'the new attempt after retry has attempt_number 2'
);
-- 20: the original FAILED attempt's history is preserved untouched, not erased or reused.
select is(
  (select state from connection_attempt where id = (select first_id from tmp_retry_ids)),
  'FAILED',
  'the original FAILED attempt row is preserved untouched after an explicit retry'
);

-- === Operator daily send limit (review Finding 1, CONTRACT.md sec.48). By this point at
-- least four real attempts have already been created today for this operator, so a limit
-- of 1 is already exceeded regardless of exact prior count. ===
update operator set max_daily_connection_sends = 1
  where id = '40000000-0000-0000-0000-000000000001';

insert into person (id, display_name) values
  ('40000000-0000-0000-0000-000000000050', 'Send Test Person 5');
insert into external_profile (id, person_id, platform, external_id) values
  ('40000000-0000-0000-0000-000000000051', '40000000-0000-0000-0000-000000000050', 'linkedin', 'send-ext-5');
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id, state) values
  ('40000000-0000-0000-0000-000000000052', '40000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000050', '40000000-0000-0000-0000-000000000051', 'EVALUATED');
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '40000000-0000-0000-0000-000000000053', '40000000-0000-0000-0000-000000000052',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000006', 'COMPLETE',
  90, 90, 90, 90, 90, true, now()
);
select set_governing_evaluation('40000000-0000-0000-0000-000000000052', '40000000-0000-0000-0000-000000000053', 'QUALIFIED');
insert into connection (id, operator_id, person_id, external_profile_id) values
  ('40000000-0000-0000-0000-000000000054', '40000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000050', '40000000-0000-0000-0000-000000000051');
select create_connection_note_and_mark_ready(
  '40000000-0000-0000-0000-000000000054', '40000000-0000-0000-0000-000000000052',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000053',
  'Hi -- would love to connect given our shared field.',
  'openrouter', 'test-model', 'connection-note/v1', 'trace-note-send-5'
);
-- 21: claiming beyond the operator's daily limit is rejected.
select throws_ok(
  $$ select claim_connection_for_sending('40000000-0000-0000-0000-000000000054', 'trace-send-5') $$,
  'P0001', null, 'claiming beyond max_daily_connection_sends is rejected (DAILY_SEND_LIMIT_REACHED)'
);

-- === Operator send window (review Finding 1, CONTRACT.md sec.48). Uncap the daily limit
-- so the window check (which runs first) is what's actually exercised, and set a 1-hour
-- window exactly 12 hours away from the current UTC hour, which by construction can never
-- contain the current hour. ===
do $$
declare
  v_current_hour integer := extract(hour from (now() at time zone 'UTC'))::integer;
  v_window_start integer := (v_current_hour + 12) % 24;
  v_window_end integer := (v_window_start + 1) % 24;
begin
  update operator
  set max_daily_connection_sends = null,
      send_window_start_hour_utc = v_window_start,
      send_window_end_hour_utc = v_window_end
  where id = '40000000-0000-0000-0000-000000000001';
end $$;

insert into person (id, display_name) values
  ('40000000-0000-0000-0000-000000000060', 'Send Test Person 6');
insert into external_profile (id, person_id, platform, external_id) values
  ('40000000-0000-0000-0000-000000000061', '40000000-0000-0000-0000-000000000060', 'linkedin', 'send-ext-6');
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id, state) values
  ('40000000-0000-0000-0000-000000000062', '40000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000060', '40000000-0000-0000-0000-000000000061', 'EVALUATED');
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '40000000-0000-0000-0000-000000000063', '40000000-0000-0000-0000-000000000062',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000006', 'COMPLETE',
  90, 90, 90, 90, 90, true, now()
);
select set_governing_evaluation('40000000-0000-0000-0000-000000000062', '40000000-0000-0000-0000-000000000063', 'QUALIFIED');
insert into connection (id, operator_id, person_id, external_profile_id) values
  ('40000000-0000-0000-0000-000000000064', '40000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000060', '40000000-0000-0000-0000-000000000061');
select create_connection_note_and_mark_ready(
  '40000000-0000-0000-0000-000000000064', '40000000-0000-0000-0000-000000000062',
  '40000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000063',
  'Hi -- would love to connect given our shared field.',
  'openrouter', 'test-model', 'connection-note/v1', 'trace-note-send-6'
);
-- 22: claiming outside the operator's allowed send window is rejected.
select throws_ok(
  $$ select claim_connection_for_sending('40000000-0000-0000-0000-000000000064', 'trace-send-6') $$,
  'P0001', null, 'claiming outside the operator''s allowed send window is rejected (OUTSIDE_SEND_WINDOW)'
);

select * from finish();

rollback;
