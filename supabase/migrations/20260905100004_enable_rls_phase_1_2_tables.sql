-- Phase 1.2: extend the Phase 0A RLS posture (CONTRACT.md sec.24) to the two new tables.
-- Same reasoning as 20260905090020_enable_rls.sql: no anon/authenticated access pattern
-- exists anywhere in this architecture, so RLS-enabled-with-zero-policies blocks that
-- exposure while never affecting service_role.

alter table search_run enable row level security;
alter table campaign_budget_reservation enable row level security;
