-- Phase 0A: close the campaign_candidate <-> evaluation cycle now that evaluation exists,
-- and provide the atomic, race-safe "governing evaluation" update path required by
-- CONTRACT.md sec.15,17 (a stale/older evaluation must never overwrite a newer decision).

alter table campaign_candidate
  add constraint campaign_candidate_current_evaluation_id_fkey
  foreign key (current_evaluation_id) references evaluation (id) on delete set null;

-- A candidate's current_evaluation_id must point at an evaluation that actually belongs
-- to that same candidate, AND a stale/older evaluation must never overwrite a newer
-- governing decision (CONTRACT.md sec.15,17,69). This is enforced here, on the table
-- itself, rather than only inside set_governing_evaluation(), so the invariant holds
-- against ANY writer -- not only callers that go through the sanctioned RPC.
create or replace function check_candidate_governing_evaluation()
returns trigger
language plpgsql
as $$
declare
  v_new_created_at timestamptz;
  v_old_created_at timestamptz;
begin
  if new.current_evaluation_id is not null then
    select created_at into v_new_created_at
    from evaluation e
    where e.id = new.current_evaluation_id
      and e.campaign_candidate_id = new.id;

    if not found then
      raise exception 'campaign_candidate %: current_evaluation_id % does not belong to this candidate',
        new.id, new.current_evaluation_id;
    end if;

    if tg_op = 'UPDATE'
       and old.current_evaluation_id is not null
       and old.current_evaluation_id is distinct from new.current_evaluation_id
    then
      select created_at into v_old_created_at from evaluation where id = old.current_evaluation_id;
      if v_old_created_at > v_new_created_at
         or (v_old_created_at = v_new_created_at and old.current_evaluation_id > new.current_evaluation_id)
      then
        raise exception 'campaign_candidate %: cannot set current_evaluation_id to % (older than current governing evaluation %)',
          new.id, new.current_evaluation_id, old.current_evaluation_id;
      end if;
    end if;
  end if;
  return new;
end;
$$;

create trigger campaign_candidate_check_governing_evaluation
before insert or update on campaign_candidate
for each row execute function check_candidate_governing_evaluation();

-- Atomically updates a candidate's governing evaluation + state under a row lock, refusing
-- to let a stale/older evaluation overwrite a newer governing decision. Returns true if the
-- update was applied, false if it was ignored as stale.
create or replace function set_governing_evaluation(
  p_candidate_id uuid,
  p_evaluation_id uuid,
  p_new_state text
)
returns boolean
language plpgsql
as $$
declare
  v_new_created_at timestamptz;
  v_current_evaluation_id uuid;
  v_current_created_at timestamptz;
begin
  select created_at into v_new_created_at
  from evaluation
  where id = p_evaluation_id and campaign_candidate_id = p_candidate_id;

  if not found then
    raise exception 'evaluation % does not belong to candidate %', p_evaluation_id, p_candidate_id;
  end if;

  select current_evaluation_id into v_current_evaluation_id
  from campaign_candidate
  where id = p_candidate_id
  for update;

  if not found then
    raise exception 'campaign_candidate % not found', p_candidate_id;
  end if;

  if v_current_evaluation_id is not null then
    select created_at into v_current_created_at from evaluation where id = v_current_evaluation_id;
    if v_current_created_at > v_new_created_at
       or (v_current_created_at = v_new_created_at and v_current_evaluation_id > p_evaluation_id) then
      return false;
    end if;
  end if;

  update campaign_candidate
  set current_evaluation_id = p_evaluation_id,
      state = p_new_state
  where id = p_candidate_id;

  return true;
end;
$$;

comment on function set_governing_evaluation(uuid, uuid, text) is
  'Atomically (row-locked) updates a campaign_candidate governing evaluation + state; refuses to let a stale/older evaluation overwrite a newer one (CONTRACT.md sec.15,17).';
