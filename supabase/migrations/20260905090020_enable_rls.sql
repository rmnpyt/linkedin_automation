-- Phase 0A: enable Row Level Security on every domain table with zero policies.
-- This blocks the anon/authenticated PostgREST roles entirely (CONTRACT.md sec.24 least
-- privilege; sec.67.1 personal-data governance) while never affecting service_role, which
-- bypasses RLS by Postgres/Supabase design. Nothing in this architecture uses the
-- anon/authenticated roles: n8n's built-in Supabase node credential type requires a
-- service_role secret (it has no anon-key mode), and Rust tools are trusted backend
-- callers, not browser/mobile clients. If a genuine end-user-facing access pattern is
-- designed later (out of scope while the system remains personal-use, per MINDSET.md
-- sec.4), it must add explicit RLS policies at that time -- not remove this default-deny.

alter table operator enable row level security;
alter table person enable row level security;
alter table external_profile enable row level security;
alter table profile_snapshot enable row level security;
alter table campaign enable row level security;
alter table campaign_revision enable row level security;
alter table campaign_candidate enable row level security;
alter table evaluation enable row level security;
alter table contact_point enable row level security;
alter table contact_enrichment_attempt enable row level security;
alter table connection enable row level security;
alter table connection_note enable row level security;
alter table connection_attempt enable row level security;
alter table workflow_run enable row level security;
alter table workflow_step_run enable row level security;
alter table provider_usage enable row level security;
