-- Phase 0A: connection
-- The long-lived Operator x Person relationship. Owns outreach/relationship state; this
-- MUST NOT be duplicated on campaign_candidate (CONTRACT.md sec.41).
--
-- Unlike campaign_candidate, this Contract does not mandate a strict transition-graph
-- trigger for request_state -- only that the state set be closed (CONTRACT.md sec.43).
-- Strict transition enforcement for Connection is deferred to Phase 1.5 (Safe Sending),
-- once the sender/reconciliation workflow's exact transition needs are concretely known.
-- This is a deliberate, documented Phase 0A scope decision, not an oversight.

create table if not exists connection (
  id uuid primary key default extensions.gen_random_uuid(),
  operator_id uuid not null references operator (id) on delete restrict,
  person_id uuid not null references person (id) on delete restrict,
  external_profile_id uuid not null references external_profile (id) on delete restrict,
  request_state text not null default 'NOT_PLANNED'
    check (request_state in (
      'NOT_PLANNED', 'NOTE_READY', 'QUEUED', 'SEND_ATTEMPTED', 'SENT',
      'FAILED', 'UNKNOWN_SEND_RESULT', 'ALREADY_CONNECTED', 'MANUAL_REVIEW'
    )),
  relationship_state text not null default 'NONE'
    check (relationship_state in ('NONE', 'CONNECTED', 'ENGAGED', 'ACTIVE_RELATIONSHIP')),
  note_sent text,
  requested_at timestamptz,
  connected_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One logical Operator x Person relationship (PLAN.md sec.17).
create unique index if not exists connection_operator_id_person_id_key
  on connection (operator_id, person_id);

create index if not exists connection_operator_id_idx on connection (operator_id);
create index if not exists connection_person_id_idx on connection (person_id);
create index if not exists connection_request_state_idx on connection (request_state);

create trigger connection_set_updated_at
before update on connection
for each row execute function set_updated_at();

comment on table connection is
  'Long-lived Operator x Person relationship; owns outreach/relationship state (CONTRACT.md sec.41).';
