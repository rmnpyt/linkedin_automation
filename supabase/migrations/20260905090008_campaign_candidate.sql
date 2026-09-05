-- Phase 0A: campaign_candidate
-- Campaign x Person. Owns discovery/qualification state only -- never send or relationship
-- state, which belongs to connection (CONTRACT.md sec.15-17).
--
-- current_evaluation_id's foreign key to evaluation is added in a later migration once the
-- evaluation table exists (the two tables reference each other).

create table if not exists campaign_candidate (
  id uuid primary key default extensions.gen_random_uuid(),
  campaign_id uuid not null references campaign (id) on delete restrict,
  person_id uuid not null references person (id) on delete restrict,
  external_profile_id uuid not null references external_profile (id) on delete restrict,
  state text not null default 'DISCOVERED'
    check (state in (
      'DISCOVERED', 'SNAPSHOT_READY', 'EVALUATED',
      'QUALIFIED', 'DISQUALIFIED', 'SKIPPED', 'MANUAL_REVIEW'
    )),
  current_evaluation_id uuid,
  discovered_at timestamptz not null default now(),
  qualified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One CampaignCandidate per Campaign + Person (CONTRACT.md sec.15).
create unique index if not exists campaign_candidate_campaign_id_person_id_key
  on campaign_candidate (campaign_id, person_id);

create index if not exists campaign_candidate_campaign_id_idx on campaign_candidate (campaign_id);
create index if not exists campaign_candidate_person_id_idx on campaign_candidate (person_id);
create index if not exists campaign_candidate_state_idx on campaign_candidate (state);
create index if not exists campaign_candidate_current_evaluation_id_idx on campaign_candidate (current_evaluation_id);

create trigger campaign_candidate_set_updated_at
before update on campaign_candidate
for each row execute function set_updated_at();

-- Reject invalid state transitions rather than silently accepting arbitrary strings
-- (CONTRACT.md sec.16). Minimum transitions from CONTRACT.md sec.17, plus re-evaluation
-- paths (a previously evaluated candidate MAY be re-evaluated, which MUST create a new
-- Evaluation and MAY change the candidate's current state).
create or replace function enforce_candidate_state_transition()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  if new.state = old.state then
    return new;
  end if;

  if (old.state, new.state) not in (
    ('DISCOVERED', 'SNAPSHOT_READY'),
    ('DISCOVERED', 'SKIPPED'),
    ('SNAPSHOT_READY', 'EVALUATED'),
    ('SNAPSHOT_READY', 'SKIPPED'),
    ('EVALUATED', 'QUALIFIED'),
    ('EVALUATED', 'DISQUALIFIED'),
    ('EVALUATED', 'MANUAL_REVIEW'),
    ('QUALIFIED', 'EVALUATED'),
    ('QUALIFIED', 'DISQUALIFIED'),
    ('QUALIFIED', 'MANUAL_REVIEW'),
    ('DISQUALIFIED', 'EVALUATED'),
    ('DISQUALIFIED', 'QUALIFIED'),
    ('DISQUALIFIED', 'MANUAL_REVIEW'),
    ('MANUAL_REVIEW', 'EVALUATED'),
    ('MANUAL_REVIEW', 'QUALIFIED'),
    ('MANUAL_REVIEW', 'DISQUALIFIED')
  ) then
    raise exception 'invalid campaign_candidate state transition % -> % for candidate %',
      old.state, new.state, old.id;
  end if;

  return new;
end;
$$;

create trigger campaign_candidate_enforce_state_transition
before update on campaign_candidate
for each row execute function enforce_candidate_state_transition();

comment on table campaign_candidate is
  'Campaign x Person: owns discovery/qualification state only, never send/relationship state (CONTRACT.md sec.15-16).';
