-- Connected friends: one payment between you is one shared record, backed by both banks.
--
-- A UPI / IMPS transfer carries the same 12-digit reference in both people's bank alerts and statements, so
-- that is matched first. Statement lines have no time (the app puts them at 6 am) and two banks can date the
-- same transfer a day apart, so without a reference they match within 3 days instead of 24 hours. Where one
-- record is backed only by your bank and an identical one only by your friend's, they are the same money and
-- are merged into one record backed by both: the balance only loses the double count.

alter table public.shared_entries add column if not exists merged_into uuid references public.shared_entries on delete set null;

-- The 12-digit references in a payment's bank text.
create or replace function public.txn_refs(p_txn uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct m[1]), '{}')
    from public.transactions t,
         regexp_matches(coalesce(t.details, '') || ' ' || coalesce(t.email_body, '') || ' ' || coalesce(t.email_ref, ''),
                        '(?<![0-9])([0-9]{12})(?![0-9])', 'g') m
   where t.id = p_txn
$$;

-- Could these two payments be the same money? The same reference: yes. Different references: never. No
-- reference on one side (cash, added by hand): only if close enough in time.
create or replace function public.same_money(p_a uuid, p_b uuid, p_a_at timestamptz, p_b_at timestamptz)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare ra text[] := public.txn_refs(p_a); rb text[] := public.txn_refs(p_b);
begin
  if cardinality(ra) > 0 and cardinality(rb) > 0 then return ra && rb; end if;
  return abs(extract(epoch from p_a_at - p_b_at)) <= extract(epoch from public.same_payment_window(p_a, p_b));
end $$;

-- How far apart two payments may be and still be the same one.
create or replace function public.same_payment_window(p_a uuid, p_b uuid)
returns interval language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.transactions where id in (p_a, p_b) and source = 'statement')
              then interval '3 days' else interval '1 day' end
$$;

-- Merges records of the same money: one backed only by the creditor's bank, one only by the debtor's.
create or replace function public.merge_shared_duplicates(p_link uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in
    select c.id cid, d.id did, c.creditor_txn ctx, d.debtor_txn dtx
      from public.shared_entries c
      join public.shared_entries d
        on d.link_id = c.link_id and d.id <> c.id and d.amount = c.amount
       and d.creditor = c.creditor and d.debtor = c.debtor
       and d.deleted_at is null and d.kind <> 'expense' and d.remove_requested_by is null
       and d.debtor_txn is not null and d.creditor_txn is null
     where c.link_id = p_link and c.deleted_at is null and c.kind <> 'expense' and c.remove_requested_by is null
       and c.creditor_txn is not null and c.debtor_txn is null
       and public.same_money(c.creditor_txn, d.debtor_txn, c.at, d.at)
     order by (public.txn_refs(c.creditor_txn) && public.txn_refs(d.debtor_txn)) desc, abs(extract(epoch from c.at - d.at))
  loop
    -- Each record joins at most one other (the loop sees rows as they were when it started).
    if not exists (select 1 from public.shared_entries where id in (r.cid, r.did) and (deleted_at is not null or
                   (id = r.cid and debtor_txn is not null) or (id = r.did and creditor_txn is not null))) then
      update public.shared_entries set deleted_at = now(), merged_into = r.cid, debtor_txn = null where id = r.did;
      update public.shared_entries
         set debtor_txn = r.dtx, confirmed_amount = amount, confirmed_at = now(), changed_by = null
       where id = r.cid;
      delete from public.match_questions where entry_id in (r.cid, r.did);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- A friend payment in my bank: attach it to the record of the same money, or record a new one.
create or replace function public.sync_friend_txn(p_txn uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t record; fk text; lk record; mine_creditor boolean; e uuid; refs text[];
begin
  select tr.*, c.kind as cat_kind into t
    from public.transactions tr left join public.categories c on c.id = tr.category_id where tr.id = p_txn;
  if t is null or t.cat_kind is distinct from 'loan' or t.excluded or t.loan_role is not null or t.paid_by is not null then return; end if;
  if exists (select 1 from public.shared_entries where creditor_txn = p_txn or debtor_txn = p_txn) then return; end if;
  fk := public.friend_key_of(t.user_id, t.merchant_key);
  select * into lk from public.link_for(t.user_id, fk);
  if lk.link_id is null then return; end if;
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

-- A new record from the friend: find the same payment in my bank (same reference: certain), or ask if unsure.
create or replace function public.match_entry_for(p_entry uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare se record; i_am_creditor boolean; friend_name text; cand record; n integer := 0; refs text[];
begin
  select * into se from public.shared_entries where id = p_entry;
  if se is null or se.deleted_at is not null or se.kind = 'expense' then return; end if;
  i_am_creditor := se.creditor = p_user;
  if (i_am_creditor and se.creditor_txn is not null) or (not i_am_creditor and se.debtor_txn is not null) then return; end if;
  select case when l.a = p_user then lower(l.a_name_for_b) else lower(l.b_name_for_a) end into friend_name
    from public.friend_links l where l.id = se.link_id;
  refs := public.txn_refs(coalesce(se.creditor_txn, se.debtor_txn));

  for cand in
    select t.id, public.friend_key_of(p_user, t.merchant_key) = friend_name as named,
           cardinality(refs) > 0 and refs && public.txn_refs(t.id) as same_ref
      from public.transactions t
     where t.user_id = p_user and t.amount = se.amount and not t.excluded and t.loan_role is null
       and t.direction = case when i_am_creditor then 'debit' else 'credit' end
       and (coalesce(se.creditor_txn, se.debtor_txn) is null and abs(extract(epoch from t.txn_at - se.at)) <= 86400
            or public.same_money(t.id, coalesce(se.creditor_txn, se.debtor_txn), t.txn_at, se.at))
       and not exists (select 1 from public.shared_entries x where x.deleted_at is null and (x.creditor_txn = t.id or x.debtor_txn = t.id))
     order by (cardinality(refs) > 0 and refs && public.txn_refs(t.id)) desc,
              (public.friend_key_of(p_user, t.merchant_key) = friend_name) desc, abs(extract(epoch from t.txn_at - se.at))
  loop
    if (cand.same_ref or cand.named) and n = 0 then
      -- The same transfer (same reference), or same amount and days from this friend: link without asking.
      if i_am_creditor then update public.shared_entries set creditor_txn = cand.id where id = p_entry;
      else update public.shared_entries set debtor_txn = cand.id where id = p_entry; end if;
      return;
    end if;
    -- Amount and days fit but the name does not (e.g. a parent's account): ask.
    insert into public.match_questions (user_id, entry_id, txn_id) values (p_user, p_entry, cand.id)
    on conflict do nothing;
    n := n + 1;
    exit when n >= 3;
  end loop;
end $$;

-- Records already doubled up: merge them now.
do $$ declare l uuid; begin
  for l in select id from public.friend_links where b is not null loop
    perform public.merge_shared_duplicates(l);
  end loop;
end $$;
