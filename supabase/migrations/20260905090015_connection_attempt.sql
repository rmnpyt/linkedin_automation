-- Phase 0A: connection_attempt
-- One external send attempt, idempotency-protected, preserving full campaign/evaluation/
-- note attribution (CONTRACT.md sec.42,45-47). A logical connection request must never be
-- sent twice because of retries, duplicate triggers, concurrent workers, or restarts.

create table if not exists connection_attempt (
  id uuid primary key default extensions.gen_random_uuid(),
  connection_id uuid not null references connection (id) on delete restrict,
  campaign_candidate_id uuid not null references campaign_candidate (id) on delete restrict,
  campaign_revision_id uuid not null references campaign_revision (id) on delete restrict,
  evaluation_id uuid not null references evaluation (id) on delete restrict,
  connection_note_id uuid not null references connection_note (id) on delete restrict,
  idempotency_key text not null,
  attempt_number integer not null check (attempt_number > 0),
  state text not null default 'QUEUED'
    check (state in (
      'QUEUED', 'SEND_ATTEMPTED', 'SENT', 'FAILED', 'UNKNOWN_SEND_RESULT', 'ALREADY_CONNECTED'
    )),
  trace_id text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  result_metadata jsonb,
  error_code text,
  error_message text
);

-- A logical send is claimed exactly once (CONTRACT.md sec.46).
create unique index if not exists connection_attempt_idempotency_key_key
  on connection_attempt (idempotency_key);
create unique index if not exists connection_attempt_connection_id_attempt_number_key
  on connection_attempt (connection_id, attempt_number);

create index if not exists connection_attempt_connection_id_idx on connection_attempt (connection_id);
create index if not exists connection_attempt_campaign_candidate_id_idx on connection_attempt (campaign_candidate_id);
create index if not exists connection_attempt_trace_id_idx on connection_attempt (trace_id);

comment on table connection_attempt is
  'One external send attempt, idempotency-protected, preserving full campaign/evaluation/note attribution (CONTRACT.md sec.42,45-47).';

-- A connection_note referenced by any attempt becomes immutable except for superseded_at
-- (CONTRACT.md sec.41.1).
create or replace function enforce_connection_note_immutability()
returns trigger
language plpgsql
as $$
begin
  if exists (select 1 from connection_attempt where connection_note_id = old.id) then
    if new.body is distinct from old.body
       or new.model_provider is distinct from old.model_provider
       or new.model_name is distinct from old.model_name
       or new.prompt_version is distinct from old.prompt_version
       or new.connection_id is distinct from old.connection_id
       or new.campaign_candidate_id is distinct from old.campaign_candidate_id
       or new.campaign_revision_id is distinct from old.campaign_revision_id
       or new.evaluation_id is distinct from old.evaluation_id
    then
      raise exception 'connection_note % is referenced by a connection_attempt and is immutable except for superseded_at',
        old.id;
    end if;
  end if;
  return new;
end;
$$;

create trigger connection_note_enforce_immutability
before update on connection_note
for each row execute function enforce_connection_note_immutability();

-- Close a race between "insert the first attempt for a note" and "edit that note" that
-- run concurrently (CONTRACT.md sec.41.1, sec.70): take a row lock on the target
-- connection_note before inserting an attempt against it. This forces the insert and any
-- concurrent UPDATE on the same note to serialize via ordinary Postgres row-lock
-- contention, so whichever transaction commits second always observes the other's effect
-- (a note update that lost the race sees the new attempt and is correctly rejected; an
-- attempt insert that lost the race proceeds only after the note edit has committed).
create or replace function lock_connection_note_before_attempt()
returns trigger
language plpgsql
as $$
begin
  perform 1 from connection_note where id = new.connection_note_id for update;
  return new;
end;
$$;

create trigger connection_attempt_lock_note_before_insert
before insert on connection_attempt
for each row execute function lock_connection_note_before_attempt();
