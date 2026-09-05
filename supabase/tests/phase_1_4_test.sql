-- Phase 1.4 database tests (CONTRACT.md sec.25,41.1,44,75,94). Run inside a transaction
-- that always rolls back, so this is safe to run repeatedly against the shared
-- linkedin_automation development project without leaving residue. All fixture data is
-- synthetic (CONTRACT.md sec.67.1).

begin;

select plan(15);

insert into operator (id, display_name) values
  ('30000000-0000-0000-0000-000000000001', 'Note Test Operator');

-- === is_evaluation_fresh ===
insert into campaign (id, operator_id, name) values
  ('30000000-0000-0000-0000-000000000010', '30000000-0000-0000-0000-000000000001', 'Freshness Test Campaign');
insert into campaign_revision (id, campaign_id, version) values
  ('30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000010', 1);
insert into person (id, display_name) values
  ('30000000-0000-0000-0000-000000000012', 'Freshness Person');
insert into external_profile (id, person_id, platform, external_id) values
  ('30000000-0000-0000-0000-000000000013', '30000000-0000-0000-0000-000000000012', 'linkedin', 'fresh-ext-1');
insert into profile_snapshot (id, external_profile_id, source_provider, raw_data, normalized_data) values
  ('30000000-0000-0000-0000-000000000014', '30000000-0000-0000-0000-000000000013', 'synthetic_fixture', '{}'::jsonb, '{}'::jsonb);
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id) values
  ('30000000-0000-0000-0000-000000000015', '30000000-0000-0000-0000-000000000010',
   '30000000-0000-0000-0000-000000000012', '30000000-0000-0000-0000-000000000013');
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '30000000-0000-0000-0000-000000000016', '30000000-0000-0000-0000-000000000015',
  '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000014', 'COMPLETE',
  90, 90, 90, 90, 90, true, now()
);
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '30000000-0000-0000-0000-000000000017', '30000000-0000-0000-0000-000000000015',
  '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000014', 'COMPLETE',
  90, 90, 90, 90, 90, true, now() - interval '31 days'
);
-- 1: a just-created evaluation is fresh.
select ok(is_evaluation_fresh('30000000-0000-0000-0000-000000000016'), 'a just-created evaluation is fresh');
-- 2: an evaluation older than 30 days is not fresh.
select ok(not is_evaluation_fresh('30000000-0000-0000-0000-000000000017'), 'an evaluation older than 30 days is not fresh (CONTRACT.md sec.25)');

-- === create_connection_note_and_mark_ready: happy path ===
insert into connection (id, operator_id, person_id, external_profile_id) values
  ('30000000-0000-0000-0000-000000000020', '30000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000012', '30000000-0000-0000-0000-000000000013');
-- Advance the candidate through its required state progression (CONTRACT.md sec.17)
-- before it can reach QUALIFIED.
update campaign_candidate set state = 'SNAPSHOT_READY' where id = '30000000-0000-0000-0000-000000000015';
update campaign_candidate set state = 'EVALUATED' where id = '30000000-0000-0000-0000-000000000015';
-- current_evaluation_id must be set to the fresh evaluation for it to be "governing".
select set_governing_evaluation('30000000-0000-0000-0000-000000000015', '30000000-0000-0000-0000-000000000016', 'QUALIFIED');

do $$
declare
  v_note_id uuid;
begin
  v_note_id := create_connection_note_and_mark_ready(
    '30000000-0000-0000-0000-000000000020', '30000000-0000-0000-0000-000000000015',
    '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000016',
    'Hi -- noticed your work in the target field, would love to connect.',
    'openrouter', 'test-model', 'connection-note/v1', 'trace-note-1'
  );
  create temporary table if not exists tmp_note_id (id uuid);
  insert into tmp_note_id values (v_note_id);
end $$;

-- 3: the note was actually created with correct provenance.
select ok(
  (select id from tmp_note_id) is not null,
  'create_connection_note_and_mark_ready returns a new note id for a qualified, fresh, governing evaluation'
);
select is(
  (select prompt_version from connection_note where id = (select id from tmp_note_id)),
  'connection-note/v1',
  'the note persists its prompt_version provenance'
);
-- 4: the Connection reached NOTE_READY only now, tied to this exact note/evaluation.
select is(
  (select request_state from connection where id = '30000000-0000-0000-0000-000000000020'),
  'NOTE_READY',
  'the Connection reaches NOTE_READY only after the note is persisted (CONTRACT.md sec.94)'
);

-- === Rejections ===
-- 5: an INCOMPLETE evaluation cannot authorize a note.
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status
) values (
  '30000000-0000-0000-0000-000000000018', '30000000-0000-0000-0000-000000000015',
  '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000014', 'INCOMPLETE'
);
select throws_ok(
  $$ select create_connection_note_and_mark_ready(
       '30000000-0000-0000-0000-000000000020', '30000000-0000-0000-0000-000000000015',
       '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000018',
       'some note', 'openrouter', 'test-model', 'connection-note/v1', 'trace-note-2'
     ) $$,
  'P0001', null, 'an INCOMPLETE evaluation cannot authorize a connection note'
);
-- 6: a stale (>30 day) evaluation cannot authorize a note, even if it was qualified.
select throws_ok(
  format($$ select create_connection_note_and_mark_ready(
       '30000000-0000-0000-0000-000000000020', '30000000-0000-0000-0000-000000000015',
       '30000000-0000-0000-0000-000000000011', %L,
       'some note', 'openrouter', 'test-model', 'connection-note/v1', 'trace-note-3'
     ) $$, '30000000-0000-0000-0000-000000000017'),
  'P0001', null, 'a stale evaluation cannot authorize a connection note (CONTRACT.md sec.25,44)'
);
-- 7: an empty body is rejected.
select throws_ok(
  $$ select create_connection_note_and_mark_ready(
       '30000000-0000-0000-0000-000000000020', '30000000-0000-0000-0000-000000000015',
       '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000016',
       '   ', 'openrouter', 'test-model', 'connection-note/v1', 'trace-note-4'
     ) $$,
  'P0001', null, 'an empty/whitespace-only note body is rejected'
);

-- 8: an evaluation that is qualified and fresh but is NOT the candidate's current
-- governing evaluation (superseded by a newer one) cannot authorize a note.
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score, qualified, created_at
) values (
  '30000000-0000-0000-0000-000000000019', '30000000-0000-0000-0000-000000000015',
  '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000014', 'COMPLETE',
  95, 95, 95, 95, 95, true, now() + interval '1 minute'
);
select set_governing_evaluation('30000000-0000-0000-0000-000000000015', '30000000-0000-0000-0000-000000000019', 'QUALIFIED');
select throws_ok(
  $$ select create_connection_note_and_mark_ready(
       '30000000-0000-0000-0000-000000000020', '30000000-0000-0000-0000-000000000015',
       '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000016',
       'some note', 'openrouter', 'test-model', 'connection-note/v1', 'trace-note-5'
     ) $$,
  'P0001', null, 'a superseded (no-longer-governing) evaluation cannot authorize a note even if it was qualified and fresh'
);

-- === Note refresh: a second, valid call supersedes the earlier note ===
do $$
declare
  v_note_id uuid;
begin
  v_note_id := create_connection_note_and_mark_ready(
    '30000000-0000-0000-0000-000000000020', '30000000-0000-0000-0000-000000000015',
    '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000019',
    'Refreshed note using the newer evaluation.',
    'openrouter', 'test-model', 'connection-note/v1', 'trace-note-6'
  );
  create temporary table if not exists tmp_note_id_2 (id uuid);
  insert into tmp_note_id_2 values (v_note_id);
end $$;
-- 9: the original note is now superseded.
select isnt(
  (select superseded_at from connection_note where id = (select id from tmp_note_id)),
  null,
  'refreshing the note supersedes the previous active note (CONTRACT.md sec.41.1)'
);
-- 10: the Connection remains NOTE_READY (idempotent refresh, not a required NOT_PLANNED start).
select is(
  (select request_state from connection where id = '30000000-0000-0000-0000-000000000020'),
  'NOTE_READY',
  'refreshing the note keeps the Connection in NOTE_READY'
);

-- 11: a Connection not in NOT_PLANNED/NOTE_READY (e.g. already SENT) cannot be moved via
-- this function -- note refresh before a queued/sent request is a reconciliation concern
-- outside this function's scope. Uses a distinct Person: connection has a unique
-- (operator_id, person_id) constraint, so this cannot reuse the earlier fixture person.
insert into person (id, display_name) values
  ('30000000-0000-0000-0000-000000000022', 'Sent State Person');
insert into external_profile (id, person_id, platform, external_id) values
  ('30000000-0000-0000-0000-000000000023', '30000000-0000-0000-0000-000000000022', 'linkedin', 'sent-state-ext-1');
insert into connection (id, operator_id, person_id, external_profile_id, request_state) values
  ('30000000-0000-0000-0000-000000000021', '30000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000022', '30000000-0000-0000-0000-000000000023', 'SENT');
select throws_ok(
  $$ select create_connection_note_and_mark_ready(
       '30000000-0000-0000-0000-000000000021', '30000000-0000-0000-0000-000000000015',
       '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000019',
       'some note', 'openrouter', 'test-model', 'connection-note/v1', 'trace-note-7'
     ) $$,
  'P0001', null, 'a connection already past NOTE_READY (e.g. SENT) cannot be reset via this function'
);
-- Regression (independent review finding #3, CONTRACT.md sec.94 "note generation failure
-- is recoverable"): the rejected call above must leave no orphaned note and no state
-- change -- the connection stays exactly SENT, and no note row was created for it.
select is(
  (select request_state from connection where id = '30000000-0000-0000-0000-000000000021'),
  'SENT',
  'a rejected note-creation call leaves the connection state completely unchanged'
);
select is(
  (select count(*) from connection_note where connection_id = '30000000-0000-0000-0000-000000000021'),
  0::bigint,
  'a rejected note-creation call leaves no orphaned connection_note row behind'
);

-- Regression (independent review finding #2): a note body over LinkedIn's 300-character
-- connection-note limit is rejected at the database layer, not only by LLM instruction.
insert into person (id, display_name) values
  ('30000000-0000-0000-0000-000000000024', 'Long Note Person');
insert into external_profile (id, person_id, platform, external_id) values
  ('30000000-0000-0000-0000-000000000025', '30000000-0000-0000-0000-000000000024', 'linkedin', 'long-note-ext-1');
insert into connection (id, operator_id, person_id, external_profile_id) values
  ('30000000-0000-0000-0000-000000000026', '30000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000024', '30000000-0000-0000-0000-000000000025');
select throws_ok(
  format(
    $$ select create_connection_note_and_mark_ready(
         '30000000-0000-0000-0000-000000000026', '30000000-0000-0000-0000-000000000015',
         '30000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000019',
         %L, 'openrouter', 'test-model', 'connection-note/v1', 'trace-note-8'
       ) $$,
    repeat('x', 301)
  ),
  'P0001', null, 'a note body over 300 characters is rejected by the database, not only by LLM instruction'
);

select * from finish();

rollback;
