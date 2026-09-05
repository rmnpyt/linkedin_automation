-- Phase 1.2 database tests (CONTRACT.md sec.29,33,75,92). Run inside a transaction that
-- always rolls back, so this is safe to run repeatedly against the shared
-- linkedin_automation development project without leaving residue.
-- All fixture data is synthetic (CONTRACT.md sec.67.1).

begin;

select plan(27);

-- Fixtures shared by every test group below.
insert into operator (id, display_name) values
  ('10000000-0000-0000-0000-000000000001', 'Test Operator');
insert into campaign (id, operator_id, name) values
  ('10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Test Campaign');

-- 1: search_run table exists.
select has_table('public', 'search_run', 'search_run table exists');
-- 2: campaign_budget_reservation table exists.
select has_table('public', 'campaign_budget_reservation', 'campaign_budget_reservation table exists');
-- 3-4: core FKs.
select fk_ok('public', 'search_run', 'campaign_revision_id', 'public', 'campaign_revision', 'id',
  'search_run.campaign_revision_id references campaign_revision');
select fk_ok('public', 'campaign_budget_reservation', 'campaign_revision_id', 'public', 'campaign_revision', 'id',
  'campaign_budget_reservation.campaign_revision_id references campaign_revision');

-- === search_run freezes its campaign_revision on insert (same mechanism as evaluation) ===
insert into campaign_revision (id, campaign_id, version) values
  ('10000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000002', 1);
insert into search_run (campaign_id, campaign_revision_id, provider, trace_id)
values ('10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000010', 'harvestapi', 'trace-1');
-- 5:
select isnt(
  (select frozen_at from campaign_revision where id = '10000000-0000-0000-0000-000000000010'),
  null,
  'inserting a search_run freezes its campaign_revision'
);

-- === Budget reservation: type-limit blocking (revision A) ===
-- Each budget test group below gets its OWN campaign: since committed spend now correctly
-- aggregates by campaign_id (not campaign_revision_id -- see the campaign-wide-spend
-- regression test near the end of this file), reusing one campaign across these
-- otherwise-independent groups would make them interfere with each other's committed
-- totals.
insert into campaign (id, operator_id, name) values
  ('10000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Budget Test Campaign A');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '10000000-0000-0000-0000-000000000020', '10000000-0000-0000-0000-000000000003', 2,
  '{"max_search_cost_usd": 5, "max_total_campaign_cost_usd": 100}'::jsonb
);
-- 6: a within-limit reservation succeeds.
select ok(
  reserve_campaign_budget('10000000-0000-0000-0000-000000000020', 'SEARCH', 4, 'trace-a') is not null,
  'reservation within the type limit succeeds'
);
-- 7: a reservation that would push committed spend over the type limit is refused (returns null, not an exception).
select is(
  reserve_campaign_budget('10000000-0000-0000-0000-000000000020', 'SEARCH', 2, 'trace-a'),
  null,
  'a reservation exceeding the remaining type-specific budget returns null'
);

-- === Settling frees up headroom for later reservations ===
-- capture the id of the first reservation to settle it
do $$
declare
  v_id uuid;
begin
  select id into v_id from campaign_budget_reservation
  where campaign_revision_id = '10000000-0000-0000-0000-000000000020' and reserved_amount_usd = 4
  order by created_at asc limit 1;
  perform settle_campaign_budget_reservation(v_id, 1);
end $$;

-- 9: after settling the 4-reserved amount down to an actual cost of 1, a new 3-unit
-- reservation now fits (1 settled + 3 requested = 4 <= 5), which would not have fit while
-- the original 4 was still just RESERVED (4 reserved + 3 requested = 7 > 5).
select ok(
  reserve_campaign_budget('10000000-0000-0000-0000-000000000020', 'SEARCH', 3, 'trace-a') is not null,
  'settling a reservation to a lower actual cost frees up headroom for a later reservation'
);

-- === Budget reservation: total-limit blocking even when the type limit alone would allow it (revision B) ===
insert into campaign (id, operator_id, name) values
  ('10000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'Budget Test Campaign B');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '10000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000004', 3,
  '{"max_search_cost_usd": 100, "max_total_campaign_cost_usd": 5}'::jsonb
);
-- 10: within total limit succeeds.
select ok(
  reserve_campaign_budget('10000000-0000-0000-0000-000000000021', 'SEARCH', 4, 'trace-b') is not null,
  'reservation within the total-campaign limit succeeds'
);
-- 11: a second reservation of a DIFFERENT type, individually within its own (uncapped)
-- type limit, is still refused because it would push the TOTAL committed spend over the
-- total-campaign limit.
select is(
  reserve_campaign_budget('10000000-0000-0000-0000-000000000021', 'EVALUATION', 2, 'trace-b'),
  null,
  'a reservation within its own type limit is still refused if it would exceed the total-campaign limit'
);

-- === Releasing an unused reservation frees its committed amount ===
insert into campaign (id, operator_id, name) values
  ('10000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'Budget Test Campaign C');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '10000000-0000-0000-0000-000000000022', '10000000-0000-0000-0000-000000000005', 4,
  '{"max_search_cost_usd": 5, "max_total_campaign_cost_usd": 5}'::jsonb
);
do $$
declare
  v_id uuid;
begin
  v_id := reserve_campaign_budget('10000000-0000-0000-0000-000000000022', 'SEARCH', 5, 'trace-c');
  perform release_campaign_budget_reservation(v_id);
end $$;
-- 12: after releasing the full 5-unit reservation, a fresh 5-unit reservation fits again.
select ok(
  reserve_campaign_budget('10000000-0000-0000-0000-000000000022', 'SEARCH', 5, 'trace-c') is not null,
  'releasing a reservation frees its committed amount for a later reservation'
);

-- === settle_campaign_budget_reservation / release_campaign_budget_reservation guard rails ===
-- Uses its own revision with generous, independent budget headroom -- NOT revision 0022
-- above, whose total budget (5) is already fully consumed by that reservation's still-
-- RESERVED (never settled/released) 5-unit SEARCH reservation. Reusing it here would
-- correctly (and confusingly, for a guard-rail test) get blocked by the total-campaign
-- limit rather than exercising the "double settle" guard rail this test actually wants.
insert into campaign (id, operator_id, name) values
  ('10000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', 'Budget Test Campaign D');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '10000000-0000-0000-0000-000000000023', '10000000-0000-0000-0000-000000000006', 5,
  '{"max_search_cost_usd": 100, "max_total_campaign_cost_usd": 100}'::jsonb
);
-- 13: settling a reservation that does not exist raises.
select throws_ok(
  $$ select settle_campaign_budget_reservation('00000000-0000-0000-0000-000000009999', 1) $$,
  'P0001', null, 'settling a nonexistent reservation raises'
);
-- 14: settling the same reservation twice raises (already SETTLED, not RESERVED).
do $$
declare
  v_id uuid;
begin
  v_id := reserve_campaign_budget('10000000-0000-0000-0000-000000000023', 'EVALUATION', 1, 'trace-d');
  perform settle_campaign_budget_reservation(v_id, 1);
  create temporary table if not exists tmp_double_settle_id (id uuid);
  insert into tmp_double_settle_id values (v_id);
end $$;
select throws_ok(
  format($$ select settle_campaign_budget_reservation(%L, 1) $$, (select id from tmp_double_settle_id)),
  'P0001', null, 'settling an already-settled reservation raises'
);

-- === Identity resolution (CONTRACT.md sec.10) ===
-- 15: a brand-new external_id creates a new Person + ExternalProfile.
select ok(
  (select created from resolve_or_create_person_by_external_profile('linkedin', 'ext-alice-1', null, 'Alice Synthetic')),
  'a new external_id creates a new person+profile'
);
-- 16: calling again with the same external_id returns the same identity, created=false.
select is(
  (select created from resolve_or_create_person_by_external_profile('linkedin', 'ext-alice-1', null, 'Alice Synthetic')),
  false,
  'the same external_id resolves to the existing person+profile'
);
-- 17: the person_id is stable across both calls.
select is(
  (select person_id from resolve_or_create_person_by_external_profile('linkedin', 'ext-alice-1', null, 'Alice Synthetic')),
  (select person_id from resolve_or_create_person_by_external_profile('linkedin', 'ext-alice-1', null, 'ignored different name')),
  'person_id is stable for the same external_id regardless of a differing display_name argument'
);
-- 18: a DIFFERENT external_id with the SAME display_name creates a SEPARATE person --
-- name-only matching must never merge identities (CONTRACT.md sec.10).
select isnt(
  (select person_id from resolve_or_create_person_by_external_profile('linkedin', 'ext-alice-2', null, 'Alice Synthetic')),
  (select person_id from resolve_or_create_person_by_external_profile('linkedin', 'ext-alice-1', null, 'Alice Synthetic')),
  'a different external_id with the same display_name creates a distinct person (no name-only merge)'
);
-- 19: canonical_url fallback matching works when no external_id is available.
select ok(
  (select created from resolve_or_create_person_by_external_profile('linkedin', null, 'https://linkedin.com/in/bob-synthetic', 'Bob Synthetic')),
  'a profile with only a canonical_url (no external_id) is created'
);
select is(
  (select created from resolve_or_create_person_by_external_profile('linkedin', null, 'https://linkedin.com/in/bob-synthetic', 'Bob Synthetic')),
  false,
  'the same canonical_url resolves to the existing person+profile when no external_id is given'
);
-- 20: requesting resolution with neither identifier is rejected.
select throws_ok(
  $$ select resolve_or_create_person_by_external_profile('linkedin', null, null, 'Nobody') $$,
  'P0001', null, 'resolving with neither external_id nor canonical_url raises'
);

-- Regression (independent review finding #2): an empty-string external_id must be treated
-- as absent, never as a real shared identifier that would merge unrelated people.
select throws_ok(
  $$ select resolve_or_create_person_by_external_profile('linkedin', '', null, 'Empty Ext Id') $$,
  'P0001', null, 'an empty-string external_id with no canonical_url is treated as absent and raises'
);
select isnt(
  (select person_id from resolve_or_create_person_by_external_profile('linkedin', '', 'https://linkedin.com/in/empty-ext-a', 'Empty Ext A')),
  (select person_id from resolve_or_create_person_by_external_profile('linkedin', '', 'https://linkedin.com/in/empty-ext-b', 'Empty Ext B')),
  'two different profiles both passing external_id='''' are never merged into one person'
);

-- === Unique-candidate cap enforcement (CONTRACT.md sec.29) ===
insert into campaign (id, operator_id, name) values
  ('10000000-0000-0000-0000-000000000030', '10000000-0000-0000-0000-000000000001', 'Cap Test Campaign');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '10000000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000030', 1,
  '{"max_unique_candidates": 2}'::jsonb
);
insert into person (id, display_name) values
  ('10000000-0000-0000-0000-000000000040', 'Cap Person 1'),
  ('10000000-0000-0000-0000-000000000041', 'Cap Person 2'),
  ('10000000-0000-0000-0000-000000000042', 'Cap Person 3');
insert into external_profile (id, person_id, platform, external_id) values
  ('10000000-0000-0000-0000-000000000050', '10000000-0000-0000-0000-000000000040', 'linkedin', 'cap-ext-1'),
  ('10000000-0000-0000-0000-000000000051', '10000000-0000-0000-0000-000000000041', 'linkedin', 'cap-ext-2'),
  ('10000000-0000-0000-0000-000000000052', '10000000-0000-0000-0000-000000000042', 'linkedin', 'cap-ext-3');

-- 21: first candidate is created.
select ok(
  (select created from resolve_or_create_campaign_candidate(
    '10000000-0000-0000-0000-000000000030', '10000000-0000-0000-0000-000000000031',
    '10000000-0000-0000-0000-000000000040', '10000000-0000-0000-0000-000000000050'
  )),
  'first candidate under the cap is created'
);
-- 22: calling again for the same person is idempotent (created=false, no duplicate).
select is(
  (select created from resolve_or_create_campaign_candidate(
    '10000000-0000-0000-0000-000000000030', '10000000-0000-0000-0000-000000000031',
    '10000000-0000-0000-0000-000000000040', '10000000-0000-0000-0000-000000000050'
  )),
  false,
  'resolving the same candidate again is idempotent'
);
-- 23: second distinct candidate reaches the cap (max_unique_candidates=2) and is still created.
select ok(
  (select created from resolve_or_create_campaign_candidate(
    '10000000-0000-0000-0000-000000000030', '10000000-0000-0000-0000-000000000031',
    '10000000-0000-0000-0000-000000000041', '10000000-0000-0000-0000-000000000051'
  )),
  'second distinct candidate reaches the configured cap and is created'
);
-- 24: a third distinct candidate would exceed the cap and is rejected.
select throws_ok(
  $$ select resolve_or_create_campaign_candidate(
       '10000000-0000-0000-0000-000000000030', '10000000-0000-0000-0000-000000000031',
       '10000000-0000-0000-0000-000000000042', '10000000-0000-0000-0000-000000000052'
     ) $$,
  'P0001', null, 'a candidate beyond max_unique_candidates is rejected even for a distinct new person'
);

-- Regression (independent review finding): committed spend aggregates across the WHOLE
-- Campaign, not just the requesting revision -- an unrelated revision bump (CONTRACT.md
-- sec.14 forces one on ANY material change, not only a budget-policy change) must not
-- silently reset the spend counter to zero, which would make a hard cap bypassable
-- (CONTRACT.md sec.30).
insert into campaign (id, operator_id, name) values
  ('10000000-0000-0000-0000-000000000060', '10000000-0000-0000-0000-000000000001', 'Campaign-Wide Budget Test Campaign');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '10000000-0000-0000-0000-000000000061', '10000000-0000-0000-0000-000000000060', 1,
  '{"max_search_cost_usd": 5, "max_total_campaign_cost_usd": 100}'::jsonb
);
select reserve_campaign_budget('10000000-0000-0000-0000-000000000061', 'SEARCH', 4, 'trace-f1');
-- A new revision for the SAME campaign (e.g. an unrelated field changed); budget_policy
-- carries the same max_search_cost_usd forward unchanged.
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '10000000-0000-0000-0000-000000000062', '10000000-0000-0000-0000-000000000060', 2,
  '{"max_search_cost_usd": 5, "max_total_campaign_cost_usd": 100}'::jsonb
);
-- 25: a request that fits within the NEW revision's own (unused) allotment, but would
-- exceed the campaign's true combined spend (4 already committed + 2 requested = 6 > 5),
-- is correctly refused.
select is(
  reserve_campaign_budget('10000000-0000-0000-0000-000000000062', 'SEARCH', 2, 'trace-f2'),
  null,
  'spend committed under an earlier revision of the same campaign still counts against a later revision''s limit'
);

select * from finish();

rollback;
