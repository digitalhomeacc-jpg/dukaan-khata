-- Entries between connected friends count only once both agree. A new entry, a changed amount or a removal
-- waits for the other person's OK; until then the balance uses the last agreed amount. They can say no.
alter table public.shared_entries add column if not exists confirmed_amount numeric(14,2);
alter table public.shared_entries add column if not exists confirmed_at timestamptz;
alter table public.shared_entries add column if not exists changed_by uuid;            -- who made the change waiting for OK
alter table public.shared_entries add column if not exists remove_requested_by uuid;   -- asked to remove, waiting for OK
alter table public.shared_entries add column if not exists rejected_by uuid;

-- Everything so far stands as agreed.
update public.shared_entries set confirmed_amount = amount, confirmed_at = coalesce(confirmed_at, created_at)
 where confirmed_amount is null and deleted_at is null;

-- Who must answer: the other person.
create or replace function public.shared_mark_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.changed_by := coalesce(auth.uid(), new.created_by);
    -- Backed by both people's own bank payments (matched automatically): nothing to agree on.
    if new.creditor_txn is not null and new.debtor_txn is not null then
      new.confirmed_amount := new.amount; new.confirmed_at := now();
    end if;
  elsif new.amount is distinct from old.amount and new.confirmed_amount is not distinct from old.confirmed_amount then
    new.changed_by := coalesce(auth.uid(), new.created_by);
    new.confirmed_at := null;
  end if;
  return new;
end $$;
drop trigger if exists shared_mark_change on public.shared_entries;
create trigger shared_mark_change before insert or update on public.shared_entries
  for each row execute function public.shared_mark_change();

-- Changes go through these functions only (no direct edits).
drop policy if exists "edit shared" on public.shared_entries;

create or replace function public.request_remove_shared(p_entry uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e record; me uuid := auth.uid();
begin
  select * into e from public.shared_entries where id = p_entry and me in (creditor, debtor) and deleted_at is null;
  if e is null then raise exception 'not found'; end if;
  if e.confirmed_amount is null then
    -- Never agreed: whoever added it can take it back; the other can turn it down.
    update public.shared_entries set deleted_at = now(), deleted_by = me,
      rejected_by = case when e.changed_by = me then null else me end where id = p_entry;
  else
    update public.shared_entries set remove_requested_by = me, changed_by = me where id = p_entry;
  end if;
end $$;
grant execute on function public.request_remove_shared(uuid) to authenticated;

-- The other person says OK or no. Only someone who did not make the change can answer it.
create or replace function public.answer_shared(p_entry uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare e record; me uuid := auth.uid();
begin
  select * into e from public.shared_entries where id = p_entry and me in (creditor, debtor) and deleted_at is null;
  if e is null then raise exception 'not found'; end if;
  if e.changed_by = me then raise exception 'waiting for the other person'; end if;
  if e.remove_requested_by is not null then
    if p_ok then
      update public.shared_entries set deleted_at = now(), deleted_by = e.remove_requested_by, remove_requested_by = null
       where id = p_entry;
    else
      update public.shared_entries set remove_requested_by = null, changed_by = null where id = p_entry;
    end if;
  elsif e.confirmed_at is null then
    if p_ok then
      update public.shared_entries set confirmed_amount = amount, confirmed_at = now(), changed_by = null where id = p_entry;
    elsif e.confirmed_amount is null then
      update public.shared_entries set deleted_at = now(), deleted_by = me, rejected_by = me where id = p_entry;
    else
      -- A changed amount turned down: back to what was agreed.
      update public.shared_entries set amount = confirmed_amount, confirmed_at = now(), changed_by = null where id = p_entry;
    end if;
  end if;
end $$;
grant execute on function public.answer_shared(uuid, boolean) to authenticated;
