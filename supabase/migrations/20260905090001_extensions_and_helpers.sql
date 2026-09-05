-- Phase 0A: extensions and shared helper functions/triggers used by every domain table.

create extension if not exists pgcrypto with schema extensions;

-- Generic BEFORE UPDATE trigger: stamps updated_at = now() on every row update.
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function set_updated_at() is
  'Generic BEFORE UPDATE trigger: stamps updated_at = now() on every row update.';

-- Generic append-only guard: attach as BEFORE UPDATE OR DELETE to make a table
-- historical/append-only at the database level (PLAN.md sec.12, CONTRACT.md sec.12).
create or replace function reject_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception '% is append-only; % is not permitted on this table', tg_table_name, tg_op;
end;
$$;

comment on function reject_mutation() is
  'Generic BEFORE UPDATE OR DELETE trigger that rejects all mutation, for append-only historical tables.';
