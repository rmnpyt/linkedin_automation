-- Phase 0A: enable pgTAP so supabase/tests/*.sql can run as reproducible database tests
-- (CONTRACT.md sec.68,75).

create extension if not exists pgtap;
