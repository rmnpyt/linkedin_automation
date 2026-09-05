-- Phase 0A: pgtap's functions are exposed via PostgREST if left in public (any function in
-- the public schema becomes a callable RPC endpoint by default). Move it to the extensions
-- schema, alongside pgcrypto/uuid-ossp. The default search_path ("$user", public,
-- extensions) already includes extensions, so unqualified test calls (has_table(), etc.)
-- keep working unchanged -- verified after this migration by rerunning
-- supabase/tests/phase_0a_test.sql.

drop extension pgtap;
create extension pgtap with schema extensions;
