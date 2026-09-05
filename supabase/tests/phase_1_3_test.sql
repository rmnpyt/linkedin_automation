-- Phase 1.3 database tests (CONTRACT.md sec.39,75). Run inside a transaction that always
-- rolls back, so this is safe to run repeatedly against the shared linkedin_automation
-- development project without leaving residue. All fixture data is synthetic
-- (CONTRACT.md sec.67.1).

begin;

select plan(7);

insert into operator (id, display_name) values
  ('20000000-0000-0000-0000-000000000001', 'Enrichment Test Operator');
insert into person (id, display_name) values
  ('20000000-0000-0000-0000-000000000003', 'Enrichment Person 1'),
  ('20000000-0000-0000-0000-000000000004', 'Enrichment Person 2'),
  ('20000000-0000-0000-0000-000000000005', 'Enrichment Person 3');
insert into external_profile (id, person_id, platform, external_id) values
  ('20000000-0000-0000-0000-000000000013', '20000000-0000-0000-0000-000000000003', 'linkedin', 'enrich-ext-1'),
  ('20000000-0000-0000-0000-000000000014', '20000000-0000-0000-0000-000000000004', 'linkedin', 'enrich-ext-2'),
  ('20000000-0000-0000-0000-000000000015', '20000000-0000-0000-0000-000000000005', 'linkedin', 'enrich-ext-3');

-- Each test group below gets its OWN campaign: since the count cap correctly aggregates
-- by campaign_id (not campaign_revision_id -- see the campaign-wide-cap regression test
-- near the end of this file), reusing one campaign across these otherwise-independent
-- groups would make them interfere with each other's counts.
insert into campaign (id, operator_id, name) values
  ('20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'Enrichment Test Campaign 1');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '20000000-0000-0000-0000-000000000020', '20000000-0000-0000-0000-000000000002', 1,
  '{"max_email_enrichments": 2}'::jsonb
);
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id) values
  ('20000000-0000-0000-0000-000000000030', '20000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000013'),
  ('20000000-0000-0000-0000-000000000031', '20000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000014'),
  ('20000000-0000-0000-0000-000000000032', '20000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000015');

-- 1: first attempt under the cap succeeds.
select ok(
  claim_contact_enrichment_attempt(
    '20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000020',
    '20000000-0000-0000-0000-000000000030', '20000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000013', 'harvestapi', 'trace-e1'
  ) is not null,
  'first enrichment attempt under the cap succeeds'
);
-- 2: second attempt reaches the cap (max=2) and still succeeds.
select ok(
  claim_contact_enrichment_attempt(
    '20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000020',
    '20000000-0000-0000-0000-000000000031', '20000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000014', 'harvestapi', 'trace-e2'
  ) is not null,
  'second enrichment attempt reaches the configured cap and succeeds'
);
-- 3: a third attempt beyond the cap is refused (returns NULL, not an exception -- email
-- enrichment is optional/non-blocking, CONTRACT.md sec.40, so the caller must be able to
-- skip cleanly rather than have a whole batch aborted).
select is(
  claim_contact_enrichment_attempt(
    '20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000020',
    '20000000-0000-0000-0000-000000000032', '20000000-0000-0000-0000-000000000005',
    '20000000-0000-0000-0000-000000000015', 'harvestapi', 'trace-e3'
  ),
  null,
  'a third enrichment attempt beyond max_email_enrichments returns null'
);

-- === A BUDGET_BLOCKED attempt never executed, so it must not consume count capacity ===
insert into campaign (id, operator_id, name) values
  ('20000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001', 'Enrichment Test Campaign 2');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '20000000-0000-0000-0000-000000000021', '20000000-0000-0000-0000-000000000006', 2,
  '{"max_email_enrichments": 1}'::jsonb
);
insert into contact_enrichment_attempt (
  campaign_id, campaign_revision_id, campaign_candidate_id, person_id, external_profile_id,
  provider, state
) values (
  '20000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000021',
  '20000000-0000-0000-0000-000000000030', '20000000-0000-0000-0000-000000000003',
  '20000000-0000-0000-0000-000000000013', 'harvestapi', 'BUDGET_BLOCKED'
);
-- 4: despite one existing BUDGET_BLOCKED row, the (still-empty-of-real-attempts) cap of 1
-- allows a real attempt to proceed.
select ok(
  claim_contact_enrichment_attempt(
    '20000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000021',
    '20000000-0000-0000-0000-000000000031', '20000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000014', 'harvestapi', 'trace-e4'
  ) is not null,
  'a BUDGET_BLOCKED attempt does not consume max_email_enrichments count capacity'
);
-- 5: a second real attempt now correctly hits the cap of 1.
select is(
  claim_contact_enrichment_attempt(
    '20000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000021',
    '20000000-0000-0000-0000-000000000032', '20000000-0000-0000-0000-000000000005',
    '20000000-0000-0000-0000-000000000015', 'harvestapi', 'trace-e5'
  ),
  null,
  'the real (non-blocked) attempt correctly counts toward and reaches the cap'
);

-- === Uncapped (max_email_enrichments not set) always succeeds ===
insert into campaign (id, operator_id, name) values
  ('20000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000001', 'Enrichment Test Campaign 3');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '20000000-0000-0000-0000-000000000022', '20000000-0000-0000-0000-000000000007', 1, '{}'::jsonb
);
-- 6:
select ok(
  claim_contact_enrichment_attempt(
    '20000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000022',
    '20000000-0000-0000-0000-000000000030', '20000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000013', 'harvestapi', 'trace-e6'
  ) is not null,
  'an unconfigured max_email_enrichments never blocks an attempt'
);

-- Regression (independent review finding): the count cap aggregates across the WHOLE
-- Campaign, not just the requesting revision -- same class of bug as Phase 1.2's budget
-- reservation, fixed the same way (CONTRACT.md sec.14,30).
insert into campaign (id, operator_id, name) values
  ('20000000-0000-0000-0000-000000000060', '20000000-0000-0000-0000-000000000001', 'Campaign-Wide Cap Test Campaign');
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '20000000-0000-0000-0000-000000000061', '20000000-0000-0000-0000-000000000060', 1,
  '{"max_email_enrichments": 2}'::jsonb
);
insert into person (id, display_name) values ('20000000-0000-0000-0000-000000000070', 'Cap Regression Person 1');
insert into external_profile (id, person_id, platform, external_id) values
  ('20000000-0000-0000-0000-000000000071', '20000000-0000-0000-0000-000000000070', 'linkedin', 'cap-regress-ext-1');
insert into campaign_candidate (id, campaign_id, person_id, external_profile_id) values
  ('20000000-0000-0000-0000-000000000072', '20000000-0000-0000-0000-000000000060',
   '20000000-0000-0000-0000-000000000070', '20000000-0000-0000-0000-000000000071');
select claim_contact_enrichment_attempt(
  '20000000-0000-0000-0000-000000000060', '20000000-0000-0000-0000-000000000061',
  '20000000-0000-0000-0000-000000000072', '20000000-0000-0000-0000-000000000070',
  '20000000-0000-0000-0000-000000000071', 'harvestapi', 'trace-f1'
);
select claim_contact_enrichment_attempt(
  '20000000-0000-0000-0000-000000000060', '20000000-0000-0000-0000-000000000061',
  '20000000-0000-0000-0000-000000000072', '20000000-0000-0000-0000-000000000070',
  '20000000-0000-0000-0000-000000000071', 'harvestapi', 'trace-f2'
);
-- A new revision for the SAME campaign; budget_policy carries the same
-- max_email_enrichments forward unchanged.
insert into campaign_revision (id, campaign_id, version, budget_policy) values (
  '20000000-0000-0000-0000-000000000062', '20000000-0000-0000-0000-000000000060', 2,
  '{"max_email_enrichments": 2}'::jsonb
);
-- 7: a claim under the NEW revision, where the campaign has already used its full cap of 2
-- real attempts under the OLD revision, is still correctly refused.
select is(
  claim_contact_enrichment_attempt(
    '20000000-0000-0000-0000-000000000060', '20000000-0000-0000-0000-000000000062',
    '20000000-0000-0000-0000-000000000072', '20000000-0000-0000-0000-000000000070',
    '20000000-0000-0000-0000-000000000071', 'harvestapi', 'trace-f3'
  ),
  null,
  'attempts claimed under an earlier revision of the same campaign still count against a later revision''s cap'
);

select * from finish();

rollback;
