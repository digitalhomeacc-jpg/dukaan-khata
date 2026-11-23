-- 1. Money to and from your broker (Zerodha, Groww…) is moving your own money: not spending, not income. Only
--    the profit or loss in there is yours, and the bank never shows that. Such payments go to Investments,
--    unless you set their category yourself.
-- 2. Money you sent a person and the same amount back (or the other way round) within 30 days is lent and
--    returned: both go to Friends, so neither is spending or income. Now also when the bank spells the name
--    differently, cuts it short, or uses another name of theirs (Also known as), and when a half was already
--    sorted by a rule. Never a payment you changed yourself, a shop, family, your own account, or a bill you
--    split; never across a fresh start with them.
alter table public.people add column if not exists ledger_at timestamptz;

create or replace function public.is_broker(p_name text)
returns boolean language sql immutable as $$
  select coalesce(p_name, '') ~* '(zerodha|groww|upstox|angel ?one|indmoney|smallcase|kuvera|paytm ?money|mutual ?fund|nippon|\mkite\M|\mdhan\M|\msip\M|\mmf\M|\mvested\M|indian clearing|\miccl\M|nse clearing|nsccl)'
$$;

create or replace function public.fill_investment_category()
returns trigger language plpgsql security definer set search_path = public as $$
declare inv uuid;
begin
  if new.excluded or new.loan_role is not null or new.paid_by is not null or not public.is_broker(new.merchant) then return new; end if;
  if new.edited then return new; end if;
  -- A new payment: only when nothing else gave it a category. A renamed one: also over a rule's guess.
  if new.category_id is not null and (tg_op = 'INSERT'
      or not exists (select 1 from public.categories c where c.id = new.category_id and c.kind = 'normal')) then
    return new;
  end if;
  select id into inv from public.categories where user_id = new.user_id and kind = 'investment' order by name = 'Investments' desc limit 1;
  if inv is not null then
    new.category_id := inv;
    new.needs_review := false;
  end if;
  return new;
end $$;
-- Runs after fill_payee_category (triggers of a kind run in name order).
drop trigger if exists investment_payee on public.transactions;
create trigger investment_payee before insert or update of merchant on public.transactions
  for each row execute function public.fill_investment_category();

update public.transactions t set category_id = i.id, needs_review = false
  from public.categories i
 where i.user_id = t.user_id and i.kind = 'investment' and i.name = 'Investments'
   and public.is_broker(t.merchant) and not t.edited and not t.excluded and t.loan_role is null and t.paid_by is null
   and (t.category_id is null or exists (select 1 from public.categories c where c.id = t.category_id and c.kind = 'normal'));

-- Can this payment be one half of lent-and-returned?
create or replace function public.can_pair(t public.transactions)
returns boolean language sql stable security definer set search_path = public as $$
  select not t.edited and not t.excluded and t.loan_role is null and t.paid_by is null and t.loan_id is null
     and coalesce(t.merchant_key, '') <> '' and public.looks_like_person(t.merchant) and not public.is_broker(t.merchant)
     and (t.category_id is null or exists (select 1 from public.categories c where c.id = t.category_id and c.kind = 'normal'))
     and not exists (select 1 from public.txn_shares s where s.txn_id = t.id)
$$;

-- The same person: by "Also known as", the same name, or a name the statement cut short.
create or replace function public.same_person_key(p_user uuid, a text, b text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.same_payee(public.friend_key_of(p_user, a), public.friend_key_of(p_user, b))
$$;

create or replace function public.pair_round_trip(p_txn uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare t public.transactions; x public.transactions; fr uuid;
begin
  select * into t from public.transactions where id = p_txn;
  if not found or not public.can_pair(t) then return false; end if;
  select id into fr from public.categories where user_id = t.user_id and kind = 'loan' order by name = 'Friends' desc limit 1;
  if fr is null then return false; end if;
  if exists (select 1 from public.people p where p.user_id = t.user_id and p.role in ('shop', 'me', 'family')
              and public.same_person_key(t.user_id, p.name_key, t.merchant_key)) then
    return false;
  end if;
  -- The nearest payment the other way: same person, same amount.
  select y.* into x from public.transactions y
   where y.user_id = t.user_id and y.id <> t.id and y.amount = t.amount and y.direction <> t.direction
     and abs(extract(epoch from y.txn_at - t.txn_at)) <= 30 * 86400
     and public.can_pair(y) and public.same_person_key(t.user_id, y.merchant_key, t.merchant_key)
   order by abs(extract(epoch from y.txn_at - t.txn_at)) limit 1;
  if x.id is null then return false; end if;
  -- Another payment like this one is nearer to that return: it is that one's pair, not this one's.
  if exists (select 1 from public.transactions y
              where y.user_id = t.user_id and y.id not in (t.id, x.id) and y.amount = t.amount and y.direction = t.direction
                and public.can_pair(y) and public.same_person_key(t.user_id, y.merchant_key, t.merchant_key)
                and abs(extract(epoch from y.txn_at - x.txn_at)) < abs(extract(epoch from t.txn_at - x.txn_at))) then
    return false;
  end if;
  -- A fresh start with them between the two: one half is history, so they do not cancel out.
  if exists (select 1 from public.people p
              where p.user_id = t.user_id and p.ledger_from is not null
                and public.same_person_key(t.user_id, p.name_key, t.merchant_key)
                and coalesce(p.ledger_at, (p.ledger_from::timestamp at time zone 'Asia/Kolkata'))
                    between least(t.txn_at, x.txn_at) and greatest(t.txn_at, x.txn_at)) then
    return false;
  end if;
  update public.transactions set category_id = fr, needs_review = false where id in (t.id, x.id);
  return true;
end $$;

drop trigger if exists txn_round_trip on public.transactions;
create trigger txn_round_trip after insert or update of merchant on public.transactions
  for each row execute function public.on_txn_round_trip();

-- Payments already there: pair them now, oldest first.
do $$ declare t uuid; begin
  for t in select id from public.transactions where not edited and not excluded and loan_role is null and paid_by is null
            order by txn_at loop
    perform public.pair_round_trip(t);
  end loop;
end $$;
