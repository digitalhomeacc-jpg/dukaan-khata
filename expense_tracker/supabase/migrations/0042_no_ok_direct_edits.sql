-- Connected friends without "OK": an entry, a change, a removal or an opening balance counts at once for both.
-- Every change still shows in both people's change history (who and when), with undo.
-- Also: either of you can edit a shared entry directly (amount, what for, date, who paid).

-- New entries and changed amounts count at once.
create or replace function public.shared_mark_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.changed_by := coalesce(auth.uid(), new.created_by);
    new.confirmed_amount := new.amount;
    new.confirmed_at := now();
  elsif new.amount is distinct from old.amount then
    new.changed_by := coalesce(auth.uid(), new.created_by);
    new.confirmed_amount := new.amount;
    new.confirmed_at := now();
  end if;
  new.remove_requested_by := null;
  return new;
end $$;

-- Removing an entry removes it for both.
create or replace function public.request_remove_shared(p_entry uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  update public.shared_entries set deleted_at = now(), deleted_by = me
   where id = p_entry and me in (creditor, debtor) and deleted_at is null;
  return found;
end $$;
grant execute on function public.request_remove_shared(uuid) to authenticated;

-- A payment that made a shared entry is deleted or moved out of Friends: the entry goes too.
create or replace function public.unsync_friend_txn(p_txn uuid, p_user uuid, p_payments_only boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare e record;
begin
  for e in select * from public.shared_entries
            where (creditor_txn = p_txn or debtor_txn = p_txn) and deleted_at is null and share_id is null
              and (not p_payments_only or kind <> 'expense') loop
    update public.shared_entries
       set creditor_txn = case when creditor_txn = p_txn then null else creditor_txn end,
           debtor_txn = case when debtor_txn = p_txn then null else debtor_txn end
     where id = e.id;
    if (case when e.creditor_txn = p_txn then e.debtor_txn else e.creditor_txn end) is null then
      update public.shared_entries set deleted_at = now(), deleted_by = p_user where id = e.id;
    end if;
  end loop;
end $$;

-- An opening balance counts as soon as either of you sets it.
create or replace function public.propose_friend_opening(p_link uuid, p_as_of date, p_owed_by uuid, p_amount numeric, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare l record; new_id uuid; amt numeric := round(coalesce(p_amount, 0), 2);
begin
  select * into l from public.friend_links fl where fl.id = p_link and fl.b is not null and auth.uid() in (fl.a, fl.b);
  if l is null then raise exception 'not connected'; end if;
  if amt < 0 then raise exception 'amount must not be negative'; end if;
  if amt > 0 and (p_owed_by is null or p_owed_by not in (l.a, l.b)) then raise exception 'who owes?'; end if;
  update public.friend_openings set deleted_at = now()
   where link_id = p_link and confirmed_at is null and deleted_at is null;
  insert into public.friend_openings (link_id, as_of, owed_by, amount, note, created_by, confirmed_at)
  values (p_link, p_as_of, case when amt = 0 then null else p_owed_by end, amt, nullif(btrim(coalesce(p_note, '')), ''), auth.uid(), now())
  returning friend_openings.id into new_id;
  return new_id;
end $$;
grant execute on function public.propose_friend_opening(uuid, date, uuid, numeric, text) to authenticated;

-- Edit a shared entry directly: amount, what it was for, date, and who paid (p_creditor is the one owed).
create or replace function public.edit_shared(p_entry uuid, p_amount numeric, p_description text, p_at timestamptz, p_creditor uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare e record; me uuid := auth.uid();
begin
  select * into e from public.shared_entries where id = p_entry and me in (creditor, debtor) and deleted_at is null;
  if e is null then return false; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be more than 0'; end if;
  if p_creditor not in (e.creditor, e.debtor) then raise exception 'who paid?'; end if;
  update public.shared_entries
     set amount = round(p_amount, 2),
         description = nullif(btrim(coalesce(p_description, '')), ''),
         at = coalesce(p_at, e.at),
         creditor = p_creditor,
         debtor = case when p_creditor = e.creditor then e.debtor else e.creditor end,
         -- the bank payments stay with their owners
         creditor_txn = case when p_creditor = e.creditor then e.creditor_txn else e.debtor_txn end,
         debtor_txn = case when p_creditor = e.creditor then e.debtor_txn else e.creditor_txn end,
         changed_by = me
   where id = p_entry;
  return true;
end $$;
grant execute on function public.edit_shared(uuid, numeric, text, timestamptz, uuid) to authenticated;

-- Everything waiting for an OK counts now; removals asked for are done.
update public.shared_entries set deleted_at = now(), deleted_by = remove_requested_by, remove_requested_by = null
 where remove_requested_by is not null and deleted_at is null;
update public.shared_entries set confirmed_amount = amount, confirmed_at = now()
 where deleted_at is null and (confirmed_at is null or confirmed_amount is distinct from amount);
update public.friend_openings set confirmed_at = now() where confirmed_at is null and deleted_at is null;
