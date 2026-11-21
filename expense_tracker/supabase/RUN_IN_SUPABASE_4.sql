-- Run in Supabase → SQL Editor (safe to run again): 0047 "Is it in your bank?" links a friend's entry to your own bank payment; 0048 a UPI ID ending friends share (e.g. born in 2002) no longer sorts one friend's payments as another's.

-- ===================================================================== 0047_link_shared_to_bank
-- "This is in my bank": link a shared record your friend's bank made to your own bank payment.
-- The payment goes to your Friends ledger (kept as your edit), its payee name is remembered as this friend, and a
-- record your own bank had made separately for the same payment is folded in, so nothing counts twice.
create or replace function public.link_shared_txn(p_entry uuid, p_txn uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); e public.shared_entries; t public.transactions; i_paid boolean; fname text; cat uuid;
        o record;
begin
  select * into e from public.shared_entries where id = p_entry and me in (creditor, debtor) and deleted_at is null;
  if e.id is null then raise exception 'entry not found'; end if;
  if e.kind = 'expense' then raise exception 'a shared bill is linked from the payment itself'; end if;
  select * into t from public.transactions where id = p_txn and user_id = me;
  if t.id is null then raise exception 'payment not found'; end if;
  i_paid := e.creditor = me;   -- I paid them: my money went out
  if (t.direction = 'debit') <> i_paid then
    raise exception '%', case when i_paid then 'pick money you paid' else 'pick money you received' end;
  end if;
  if round(t.amount, 2) <> round(e.amount, 2) then raise exception 'the amounts differ'; end if;
  if t.excluded or t.loan_role is not null or t.paid_by is not null then raise exception 'this payment is not a friend payment'; end if;

  -- Another record backed by this payment (my own bank made one too): unlink it; with no bank left, it goes.
  for o in select * from public.shared_entries
            where id <> e.id and deleted_at is null and share_id is null and (creditor_txn = p_txn or debtor_txn = p_txn) loop
    update public.shared_entries
       set creditor_txn = case when creditor_txn = p_txn then null else creditor_txn end,
           debtor_txn = case when debtor_txn = p_txn then null else debtor_txn end
     where id = o.id;
    if (case when o.creditor_txn = p_txn then o.debtor_txn else o.creditor_txn end) is null then
      update public.shared_entries set deleted_at = now(), deleted_by = me where id = o.id;
    end if;
  end loop;

  -- Remember the payee as this friend first, so moving the payment to Friends keeps it with this record.
  select case when l.a = me then l.a_name_for_b else l.b_name_for_a end into fname
    from public.friend_links l where l.id = e.link_id;
  if coalesce(t.merchant_key, '') <> '' and fname is not null and t.merchant_key <> lower(btrim(fname)) then
    insert into public.friend_aliases (user_id, alias_key, friend_name) values (me, t.merchant_key, fname)
    on conflict (user_id, alias_key) do update set friend_name = excluded.friend_name;
  end if;

  if i_paid then update public.shared_entries set creditor_txn = p_txn where id = e.id;
  else update public.shared_entries set debtor_txn = p_txn where id = e.id; end if;
  delete from public.match_questions where entry_id = e.id or txn_id = p_txn;

  if not coalesce((select c.kind = 'loan' from public.categories c where c.id = t.category_id), false) then
    select id into cat from public.categories where user_id = me and kind = 'loan' order by name = 'Friends' desc limit 1;
    update public.transactions set category_id = cat, needs_review = false, edited = true where id = t.id;
  end if;
  return true;
end $$;
grant execute on function public.link_shared_txn(uuid, uuid) to authenticated;

-- ===================================================================== 0048_shared_upi_tails
-- The app keeps only the end of a UPI ID ("kunal2002@okaxis" → "2002@o"), because statements cut it short.
-- Different people can end the same way (born in 2002, the same last digits): such an ending says nothing about
-- who was paid. It is ignored for category rules: the payee's name (and what you did with it before) decides.
-- A real UPI ID has one account holder, so: 3 or more full names on one ending, or 2 on an ending that is a year.
create or replace function public.vpa_is_shared(p_user uuid, p_vpa text)
returns boolean language sql stable security definer set search_path = public as $$
  with names as (
    select distinct merchant_key from public.transactions
     where user_id = p_user and payee_vpa = p_vpa and merchant_key ~ '^[a-z]+ [a-z]'
  )
  select p_vpa is not null and ((select count(*) from names) >= 3
         or ((select count(*) from names) >= 2 and p_vpa ~ '^(19[5-9][0-9]|20[0-2][0-9])@'))
$$;

create or replace function public.payee_category(p_user uuid, p_key text, p_vpa text, p_except uuid default null)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare c uuid; n integer;
begin
  if coalesce(p_key, '') = '' then return null; end if;
  select category_id into c from public.merchant_rules where user_id = p_user and merchant_key = p_key;
  if c is not null then return c; end if;
  select count(distinct category_id), min(category_id::text)::uuid into n, c from public.merchant_rules
   where user_id = p_user and public.same_payee(merchant_key, p_key);
  if n = 1 then return c; end if;
  if p_vpa is not null and not public.vpa_is_shared(p_user, p_vpa) then
    select category_id into c from public.vpa_rules where user_id = p_user and vpa = p_vpa;
    if c is not null then return c; end if;
  end if;
  select count(distinct category_id), min(category_id::text)::uuid into n, c from public.transactions
   where user_id = p_user and category_id is not null and not excluded and loan_role is null
     and id is distinct from p_except and public.same_payee(merchant_key, p_key);
  if n = 1 then return c; end if;
  return null;
end $$;

create or replace function public.apply_vpa_rules(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  update public.transactions t set category_id = r.category_id, needs_review = false
    from public.vpa_rules r
   where r.user_id = p_user and t.user_id = p_user and t.payee_vpa = r.vpa
     and not t.edited and not t.excluded and t.loan_role is null and t.category_id is distinct from r.category_id
     and not public.vpa_is_shared(p_user, r.vpa);
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.apply_vpa_rules(uuid) to authenticated, service_role;

