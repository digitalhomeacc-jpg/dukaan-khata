-- Run in Supabase → SQL Editor (safe to run again, any order): 0051 a bill a connected friend paid for you is on the record you both see.

-- "A friend paid" for your food (or anything): with a connected friend it becomes a shared record for both of
-- you (you owe them your part), kept in step when you change or delete the payment. Not your bank or cash.
create or replace function public.sync_paid_by(p_txn uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.transactions; e public.shared_entries; lk_id uuid; lk_other uuid; friend text;
begin
  select * into t from public.transactions where id = p_txn;
  select * into e from public.shared_entries
   where debtor_txn = p_txn and kind = 'expense' and share_id is null and deleted_at is null limit 1;
  friend := lower(btrim(regexp_replace(coalesce(t.paid_by, ''), '\s+', ' ', 'g')));
  if t.id is not null and friend <> '' and friend <> coalesce(t.merchant_key, '') and t.direction = 'debit'
     and not t.excluded and t.amount > 0 then
    select l.link_id, l.other into lk_id, lk_other from public.link_for(t.user_id, public.friend_key_of(t.user_id, friend)) l;
  end if;
  if lk_id is null then
    -- No longer paid by a connected friend: their record of it goes.
    if e.id is not null then
      update public.shared_entries set deleted_at = now(), deleted_by = t.user_id where id = e.id;
    end if;
    return;
  end if;
  if e.id is not null and e.link_id = lk_id then
    update public.shared_entries
       set amount = t.amount, description = nullif(btrim(coalesce(t.merchant, '')), ''), at = t.txn_at
     where id = e.id and (amount, coalesce(description, ''), at) is distinct from (t.amount, btrim(coalesce(t.merchant, '')), t.txn_at);
    return;
  end if;
  if e.id is not null then
    update public.shared_entries set deleted_at = now(), deleted_by = t.user_id where id = e.id;
  end if;
  insert into public.shared_entries (link_id, creditor, debtor, amount, kind, description, at, created_by, debtor_txn)
  values (lk_id, lk_other, t.user_id, t.amount, 'expense', nullif(btrim(coalesce(t.merchant, '')), ''), t.txn_at,
          t.user_id, t.id);
end $$;

create or replace function public.on_txn_paid_by()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.paid_by is null then return null; end if;
  perform public.sync_paid_by(new.id);
  return null;
end $$;
drop trigger if exists txn_paid_by on public.transactions;
create trigger txn_paid_by after insert or update of paid_by, amount, merchant, txn_at, excluded on public.transactions
  for each row execute function public.on_txn_paid_by();

-- Bills friends already paid for you: on the shared record now.
do $$ declare t uuid; begin
  for t in select id from public.transactions where paid_by is not null and paid_by <> coalesce(merchant, '') loop
    perform public.sync_paid_by(t);
  end loop;
end $$;
