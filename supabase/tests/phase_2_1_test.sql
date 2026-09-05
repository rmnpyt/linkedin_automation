-- Phase 2.1 database tests (CONTRACT.md sec.49,69). Run inside a transaction that always
-- rolls back, so this is safe to run repeatedly against the shared linkedin_automation
-- development project without leaving residue. All fixture data is synthetic
-- (CONTRACT.md sec.67.1) -- this phase's real human-validation acceptance criterion
-- (CONTRACT.md sec.50) requires actual operator source material and is out of scope here.

begin;

select plan(18);

insert into operator (id, display_name) values
  ('50000000-0000-0000-0000-000000000001', 'Story Test Operator A'),
  ('50000000-0000-0000-0000-000000000002', 'Story Test Operator B');

insert into story_source_material (id, operator_id, material_type, content) values
  ('50000000-0000-0000-0000-000000000010', '50000000-0000-0000-0000-000000000001', 'LINKEDIN_PROFILE', 'synthetic linkedin profile text for operator A'),
  ('50000000-0000-0000-0000-000000000011', '50000000-0000-0000-0000-000000000001', 'CV', 'synthetic CV text for operator A');

-- 1: creating a story profile for a non-existent operator is rejected.
select throws_ok(
  $$ select create_story_profile(
       '50000000-0000-0000-0000-00000000ffff', 'positioning', 'identity',
       '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, '[]'::jsonb,
       '{}'::uuid[], null, null, null, 'trace-story-0'
     ) $$,
  'P0001', null, 'creating a story profile for a non-existent operator is rejected'
);

-- 2: an empty positioning is rejected.
select throws_ok(
  $$ select create_story_profile(
       '50000000-0000-0000-0000-000000000001', '   ', 'identity',
       '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, '[]'::jsonb,
       '{}'::uuid[], null, null, null, 'trace-story-1'
     ) $$,
  'P0001', null, 'an empty (whitespace-only) positioning is rejected'
);

-- 3: an empty professional_identity is rejected.
select throws_ok(
  $$ select create_story_profile(
       '50000000-0000-0000-0000-000000000001', 'positioning', '',
       '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, '[]'::jsonb,
       '{}'::uuid[], null, null, null, 'trace-story-2'
     ) $$,
  'P0001', null, 'an empty professional_identity is rejected'
);

-- 4: a source_material_id that does not exist is rejected.
select throws_ok(
  format(
    $$ select create_story_profile(
         '50000000-0000-0000-0000-000000000001', 'positioning', 'identity',
         '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, '[]'::jsonb,
         ARRAY[%L]::uuid[], null, null, null, 'trace-story-3'
       ) $$,
    '50000000-0000-0000-0000-0000000000ff'
  ),
  'P0001', null, 'a nonexistent source_material_id is rejected (SOURCE_MATERIAL_NOT_FOUND)'
);

-- 5: a source_material_id that belongs to a DIFFERENT operator is rejected -- provenance
-- must not be allowed to point at another operator's material.
select throws_ok(
  format(
    $$ select create_story_profile(
         '50000000-0000-0000-0000-000000000002', 'positioning', 'identity',
         '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, '[]'::jsonb,
         ARRAY[%L]::uuid[], null, null, null, 'trace-story-4'
       ) $$,
    '50000000-0000-0000-0000-000000000010'
  ),
  'P0001', null, 'a source_material_id belonging to a different operator is rejected'
);

-- 6: a partial provenance triple (model_provider without model_name/prompt_version) is
-- rejected by the check constraint.
select throws_ok(
  $$ insert into story_profile (operator_id, version, positioning, professional_identity, model_provider)
     values ('50000000-0000-0000-0000-000000000001', 999, 'p', 'i', 'openrouter') $$,
  '23514', null, 'a partial provenance triple (provider without name/prompt_version) is rejected'
);

do $$
declare
  v_profile_id uuid;
begin
  v_profile_id := create_story_profile(
    '50000000-0000-0000-0000-000000000001', 'Builder who ships pragmatic automation.', 'Senior backend engineer',
    '["automation", "reliability"]'::jsonb, '["shipped a linkedin automation system"]'::jsonb,
    '["small teams move faster"]'::jsonb, '["engineering leaders"]'::jsonb,
    '{"tone": "direct", "avoid": ["hype"]}'::jsonb, '["lessons from building agentic systems"]'::jsonb,
    ARRAY['50000000-0000-0000-0000-000000000010', '50000000-0000-0000-0000-000000000011']::uuid[],
    'openrouter', 'test-model', 'story-discovery/v1', 'trace-story-5'
  );
  create temporary table if not exists tmp_story_profile_id (id uuid);
  insert into tmp_story_profile_id values (v_profile_id);
end $$;

-- 7: a well-formed first version is created successfully.
select ok(
  (select id from tmp_story_profile_id) is not null,
  'create_story_profile creates a StoryProfile with a full provenance triple and valid content'
);
-- 8: it is version 1.
select is(
  (select version from story_profile where id = (select id from tmp_story_profile_id)),
  1,
  'the first StoryProfile for an operator is version 1'
);
-- 9: it is active (not superseded).
select is(
  (select superseded_at from story_profile where id = (select id from tmp_story_profile_id)),
  null,
  'a newly created StoryProfile is active (superseded_at is null)'
);
-- 10: its source_material_ids are recorded.
select is(
  (select array_length(source_material_ids, 1) from story_profile where id = (select id from tmp_story_profile_id)),
  2,
  'source_material_ids provenance is recorded on the StoryProfile'
);

do $$
declare
  v_second_id uuid;
begin
  v_second_id := create_story_profile(
    '50000000-0000-0000-0000-000000000001', 'Refined positioning after a second pass.', 'Senior backend engineer',
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, '[]'::jsonb,
    '{}'::uuid[], null, null, null, 'trace-story-6'
  );
  create temporary table if not exists tmp_story_profile_id_2 (id uuid);
  insert into tmp_story_profile_id_2 values (v_second_id);
end $$;

-- 11: a second call for the same operator creates version 2.
select is(
  (select version from story_profile where id = (select id from tmp_story_profile_id_2)),
  2,
  'a second StoryProfile for the same operator is version 2'
);
-- 12: the second version is now the active one.
select is(
  (select superseded_at from story_profile where id = (select id from tmp_story_profile_id_2)),
  null,
  'the second StoryProfile version is active'
);
-- 13: the first version is now superseded, not deleted or edited.
select isnt(
  (select superseded_at from story_profile where id = (select id from tmp_story_profile_id)),
  null,
  'the first StoryProfile version is superseded (not destructively overwritten) after a new version is created'
);
-- 14: the first version's own content is unchanged (never destructively overwritten).
select is(
  (select positioning from story_profile where id = (select id from tmp_story_profile_id)),
  'Builder who ships pragmatic automation.',
  'the superseded StoryProfile''s own content is preserved untouched, not rewritten'
);

-- 15: story_source_material is append-only -- an attempted update is rejected.
select throws_ok(
  $$ update story_source_material set content = 'edited' where id = '50000000-0000-0000-0000-000000000010' $$,
  null, null, 'story_source_material rows cannot be updated (append-only, CONTRACT.md sec.49)'
);

-- === Review-fix regressions ===

-- 16: an empty-string provenance field (not null, but blank) alongside a filled one is
-- rejected, not silently accepted as "full provenance" (Finding 1: a bare
-- length(trim(...)) > 0 CHECK on a possibly-null column evaluates to NULL -- which a CHECK
-- constraint treats as satisfied -- for the null branches, so the constraint alone must not
-- be trusted to catch this; create_story_profile's own validation is what is exercised here).
select throws_ok(
  $$ select create_story_profile(
       '50000000-0000-0000-0000-000000000001', 'positioning', 'identity',
       '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb, '[]'::jsonb,
       '{}'::uuid[], 'openrouter', '', 'story-discovery/v1', 'trace-story-7'
     ) $$,
  'P0001', null, 'an empty-string provenance field alongside filled ones is rejected, not treated as full provenance'
);

-- 17: story_profile is immutable except for superseded_at -- a direct UPDATE of any other
-- column is rejected (Finding 2).
select throws_ok(
  format(
    $$ update story_profile set positioning = 'rewritten' where id = %L $$,
    (select id from tmp_story_profile_id)
  ),
  'P0001', null, 'a direct UPDATE of a story_profile row''s content (not superseded_at) is rejected'
);

-- 18: story_profile rows cannot be deleted, even once superseded (Finding 2).
select throws_ok(
  format(
    $$ delete from story_profile where id = %L $$,
    (select id from tmp_story_profile_id)
  ),
  null, null, 'story_profile rows cannot be deleted, even once superseded'
);

select * from finish();

rollback;
