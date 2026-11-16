-- Connected friends: every friend payment is in the shared record, and stays right when it changes.
--
-- 1. A friend's bank names you in full ("SANKET PRAMOD PATIL") while they saved you as "Sanket Patil": the
--    payment matched no connection, so it was in Friends but never in the balance you both see. Now a payee
--    is the connected friend when it is that friend's own name (the "me" name in their app) or contains every
--    word of the name you saved them as; the payee name is remembered as "also known as" that friend.
-- 2. A payment that made a shared record is deleted (a duplicate, an import that removes what the bank does
--    not have): the record was left behind and still counted. Now it goes too (or, if your friend had already
--    agreed to it, they are asked to OK the removal).
-- 3. Such a payment is moved out of Friends, or its amount changes: the record now follows it (a changed
--    amount waits for your friend's OK, like any change).

-- The connected friend a payee name means for this user, if any (one connection only).
create or replace function public.friend_link_of_payee(p_user uuid, p_merchant_key text)
returns table (link_id uuid, other uuid, friend_name text, exact boolean)
language plpgsql stable security definer set search_path = public as $$
declare fk text := public.friend_key_of(p_user, p_merchant_key); lk record; n integer;
begin
  select * into lk from public.link_for(p_user, fk);
  if lk.link_id is not null then
    return query select lk.link_id, lk.other, fk, true;
    return;
  end if;
  if coalesce(p_merchant_key, '') = '' then return; end if;
  return query
    with cands as (
      select l.id, case when l.a = p_user then l.b else l.a end as o,
             case when l.a = p_user then l.a_name_for_b else l.b_name_for_a end as saved
        from public.friend_links l
       where l.b is not null and p_user in (l.a, l.b)
    ), hits as (
      select c.id, c.o, c.saved from cands c
       where exists (select 1 from public.people p where p.user_id = c.o and p.role = 'me'
                      and (public.is_person(p_merchant_key, p.name_key) or public.is_person(p.name_key, p_merchant_key)))
          or (array_length(regexp_split_to_array(btrim(lower(c.saved)), '\s+'), 1) >= 2
              and regexp_split_to_array(btrim(lower(c.saved)), '\s+') <@ regexp_split_to_array(p_merchant_key, '\s+'))
    )
    select h.id, h.o, lower(h.saved), false from hits h where (select count(*) from hits) = 1;
end $$;

-- Does this payment belong in a shared record at all?
create or replace function public.is_friend_payment(t public.transactions)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select c.kind = 'loan' from public.categories c where c.id = t.category_id), false)
     and not t.excluded and t.loan_role is null and t.paid_by is null
$$;

-- A payment no longer backs its record: unlink it; a record left with no payment is removed (or, once your
-- friend agreed to it, they are asked to OK the removal).
drop function if exists public.unsync_friend_txn(uuid, uuid);

-- [p_payments_only]: only records made from friend payments (not "paid by" expenses), when the payment changed.
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
      if e.confirmed_amount is null then
        update public.shared_entries set deleted_at = now(), deleted_by = p_user where id = e.id;
      else
        update public.shared_entries set remove_requested_by = p_user, changed_by = p_user where id = e.id;
      end if;
    end if;
  end loop;
end $$;

-- A friend payment in my bank: attach it to the record of the same money, or record a new one.
create or replace function public.sync_friend_txn(p_txn uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.transactions; lk record; mine_creditor boolean; e uuid; refs text[];
begin
  select tr.* into t from public.transactions tr where tr.id = p_txn;
  if not found then return; end if;
  if not public.is_friend_payment(t) then return; end if;
  if exists (select 1 from public.shared_entries where (creditor_txn = p_txn or debtor_txn = p_txn) and deleted_at is null) then return; end if;
  select * into lk from public.friend_link_of_payee(t.user_id, t.merchant_key);
  if lk.link_id is null then return; end if;
  -- Recognised by name: remember the payee name as this friend, so it is one person everywhere.
  if not lk.exact then
    insert into public.friend_aliases (user_id, alias_key, friend_name)
    select t.user_id, t.merchant_key, case when l.a = t.user_id then l.a_name_for_b else l.b_name_for_a end
      from public.friend_links l where l.id = lk.link_id
    on conflict (user_id, alias_key) do nothing;
  end if;
  mine_creditor := t.direction = 'debit';   -- I paid them: they owe me (or I paid back)
  refs := public.txn_refs(p_txn);

  -- The friend may already have it: the same reference, else same amount and direction close in time.
  select se.id into e from public.shared_entries se
   where se.link_id = lk.link_id and se.deleted_at is null and se.kind <> 'expense' and se.amount = t.amount
     and se.creditor = case when mine_creditor then t.user_id else lk.other end
     and (case when mine_creditor then se.creditor_txn else se.debtor_txn end) is null
     and (coalesce(se.creditor_txn, se.debtor_txn) is null
          or public.same_money(p_txn, coalesce(se.creditor_txn, se.debtor_txn), t.txn_at, se.at))
   order by (cardinality(refs) > 0 and refs && public.txn_refs(coalesce(se.creditor_txn, se.debtor_txn))) desc,
            abs(extract(epoch from se.at - t.txn_at))
   limit 1;
  if e is not null then
    if mine_creditor then update public.shared_entries set creditor_txn = p_txn where id = e;
    else update public.shared_entries set debtor_txn = p_txn where id = e; end if;
    -- Backed by both banks now: nothing left to agree on.
    update public.shared_entries set confirmed_amount = amount, confirmed_at = now(), changed_by = null
     where id = e and creditor_txn is not null and debtor_txn is not null and confirmed_at is null;
    delete from public.match_questions where entry_id = e;
    perform public.merge_shared_duplicates(lk.link_id);
    return;
  end if;

  insert into public.shared_entries (link_id, creditor, debtor, amount, kind, description, at, created_by, creditor_txn, debtor_txn)
  values (lk.link_id,
          case when mine_creditor then t.user_id else lk.other end,
          case when mine_creditor then lk.other else t.user_id end,
          t.amount, 'payment', null, t.txn_at, t.user_id,
          case when mine_creditor then p_txn end, case when mine_creditor then null else p_txn end);
  perform public.merge_shared_duplicates(lk.link_id);
end $$;

-- Payments added or changed: keep their shared records right.
create or replace function public.on_txn_friend_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare e record;
begin
  if tg_op = 'UPDATE' then
    if not public.is_friend_payment(new) then
      perform public.unsync_friend_txn(new.id, new.user_id, true);
    else
      -- Another friend now (renamed): leave the old record, then sync below.
      for e in select se.* from public.shared_entries se
                where (se.creditor_txn = new.id or se.debtor_txn = new.id) and se.deleted_at is null and se.share_id is null
                  and se.kind <> 'expense' loop
        if e.link_id is distinct from (select link_id from public.friend_link_of_payee(new.user_id, new.merchant_key)) then
          perform public.unsync_friend_txn(new.id, new.user_id, true);
        elsif new.amount is distinct from old.amount and e.kind = 'payment' then
          -- The amount changed: the record changes too, for your friend to OK.
          update public.shared_entries set amount = new.amount where id = e.id;
        end if;
      end loop;
    end if;
  end if;
  perform public.sync_friend_txn(new.id);
  perform public.ask_about_txn(new.id);
  return null;
end $$;
drop trigger if exists txn_friend_sync on public.transactions;
create trigger txn_friend_sync after insert or update of category_id, merchant, amount, excluded, loan_role on public.transactions
  for each row execute function public.on_txn_friend_sync();

create or replace function public.on_txn_friend_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.unsync_friend_txn(old.id, old.user_id);
  return old;
end $$;
drop trigger if exists txn_friend_delete on public.transactions;
create trigger txn_friend_delete before delete on public.transactions
  for each row execute function public.on_txn_friend_delete();
