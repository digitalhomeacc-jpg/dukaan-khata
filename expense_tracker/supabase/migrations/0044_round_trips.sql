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
