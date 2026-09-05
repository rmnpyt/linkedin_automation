-- Phase 0A database tests (CONTRACT.md sec.75,89). Run inside a transaction that always
-- rolls back, so this is safe to run repeatedly against the shared linkedin_automation
-- development project without leaving residue.
--
-- Run with: psql -f supabase/tests/phase_0a_test.sql, or paste the body between
-- BEGIN/ROLLBACK into any Postgres client connected to the target database.
-- All fixture data below is synthetic (CONTRACT.md sec.67.1 personal-data minimization).

begin;

select plan(35);

-- 1-9: core tables exist.
select has_table('public', 'operator', 'operator table exists');
select has_table('public', 'person', 'person table exists');
select has_table('public', 'external_profile', 'external_profile table exists');
select has_table('public', 'campaign_revision', 'campaign_revision table exists');
select has_table('public', 'campaign_candidate', 'campaign_candidate table exists');
select has_table('public', 'evaluation', 'evaluation table exists');
select has_table('public', 'contact_point', 'contact_point table exists');
select has_table('public', 'connection', 'connection table exists');
select has_table('public', 'connection_attempt', 'connection_attempt table exists');

-- 10-13: core foreign keys exist (CONTRACT.md sec.89 "core schema exists").
select fk_ok('public', 'campaign_candidate', 'campaign_id', 'public', 'campaign', 'id',
  'campaign_candidate.campaign_id references campaign');
select fk_ok('public', 'evaluation', 'campaign_revision_id', 'public', 'campaign_revision', 'id',
  'evaluation.campaign_revision_id references campaign_revision');
select fk_ok('public', 'evaluation', 'profile_snapshot_id', 'public', 'profile_snapshot', 'id',
  'evaluation.profile_snapshot_id references profile_snapshot');
select fk_ok('public', 'connection_attempt', 'connection_note_id', 'public', 'connection_note', 'id',
  'connection_attempt.connection_note_id references connection_note');

-- Fixtures: one operator, one person, one external profile, one snapshot, one campaign.
insert into operator (id, display_name) values
  ('00000000-0000-0000-0000-000000000001', 'Test Operator');
insert into person (id, display_name) values
  ('00000000-0000-0000-0000-000000000002', 'Test Person A'),
  ('00000000-0000-0000-0000-000000000003', 'Test Person B');
insert into external_profile (id, person_id, platform, external_id) values
  ('00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000002', 'linkedin', 'ext-a-1');
insert into profile_snapshot (id, external_profile_id, source_provider, raw_data, normalized_data) values
  ('00000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000004',
   'synthetic_fixture', '{"headline":"Software Engineer"}'::jsonb, '{"headline":"Software Engineer"}'::jsonb);
insert into campaign (id, operator_id, name) values
  ('00000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', 'Test Campaign');
insert into campaign_revision (id, campaign_id, version) values
  ('00000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000006', 1);

-- 14: CampaignRevision uniqueness/versioning (CONTRACT.md sec.14, sec.301).
select throws_ok(
  $$ insert into campaign_revision (campaign_id, version)
     values ('00000000-0000-0000-0000-000000000006', 1) $$,
  '23505',
  null,
  'duplicate (campaign_id, version) is rejected'
);

-- Candidate lifecycle fixture.
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id) values
  ('00000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000006',
   '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000004');

-- 15: duplicate CampaignCandidate prevention (CONTRACT.md sec.15).
select throws_ok(
  $$ insert into campaign_candidate (campaign_id, person_id, external_profile_id)
     values ('00000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000002',
             '00000000-0000-0000-0000-000000000004') $$,
  '23505',
  null,
  'duplicate (campaign_id, person_id) CampaignCandidate is rejected'
);

-- 15b: the CHECK constraint itself rejects an invalid state value on INSERT, where the
-- transition trigger has no prior state to compare against (tg_op = 'INSERT' short-circuits).
select throws_ok(
  $$ insert into campaign_candidate (campaign_id, person_id, external_profile_id, state)
     values ('00000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000003',
             '00000000-0000-0000-0000-000000000004', 'NOT_A_REAL_STATE') $$,
  '23514',
  null,
  'invalid campaign_candidate state value is rejected on insert (CHECK constraint)'
);

-- 16: invalid state value rejected on UPDATE (CONTRACT.md sec.16). The state-transition trigger
-- (BEFORE UPDATE) runs before CHECK constraints are validated, so an unknown value is
-- rejected as an invalid transition (P0001) rather than reaching the CHECK violation
-- (23514) -- the CHECK still guards plain INSERTs, where no prior state exists to compare.
select throws_ok(
  $$ update campaign_candidate set state = 'NOT_A_REAL_STATE'
     where id = '00000000-0000-0000-0000-000000000008' $$,
  'P0001',
  null,
  'invalid campaign_candidate state value is rejected'
);

-- 17: invalid state transition rejected (skips SNAPSHOT_READY -> EVALUATED path).
select throws_ok(
  $$ update campaign_candidate set state = 'QUALIFIED'
     where id = '00000000-0000-0000-0000-000000000008' $$,
  'P0001',
  null,
  'DISCOVERED -> QUALIFIED direct transition is rejected'
);

-- 18: valid transition sequence is accepted.
update campaign_candidate set state = 'SNAPSHOT_READY' where id = '00000000-0000-0000-0000-000000000008';
update campaign_candidate set state = 'EVALUATED' where id = '00000000-0000-0000-0000-000000000008';
select is(
  (select state from campaign_candidate where id = '00000000-0000-0000-0000-000000000008'),
  'EVALUATED',
  'valid DISCOVERED -> SNAPSHOT_READY -> EVALUATED transition succeeds'
);

-- 19: a COMPLETE evaluation with only KPI 5 missing is accepted (KPI-FRAMEWORK.md).
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_5_score, kpi_6_score,
  composite_score, hard_filter_passed, qualified, qualification_threshold
) values (
  '00000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000005', 'COMPLETE',
  90, 100, 85, 90, null, 70,
  88.0, true, true, 60
);
select lives_ok(
  $$ select 1 $$,
  'COMPLETE evaluation with only KPI 5 null was accepted (fixture above did not throw)'
);

-- 20: a COMPLETE evaluation missing a non-KPI-5 score is rejected (CONTRACT.md sec.20.1).
select throws_ok(
  $$ insert into evaluation (
       campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
       kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score
     ) values (
       '00000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000007',
       '00000000-0000-0000-0000-000000000005', 'COMPLETE',
       null, 100, 85, 90, 70
     ) $$,
  '23514',
  null,
  'COMPLETE evaluation missing KPI 1 is rejected (only KPI 5 may be missing)'
);

-- 21: evaluation is append-only (CONTRACT.md sec.12, sec.300).
select throws_ok(
  $$ update evaluation set composite_score = 0 where id = '00000000-0000-0000-0000-000000000009' $$,
  'P0001',
  null,
  'evaluation rows cannot be updated (append-only)'
);
select throws_ok(
  $$ delete from evaluation where id = '00000000-0000-0000-0000-000000000009' $$,
  'P0001',
  null,
  'evaluation rows cannot be deleted (append-only)'
);

-- 22: inserting the evaluation froze its campaign_revision (CONTRACT.md sec.14).
select isnt(
  (select frozen_at from campaign_revision where id = '00000000-0000-0000-0000-000000000007'),
  null,
  'campaign_revision was auto-frozen by the evaluation insert'
);

-- 23: a frozen campaign_revision rejects material edits (CONTRACT.md sec.14).
select throws_ok(
  $$ update campaign_revision set qualification_threshold = 70
     where id = '00000000-0000-0000-0000-000000000007' $$,
  'P0001',
  null,
  'frozen campaign_revision rejects a material policy edit'
);

-- 24: set_governing_evaluation applies a real update and moves candidate state
-- (CONTRACT.md sec.15,17).
select ok(
  set_governing_evaluation(
    '00000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000009', 'QUALIFIED'
  ),
  'set_governing_evaluation applies a fresh evaluation'
);
select is(
  (select state from campaign_candidate where id = '00000000-0000-0000-0000-000000000008'),
  'QUALIFIED',
  'candidate state updated to QUALIFIED by set_governing_evaluation'
);

-- 25: a stale (older) evaluation is refused by set_governing_evaluation rather than
-- overwriting the newer governing decision (CONTRACT.md sec.15,17).
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score,
  qualified, created_at
) values (
  '0000000a-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000005', 'COMPLETE',
  40, 40, 40, 40, 40, false,
  now() - interval '1 day'
);
select is(
  set_governing_evaluation(
    '00000000-0000-0000-0000-000000000008', '0000000a-0000-0000-0000-000000000001', 'DISQUALIFIED'
  ),
  false,
  'a stale/older evaluation is refused by set_governing_evaluation'
);
select is(
  (select state from campaign_candidate where id = '00000000-0000-0000-0000-000000000008'),
  'QUALIFIED',
  'candidate state is unchanged after a stale governing-evaluation attempt'
);

-- Regression tests below cover findings from the Phase 0A independent review, each fixed
-- before commit (CONTRACT.md sec.17,69,14).

-- Regression (review finding #1): a genuinely NEWER evaluation can flip a candidate from
-- QUALIFIED to DISQUALIFIED. Previously the transition table omitted this pair entirely,
-- so any real re-evaluation that disqualified a previously-qualified candidate would fail.
insert into evaluation (
  id, campaign_candidate_id, campaign_revision_id, profile_snapshot_id, status,
  kpi_1_score, kpi_2_score, kpi_3_score, kpi_4_score, kpi_6_score,
  qualified, created_at
) values (
  '0000000a-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000005', 'COMPLETE',
  10, 10, 10, 10, 10, false,
  now() + interval '1 day'
);
select is(
  set_governing_evaluation(
    '00000000-0000-0000-0000-000000000008', '0000000a-0000-0000-0000-000000000002', 'DISQUALIFIED'
  ),
  true,
  'a genuinely newer evaluation can flip QUALIFIED -> DISQUALIFIED'
);
select is(
  (select state from campaign_candidate where id = '00000000-0000-0000-0000-000000000008'),
  'DISQUALIFIED',
  'candidate state reflects the newer DISQUALIFIED evaluation'
);

-- Regression (review finding #2): staleness is enforced on campaign_candidate itself, not
-- only inside set_governing_evaluation -- a raw UPDATE that bypasses the RPC must also be
-- rejected when it tries to move current_evaluation_id backwards.
select throws_ok(
  $$ update campaign_candidate
     set current_evaluation_id = '0000000a-0000-0000-0000-000000000001', state = 'DISQUALIFIED'
     where id = '00000000-0000-0000-0000-000000000008' $$,
  'P0001',
  null,
  'a raw UPDATE cannot move current_evaluation_id back to an older evaluation'
);

-- Regression (review finding #3): freezing a campaign_revision cannot be combined with a
-- material policy edit in the same statement.
insert into campaign_revision (id, campaign_id, version) values
  ('0000000b-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000006', 2);
select throws_ok(
  $$ update campaign_revision set frozen_at = now(), qualification_threshold = 99
     where id = '0000000b-0000-0000-0000-000000000001' $$,
  'P0001',
  null,
  'freezing and materially editing a campaign_revision in the same statement is rejected'
);

-- 26: ContactPoint duplicate prevention (CONTRACT.md sec.37).
insert into contact_point (person_id, type, value, normalized_value, source_provider) values
  ('00000000-0000-0000-0000-000000000002', 'email', 'a@example.test', 'a@example.test', 'synthetic_fixture');
select throws_ok(
  $$ insert into contact_point (person_id, type, value, normalized_value, source_provider)
     values ('00000000-0000-0000-0000-000000000002', 'email', 'A@Example.test', 'a@example.test', 'synthetic_fixture') $$,
  '23505',
  null,
  'duplicate (person_id, type, normalized_value) ContactPoint is rejected'
);

-- 27: ExternalProfile identity uniqueness (CONTRACT.md sec.11).
select throws_ok(
  $$ insert into external_profile (person_id, platform, external_id)
     values ('00000000-0000-0000-0000-000000000003', 'linkedin', 'ext-a-1') $$,
  '23505',
  null,
  'duplicate (platform, external_id) ExternalProfile is rejected'
);

select * from finish();

rollback;
