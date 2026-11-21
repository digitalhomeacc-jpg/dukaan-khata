-- Run in Supabase → SQL Editor (safe to run again): 0044 lent and returned is not spending; 0045 loans follow your payments; 0046 a payee you sorted stays sorted.

-- ===================================================================== 0044_round_trips
-- Money you sent a person and the same amount back from the same person (or the other way round) within 30
-- days is money lent and returned, not spending and income. Both go to Friends (the person is then settled).
-- Only payments with no category on both sides, never ones you edited, never shops; nearest pairs first.

create or replace function public.looks_like_person(p_name text)
returns boolean language sql immutable as $$
  select coalesce(p_name, '') ~ '^[A-Za-z.'' ]+$'
     and array_length(regexp_split_to_array(btrim(p_name), '\s+'), 1) between 2 and 5
     and p_name !~* '\m(store|stores|mart|hotel|restaurant|cafe|services|service|pvt|ltd|limited|enterprises?|medical|medicals|traders|shop|bank|finance|pharma|hospital|clinic|centre|center|agency|agencies|foods?|super|bazaar|kirana|general|india|technologies|solutions|private)\M'
$$;

-- Pairs [p_txn] with its return, if there is one. Returns true when paired.
create or replace function public.pair_round_trip(p_txn uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare t public.transactions; o uuid; fr uuid;
begin
  select * into t from public.transactions where id = p_txn;
  if not found or t.edited or t.excluded or t.loan_role is not null or t.paid_by is not null
     or coalesce(t.merchant_key, '') = '' or not public.looks_like_person(t.merchant) then return false; end if;
  select id into fr from public.categories where user_id = t.user_id and kind = 'loan' order by name = 'Friends' desc limit 1;
  if fr is null or t.category_id is not null then return false; end if;
  if exists (select 1 from public.people p where p.user_id = t.user_id and p.name_key = t.merchant_key and p.role in ('shop', 'me', 'family')) then
    return false;
  end if;
  -- The nearest unsorted payment the other way, same person and amount.
  select x.id into o from public.transactions x
   where x.user_id = t.user_id and x.id <> t.id and x.merchant_key = t.merchant_key and x.amount = t.amount
     and x.direction <> t.direction and not x.edited and not x.excluded and x.loan_role is null and x.paid_by is null
     and x.category_id is null
     and abs(extract(epoch from x.txn_at - t.txn_at)) <= 30 * 86400
   order by abs(extract(epoch from x.txn_at - t.txn_at)) limit 1;
  if o is null then return false; end if;
  -- Another payment like this one is nearer to that return: it is that one's pair, not this one's.
  if exists (select 1 from public.transactions y, public.transactions x
              where x.id = o and y.user_id = t.user_id and y.id not in (t.id, o) and y.merchant_key = t.merchant_key
                and y.amount = t.amount and y.direction = t.direction and y.category_id is null and not y.edited
                and not y.excluded and y.loan_role is null and y.paid_by is null
                and abs(extract(epoch from y.txn_at - x.txn_at)) < abs(extract(epoch from t.txn_at - x.txn_at))) then
    return false;
  end if;
  update public.transactions set category_id = fr, needs_review = false where id in (t.id, o) and category_id is null;
  return true;
end $$;

create or replace function public.on_txn_round_trip()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.pair_round_trip(new.id);
  return null;
end $$;
drop trigger if exists txn_round_trip on public.transactions;
create trigger txn_round_trip after insert on public.transactions
  for each row execute function public.on_txn_round_trip();

-- Payments already there: pair them now, oldest first.
do $$ declare t uuid; begin
  for t in select id from public.transactions where category_id is null and not edited and not excluded
            and loan_role is null and paid_by is null order by txn_at loop
    perform public.pair_round_trip(t);
  end loop;
end $$;

-- ===================================================================== 0045_loan_events_follow_payments
-- Loans follow your payments, always and at once.
-- Before: a bank payment linked to a loan became a loan event only when the lender had never sent an email
-- (to avoid counting an EMI twice), and only when a bank email or import ran the linking. So a KreditBee EMI
-- paid from the bank was linked but the EMIs left never went down. Now each payment linked to a loan has its
-- event, kept in step when it is linked (by you or a rule), changed, unlinked or deleted. An EMI the lender's
-- own email already recorded (same amount, within 5 days) is not counted twice. Money borrowed counts from the
-- day you added the loan (what came before is in the amounts you entered).

create or replace function public.sync_loan_event(p_txn uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.transactions; l public.loans; k text;
begin
  select * into t from public.transactions where id = p_txn;
  if not found then return; end if;
  k := case t.loan_role when 'repay' then 'repay' when 'borrow' then 'borrow' end;
  if t.loan_id is null or k is null then
    delete from public.loan_events where txn_id = p_txn;
    return;
  end if;
  select * into l from public.loans where id = t.loan_id;
  if not found or (k = 'borrow' and t.txn_at < l.created_at) then
    delete from public.loan_events where txn_id = p_txn;
    return;
  end if;
  if exists (select 1 from public.loan_events where txn_id = p_txn) then
    update public.loan_events set loan_id = t.loan_id, kind = k, amount = t.amount, event_at = t.txn_at where txn_id = p_txn;
    return;
  end if;
  -- The lender's email already has it.
  if exists (select 1 from public.loan_events e where e.loan_id = t.loan_id and e.kind = k and e.txn_id is null
              and e.email_id is not null and abs(e.amount - t.amount) < 1
              and abs(extract(epoch from e.event_at - t.txn_at)) <= 5 * 86400) then
    return;
  end if;
  insert into public.loan_events (user_id, loan_id, kind, amount, event_at, txn_id, note)
  values (t.user_id, t.loan_id, k, t.amount, t.txn_at, t.id, 'Bank payment')
  on conflict (txn_id) do nothing;
end $$;

create or replace function public.on_txn_loan_event()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.sync_loan_event(new.id);
  return null;
end $$;
drop trigger if exists txn_loan_event on public.transactions;
create trigger txn_loan_event after insert or update of loan_id, loan_role, amount, txn_at on public.transactions
  for each row execute function public.on_txn_loan_event();

-- Everything linked so far.
do $$ declare t uuid; begin
  for t in select id from public.transactions where loan_id is not null or loan_role is not null loop
    perform public.sync_loan_event(t);
  end loop;
end $$;

-- ===================================================================== 0046_remember_payees
-- A payee you sorted stays sorted. A new payment (or one renamed by a rule, e.g. from its UPI ID to the
-- person's full name) with no category takes the category you chose for that payee: your saved rules first,
-- else your past sorting when it all agrees (one category). Names match exactly, or when one is the other cut
-- short by a statement (12+ letters), or the other plus more words (two words or more: a first name alone
-- never matches). Never a payment you edited; never when you gave the payee different categories.

create or replace function public.same_payee(a text, b text)
returns boolean language sql immutable as $$
  select a = b
      or (length(a) >= 12 and b like a || '%') or (length(b) >= 12 and a like b || '%')
      or (a like '% %' and b like a || ' %') or (b like '% %' and a like b || ' %')
$$;

-- A UPI ID ending several people share (e.g. a birth year) says nothing about who was paid (see 0048).
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

create or replace function public.fill_payee_category()
returns trigger language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  if new.category_id is not null or new.excluded or new.loan_role is not null or new.paid_by is not null then return new; end if;
  if tg_op = 'UPDATE' and new.edited then return new; end if;
  c := public.payee_category(new.user_id, btrim(lower(regexp_replace(coalesce(new.merchant, ''), '\s+', ' ', 'g'))),
                             new.payee_vpa, new.id);
  if c is not null then
    new.category_id := c;
    new.needs_review := false;
  end if;
  return new;
end $$;
drop trigger if exists fill_payee_category on public.transactions;
create trigger fill_payee_category before insert or update of merchant, payee_vpa on public.transactions
  for each row execute function public.fill_payee_category();

-- Unsorted payments of payees you already sorted: sorted now.
update public.transactions t set category_id = x.c, needs_review = false
  from (select id, public.payee_category(user_id, merchant_key, payee_vpa, id) c from public.transactions
         where category_id is null and not edited and not excluded and loan_role is null and paid_by is null) x
 where t.id = x.id and x.c is not null;
