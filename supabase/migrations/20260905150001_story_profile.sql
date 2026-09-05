-- Phase 2.1: Story Discovery -- versioned StoryProfile persistence (CONTRACT.md sec.49-50,
-- PROPOSAL.md sec.22, PLAN.md sec.35). This is the buildable-without-live-access part of the
-- phase: schema, provenance, and versioning mechanics. Full acceptance (CONTRACT.md sec.50)
-- additionally requires running Story Discovery on both real current operators and a human
-- usability judgment on the result -- that is real personal source material this repository
-- does not have access to, and is tracked as its own gate (see the Phase 2.1 status note in
-- the delivery report), not something any agent may fabricate or approximate.

-- Raw source material accepted for Story Discovery (CONTRACT.md sec.49: "MUST accept, when
-- available: operator LinkedIn profile; CV; optional written story"). Kept as its own
-- append-only table (never updated or deleted) so a StoryProfile's provenance can always
-- point back at the exact input text that produced it, even after newer material is added.
create table if not exists story_source_material (
  id uuid primary key default extensions.gen_random_uuid(),
  operator_id uuid not null references operator (id) on delete restrict,
  material_type text not null check (material_type in ('LINKEDIN_PROFILE', 'CV', 'WRITTEN_STORY')),
  content text not null check (length(trim(content)) > 0),
  created_at timestamptz not null default now()
);

create index if not exists story_source_material_operator_id_idx
  on story_source_material (operator_id);

create trigger story_source_material_append_only
before update or delete on story_source_material
for each row execute function reject_mutation();

comment on table story_source_material is
  'Raw LinkedIn-profile/CV/written-story text supplied for Story Discovery (CONTRACT.md sec.49). Append-only: a StoryProfile references the exact rows used as of its own creation time.';

-- Versioned StoryProfile output (PROPOSAL.md sec.22's suggested structure). "MUST NOT be
-- destructively overwritten when a materially new version is created" (CONTRACT.md sec.49)
-- is implemented the same way as ConnectionNote (20260905120001_connection_note_creation.sql):
-- old rows are kept forever with superseded_at set, never updated in place or deleted.
create table if not exists story_profile (
  id uuid primary key default extensions.gen_random_uuid(),
  operator_id uuid not null references operator (id) on delete restrict,
  version integer not null check (version > 0),
  positioning text not null check (length(trim(positioning)) > 0),
  professional_identity text not null check (length(trim(professional_identity)) > 0),
  core_themes jsonb not null default '[]'::jsonb,
  experience_signals jsonb not null default '[]'::jsonb,
  beliefs jsonb not null default '[]'::jsonb,
  audience jsonb not null default '[]'::jsonb,
  voice jsonb not null default '{}'::jsonb,
  content_angles jsonb not null default '[]'::jsonb,
  -- Provenance (CONTRACT.md sec.49): which source rows were used, plus the generating
  -- model/prompt version when AI-generated. Both provider and version are null together
  -- only for a hand-authored profile (no LLM involved) -- never a partially-filled pair.
  source_material_ids uuid[] not null default '{}'::uuid[],
  model_provider text,
  model_name text,
  prompt_version text,
  trace_id text,
  created_at timestamptz not null default now(),
  superseded_at timestamptz,
  -- Both "all null" and "all non-empty" must use IS [NOT] NULL rather than a bare
  -- length(trim(...)) > 0 comparison on a possibly-null column: length(trim(null)) is null,
  -- and a CHECK constraint treats a NULL result as satisfied rather than violated, which
  -- would silently let a partial (e.g. provider set, name/version null) row through.
  constraint story_profile_provenance_pair check (
    (model_provider is null and model_name is null and prompt_version is null)
    or (
      model_provider is not null and length(trim(model_provider)) > 0
      and model_name is not null and length(trim(model_name)) > 0
      and prompt_version is not null and length(trim(prompt_version)) > 0
    )
  ),
  unique (operator_id, version)
);

-- At most one active (current) StoryProfile per operator, enforced at the schema level as a
-- backstop independent of the row-lock discipline in create_story_profile below -- the same
-- defense-in-depth pattern as connection_note_one_active_per_connection (CONTRACT.md sec.69).
create unique index if not exists story_profile_one_active_per_operator
  on story_profile (operator_id)
  where superseded_at is null;

create index if not exists story_profile_operator_id_idx on story_profile (operator_id);

comment on table story_profile is
  'Versioned StoryProfile output of Story Discovery (CONTRACT.md sec.49-50, PROPOSAL.md sec.22). Never destructively overwritten -- a new version supersedes the prior one, which is kept for history.';

-- Atomically creates a new StoryProfile version for an operator and supersedes whichever
-- version was previously active, in one transaction (mirrors
-- create_connection_note_and_mark_ready's lock-then-supersede-then-insert shape). Locking
-- the operator row (rather than the story_profile row, which does not exist yet for a
-- first-ever profile) prevents two concurrent calls for the same operator from both reading
-- "no active profile yet" and racing to insert version 1 twice.
create or replace function create_story_profile(
  p_operator_id uuid,
  p_positioning text,
  p_professional_identity text,
  p_core_themes jsonb,
  p_experience_signals jsonb,
  p_beliefs jsonb,
  p_audience jsonb,
  p_voice jsonb,
  p_content_angles jsonb,
  p_source_material_ids uuid[],
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
  v_next_version integer;
  v_profile_id uuid;
  v_unknown_ids uuid[];
begin
  perform 1 from operator where id = p_operator_id for update;
  if not found then
    raise exception 'operator % not found', p_operator_id;
  end if;

  if length(trim(coalesce(p_positioning, ''))) = 0 then
    raise exception 'story profile positioning must not be empty';
  end if;
  if length(trim(coalesce(p_professional_identity, ''))) = 0 then
    raise exception 'story profile professional_identity must not be empty';
  end if;

  if (p_model_provider is not null or p_model_name is not null or p_prompt_version is not null)
     and (
       length(trim(coalesce(p_model_provider, ''))) = 0
       or length(trim(coalesce(p_model_name, ''))) = 0
       or length(trim(coalesce(p_prompt_version, ''))) = 0
     )
  then
    raise exception 'story profile provenance fields (model_provider, model_name, prompt_version) must be either all null (hand-authored) or all non-empty (AI-generated)';
  end if;

  -- Every referenced source-material id must actually exist and belong to this operator --
  -- provenance must point at real inputs, never an invented or cross-operator reference.
  select array_agg(sid) into v_unknown_ids
  from unnest(coalesce(p_source_material_ids, '{}'::uuid[])) as sid
  where not exists (
    select 1 from story_source_material
    where id = sid and operator_id = p_operator_id
  );
  if v_unknown_ids is not null and array_length(v_unknown_ids, 1) > 0 then
    raise exception 'SOURCE_MATERIAL_NOT_FOUND: source_material_ids % do not belong to operator %',
      v_unknown_ids, p_operator_id;
  end if;

  select coalesce(max(version), 0) + 1 into v_next_version
  from story_profile
  where operator_id = p_operator_id;

  update story_profile
  set superseded_at = now()
  where operator_id = p_operator_id and superseded_at is null;

  insert into story_profile (
    operator_id, version, positioning, professional_identity, core_themes, experience_signals,
    beliefs, audience, voice, content_angles, source_material_ids,
    model_provider, model_name, prompt_version, trace_id
  ) values (
    p_operator_id, v_next_version, p_positioning, p_professional_identity,
    coalesce(p_core_themes, '[]'::jsonb), coalesce(p_experience_signals, '[]'::jsonb),
    coalesce(p_beliefs, '[]'::jsonb), coalesce(p_audience, '[]'::jsonb),
    coalesce(p_voice, '{}'::jsonb), coalesce(p_content_angles, '[]'::jsonb),
    coalesce(p_source_material_ids, '{}'::uuid[]),
    p_model_provider, p_model_name, p_prompt_version, p_trace_id
  )
  returning id into v_profile_id;

  return v_profile_id;
end;
$$;

comment on function create_story_profile(uuid, text, text, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, uuid[], text, text, text, text) is
  'Atomically creates a new versioned StoryProfile for an operator and supersedes the prior active one, never destructively overwriting it (CONTRACT.md sec.49,69).';

-- Unlike connection_note (whose immutability only kicks in once a connection_attempt
-- references it), a story_profile has no downstream reference to gate on yet, and
-- CONTRACT.md sec.49's "MUST NOT be destructively overwritten" applies to the row from the
-- moment it exists. superseded_at is the one field create_story_profile itself needs to
-- change (to retire the previously-active version); every other field is fixed at insert.
create or replace function enforce_story_profile_immutability()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
  if new.operator_id is distinct from old.operator_id
     or new.version is distinct from old.version
     or new.positioning is distinct from old.positioning
     or new.professional_identity is distinct from old.professional_identity
     or new.core_themes is distinct from old.core_themes
     or new.experience_signals is distinct from old.experience_signals
     or new.beliefs is distinct from old.beliefs
     or new.audience is distinct from old.audience
     or new.voice is distinct from old.voice
     or new.content_angles is distinct from old.content_angles
     or new.source_material_ids is distinct from old.source_material_ids
     or new.model_provider is distinct from old.model_provider
     or new.model_name is distinct from old.model_name
     or new.prompt_version is distinct from old.prompt_version
     or new.trace_id is distinct from old.trace_id
     or new.created_at is distinct from old.created_at
  then
    raise exception 'story_profile % is immutable except for superseded_at (CONTRACT.md sec.49)', old.id;
  end if;
  return new;
end;
$$;

create trigger story_profile_enforce_immutability
before update on story_profile
for each row execute function enforce_story_profile_immutability();

create trigger story_profile_no_delete
before delete on story_profile
for each row execute function reject_mutation();

alter table story_source_material enable row level security;
alter table story_profile enable row level security;
