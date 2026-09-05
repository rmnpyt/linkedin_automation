-- Phase 0A: pin search_path on every SECURITY INVOKER helper/trigger function so it
-- cannot be redirected by a role that manipulates its session search_path
-- (CONTRACT.md sec.24 least privilege).

alter function set_updated_at() set search_path = public, extensions;
alter function reject_mutation() set search_path = public, extensions;
alter function enforce_campaign_revision_freeze() set search_path = public, extensions;
alter function freeze_campaign_revision(uuid) set search_path = public, extensions;
alter function enforce_candidate_state_transition() set search_path = public, extensions;
alter function check_candidate_governing_evaluation() set search_path = public, extensions;
alter function set_governing_evaluation(uuid, uuid, text) set search_path = public, extensions;
alter function evaluation_freeze_revision_on_insert() set search_path = public, extensions;
alter function enforce_connection_note_immutability() set search_path = public, extensions;
alter function lock_connection_note_before_attempt() set search_path = public, extensions;
