-- Connected friends: two users share one record of what is owed between them.
-- Each user sees only the entries between the two of them, never anything else.

-- Payee names that mean a friend (his father's account, a second bank): name → friend.
create table public.friend_aliases (
  user_id     uuid not null default auth.uid() references auth.users on delete cascade,
  alias_key   text not null,   -- merchant_key of the payee name
  friend_name text not null,   -- the friend it belongs to, as shown in the app
  primary key (user_id, alias_key)
);
alter table public.friend_aliases enable row level security;
create policy "own aliases" on public.friend_aliases
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- A connection between user a (who invited) and user b (who accepted).
create table public.friend_links (
  id           uuid primary key default gen_random_uuid(),
  a            uuid not null default auth.uid() references auth.users on delete cascade,
  b            uuid references auth.users on delete cascade,
  a_name_for_b text not null,           -- the friend's name in a's list
  b_name_for_a text,                    -- a's name in b's list
  code         text not null unique default encode(extensions.gen_random_bytes(5), 'hex'),
  created_at   timestamptz not null default now(),
  accepted_at  timestamptz,
  check (a is distinct from b)
);
alter table public.friend_links enable row level security;
create policy "see own links" on public.friend_links for select using (auth.uid() in (a, b));
create policy "invite" on public.friend_links for insert with check (a = auth.uid() and b is null);
create policy "remove own links" on public.friend_links for delete using (auth.uid() in (a, b));

-- One shared entry: `debtor` owes `creditor` `amount` (a payment, a share of an expense, a settle-up).
create table public.shared_entries (
  id            uuid primary key default gen_random_uuid(),
  link_id       uuid not null references public.friend_links on delete cascade,
  creditor      uuid not null references auth.users on delete cascade,
  debtor        uuid not null references auth.users on delete cascade,
  amount        numeric(14, 2) not null check (amount > 0),
  kind          text not null default 'payment' check (kind in ('payment', 'expense', 'settle')),
  description   text,
  at            timestamptz not null default now(),
  created_by    uuid not null references auth.users on delete cascade,
  creditor_txn  uuid references public.transactions on delete set null,
  debtor_txn    uuid references public.transactions on delete set null,
  share_id      uuid references public.txn_shares on delete cascade,
  deleted_by    uuid references auth.users on delete set null,
  deleted_at    timestamptz,
  created_at    timestamptz not null default now(),
  check (creditor <> debtor)
);
create index shared_entries_link on public.shared_entries (link_id, at desc);
create unique index shared_entries_share on public.shared_entries (share_id) where share_id is not null;
alter table public.shared_entries enable row level security;
create policy "see shared" on public.shared_entries for select using (auth.uid() in (creditor, debtor));
create policy "add shared" on public.shared_entries for insert
  with check (created_by = auth.uid() and auth.uid() in (creditor, debtor)
              and exists (select 1 from public.friend_links l where l.id = link_id and l.b is not null
                          and auth.uid() in (l.a, l.b) and creditor in (l.a, l.b) and debtor in (l.a, l.b)));
create policy "edit shared" on public.shared_entries for update
  using (auth.uid() in (creditor, debtor)) with check (auth.uid() in (creditor, debtor));

-- "Was this ₹500 from Vijay Sharma the ₹500 Rahul paid you?"
create table public.match_questions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade,
  entry_id   uuid not null references public.shared_entries on delete cascade,
  txn_id     uuid not null references public.transactions on delete cascade,
  created_at timestamptz not null default now(),
  unique (entry_id, txn_id)
);
alter table public.match_questions enable row level security;
create policy "own questions" on public.match_questions for select using (user_id = auth.uid());
create policy "dismiss questions" on public.match_questions for delete using (user_id = auth.uid());

alter publication supabase_realtime add table public.friend_aliases, public.friend_links, public.shared_entries, public.match_questions;

-- ------------------------------------------------------------------ helpers

-- The friend (canonical name key) a payee name means for this user.
create or replace function public.friend_key_of(p_user uuid, p_merchant_key text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select lower(friend_name) from public.friend_aliases where user_id = p_user and alias_key = p_merchant_key),
                  p_merchant_key)
$$;

-- The connection for this user's friend name, with the other user's id.
create or replace function public.link_for(p_user uuid, p_friend_key text)
returns table (link_id uuid, other uuid) language sql stable security definer set search_path = public as $$
  select id, case when a = p_user then b else a end
    from public.friend_links
   where b is not null
     and ((a = p_user and lower(a_name_for_b) = p_friend_key) or (b = p_user and lower(b_name_for_a) = p_friend_key))
   limit 1
$$;

-- A friend payment in my bank: attach it to the matching shared entry, or record a new one.
create or replace function public.sync_friend_txn(p_txn uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t record; fk text; lk record; mine_creditor boolean; e uuid;
begin
  select tr.*, c.kind as cat_kind into t
    from public.transactions tr left join public.categories c on c.id = tr.category_id where tr.id = p_txn;
  if t is null or t.cat_kind is distinct from 'loan' or t.excluded or t.loan_role is not null or t.paid_by is not null then return; end if;
  if exists (select 1 from public.shared_entries where creditor_txn = p_txn or debtor_txn = p_txn) then return; end if;
  fk := public.friend_key_of(t.user_id, t.merchant_key);
  select * into lk from public.link_for(t.user_id, fk);
  if lk.link_id is null then return; end if;
  mine_creditor := t.direction = 'debit';   -- I paid them: they owe me (or I paid back)

  -- The friend may already have recorded it: same amount, same direction, within a day.
  select se.id into e from public.shared_entries se
   where se.link_id = lk.link_id and se.deleted_at is null and se.kind <> 'expense' and se.amount = t.amount
     and se.creditor = case when mine_creditor then t.user_id else lk.other end
     and (case when mine_creditor then se.creditor_txn else se.debtor_txn end) is null
     and abs(extract(epoch from se.at - t.txn_at)) <= 86400
   order by abs(extract(epoch from se.at - t.txn_at)) limit 1;
  if e is not null then
    if mine_creditor then update public.shared_entries set creditor_txn = p_txn where id = e;
    else update public.shared_entries set debtor_txn = p_txn where id = e; end if;
    delete from public.match_questions where entry_id = e;
    return;
  end if;

  insert into public.shared_entries (link_id, creditor, debtor, amount, kind, description, at, created_by, creditor_txn, debtor_txn)
  values (lk.link_id,
          case when mine_creditor then t.user_id else lk.other end,
          case when mine_creditor then lk.other else t.user_id end,
          t.amount, 'payment', null, t.txn_at, t.user_id,
          case when mine_creditor then p_txn end, case when mine_creditor then null else p_txn end);
end $$;

-- A new entry from the friend: find the same payment in my bank, or ask if unsure.
create or replace function public.match_entry_for(p_entry uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare se record; i_am_creditor boolean; friend_name text; cand record; n integer := 0;
begin
  select * into se from public.shared_entries where id = p_entry;
  if se is null or se.deleted_at is not null or se.kind = 'expense' then return; end if;
  i_am_creditor := se.creditor = p_user;
  if (i_am_creditor and se.creditor_txn is not null) or (not i_am_creditor and se.debtor_txn is not null) then return; end if;
  select case when l.a = p_user then lower(l.a_name_for_b) else lower(l.b_name_for_a) end into friend_name
    from public.friend_links l where l.id = se.link_id;

  for cand in
    select t.id, public.friend_key_of(p_user, t.merchant_key) = friend_name as named
      from public.transactions t
     where t.user_id = p_user and t.amount = se.amount and not t.excluded and t.loan_role is null
       and t.direction = case when i_am_creditor then 'debit' else 'credit' end
       and abs(extract(epoch from t.txn_at - se.at)) <= 86400
       and not exists (select 1 from public.shared_entries x where x.creditor_txn = t.id or x.debtor_txn = t.id)
     order by (public.friend_key_of(p_user, t.merchant_key) = friend_name) desc, abs(extract(epoch from t.txn_at - se.at))
  loop
    if cand.named and n = 0 then
      -- Same amount, same day, from this friend: link without asking.
      if i_am_creditor then update public.shared_entries set creditor_txn = cand.id where id = p_entry;
      else update public.shared_entries set debtor_txn = cand.id where id = p_entry; end if;
      return;
    end if;
    -- Amount and day fit but the name does not (e.g. a parent's account): ask.
    insert into public.match_questions (user_id, entry_id, txn_id) values (p_user, p_entry, cand.id)
    on conflict do nothing;
    n := n + 1;
    exit when n >= 3;
  end loop;
end $$;

-- Triggers: bank emails, statements and category changes sync friend payments.
create or replace function public.on_txn_friend_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.sync_friend_txn(new.id);
  return null;
end $$;
create trigger txn_friend_sync after insert or update of category_id, merchant, amount on public.transactions
  for each row execute function public.on_txn_friend_sync();

create or replace function public.on_entry_added()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- The other person's side.
  perform public.match_entry_for(new.id, case when new.created_by = new.creditor then new.debtor else new.creditor end);
  return null;
end $$;
create trigger entry_added after insert on public.shared_entries
  for each row execute function public.on_entry_added();

-- Shares of a payment with a connected friend become shared entries ("Rahul owes you ₹300").
create or replace function public.on_share_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare t record; lk record;
begin
  if tg_op = 'DELETE' then
    update public.shared_entries set deleted_at = now(), deleted_by = auth.uid() where share_id = old.id;
    return null;
  end if;
  select * into t from public.transactions where id = new.txn_id;
  select * into lk from public.link_for(new.user_id, public.friend_key_of(new.user_id,
    btrim(lower(regexp_replace(new.person, '\s+', ' ', 'g')))));
  if lk.link_id is null then return null; end if;
  insert into public.shared_entries (link_id, creditor, debtor, amount, kind, description, at, created_by, creditor_txn, share_id)
  values (lk.link_id, new.user_id, lk.other, new.amount, 'expense', coalesce(t.merchant, 'Shared expense'), t.txn_at,
          new.user_id, new.txn_id, new.id)
  on conflict (share_id) where share_id is not null
  do update set amount = excluded.amount, deleted_at = null, deleted_by = null;
  return null;
end $$;
create trigger share_sync after insert or update of amount, person or delete on public.txn_shares
  for each row execute function public.on_share_change();

-- "Paid by Rahul" expenses with a connected Rahul: Rahul sees that you owe him your share.
create or replace function public.on_paid_by()
returns trigger language plpgsql security definer set search_path = public as $$
declare lk record;
begin
  if new.paid_by is null then return null; end if;
  if exists (select 1 from public.shared_entries where debtor_txn = new.id) then return null; end if;
  select * into lk from public.link_for(new.user_id, public.friend_key_of(new.user_id,
    btrim(lower(regexp_replace(new.paid_by, '\s+', ' ', 'g')))));
  if lk.link_id is null then return null; end if;
  insert into public.shared_entries (link_id, creditor, debtor, amount, kind, description, at, created_by, debtor_txn)
  values (lk.link_id, lk.other, new.user_id, new.amount, 'expense', new.merchant, new.txn_at, new.user_id, new.id);
  return null;
end $$;
create trigger paid_by_sync after insert on public.transactions
  for each row execute function public.on_paid_by();

-- ------------------------------------------------------------------ actions

-- Accept an invite code; links both users and shares past payments between them.
create or replace function public.accept_friend_invite(p_code text, p_name_for_inviter text)
returns uuid language plpgsql security definer set search_path = public as $$
declare l record; t record;
begin
  select * into l from public.friend_links where code = lower(btrim(p_code)) for update;
  if l is null then raise exception 'This invite code is not valid.'; end if;
  if l.b is not null then raise exception 'This invite was already used.'; end if;
  if l.a = auth.uid() then raise exception 'That is your own invite. Send it to your friend.'; end if;
  update public.friend_links set b = auth.uid(), b_name_for_a = btrim(p_name_for_inviter), accepted_at = now() where id = l.id;
  -- Bring in friend payments both of you already have (oldest first so matching pairs up).
  for t in select tr.id from public.transactions tr join public.categories c on c.id = tr.category_id
            where tr.user_id in (l.a, auth.uid()) and c.kind = 'loan' order by tr.txn_at loop
    perform public.sync_friend_txn(t.id);
  end loop;
  return l.id;
end $$;
grant execute on function public.accept_friend_invite(text, text) to authenticated;

-- Answer "was this the same payment?". Yes: link it, and remember that payee name as this friend.
create or replace function public.answer_match(p_question uuid, p_yes boolean)
returns void language plpgsql security definer set search_path = public as $$
declare q record; se record; t record; fname text; cat uuid;
begin
  select * into q from public.match_questions where id = p_question and user_id = auth.uid();
  if q is null then return; end if;
  if not p_yes then delete from public.match_questions where id = q.id; return; end if;
  select * into se from public.shared_entries where id = q.entry_id;
  select * into t from public.transactions where id = q.txn_id;
  select case when l.a = auth.uid() then l.a_name_for_b else l.b_name_for_a end into fname
    from public.friend_links l where l.id = se.link_id;
  if se.creditor = auth.uid() then update public.shared_entries set creditor_txn = t.id where id = se.id;
  else update public.shared_entries set debtor_txn = t.id where id = se.id; end if;
  select id into cat from public.categories where user_id = auth.uid() and kind = 'loan' order by name = 'Friends' desc limit 1;
  update public.transactions set category_id = cat, needs_review = false where id = t.id;
  if coalesce(t.merchant_key, '') <> '' and lower(t.merchant_key) <> lower(fname) then
    insert into public.friend_aliases (user_id, alias_key, friend_name) values (auth.uid(), t.merchant_key, fname)
    on conflict (user_id, alias_key) do update set friend_name = excluded.friend_name;
    insert into public.merchant_rules (user_id, merchant_key, category_id) values (auth.uid(), t.merchant_key, cat)
    on conflict (user_id, merchant_key) do update set category_id = excluded.category_id;
  end if;
  delete from public.match_questions where entry_id = se.id;
end $$;
grant execute on function public.answer_match(uuid, boolean) to authenticated;

-- "Also known as": this payee name is that friend (parent's account, second bank…).
create or replace function public.add_friend_alias(p_alias text, p_friend text)
returns integer language plpgsql security invoker set search_path = public as $$
declare k text := btrim(lower(regexp_replace(p_alias, '\s+', ' ', 'g')));
begin
  insert into public.friend_aliases (user_id, alias_key, friend_name) values (auth.uid(), k, btrim(p_friend))
  on conflict (user_id, alias_key) do update set friend_name = excluded.friend_name;
  return public.mark_friend(k, true);
end $$;
grant execute on function public.add_friend_alias(text, text) to authenticated;

-- A payment from/to someone not known as a friend, but a connected friend recorded the
-- same amount within a day: ask "was this it?" (e.g. paid from a parent's account).
create or replace function public.ask_about_txn(p_txn uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t record; se record;
begin
  select tr.*, c.kind as cat_kind into t
    from public.transactions tr left join public.categories c on c.id = tr.category_id where tr.id = p_txn;
  if t is null or t.cat_kind = 'loan' or t.excluded or t.loan_role is not null or t.paid_by is not null then return; end if;
  if exists (select 1 from public.shared_entries where creditor_txn = p_txn or debtor_txn = p_txn) then return; end if;
  for se in
    select x.id from public.shared_entries x
     where x.deleted_at is null and x.kind <> 'expense' and x.amount = t.amount and x.created_by <> t.user_id
       and ((t.direction = 'credit' and x.debtor = t.user_id and x.debtor_txn is null)
         or (t.direction = 'debit' and x.creditor = t.user_id and x.creditor_txn is null))
       and abs(extract(epoch from x.at - t.txn_at)) <= 86400
     limit 3
  loop
    insert into public.match_questions (user_id, entry_id, txn_id) values (t.user_id, se.id, p_txn) on conflict do nothing;
  end loop;
end $$;

create or replace function public.on_txn_friend_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.sync_friend_txn(new.id);
  perform public.ask_about_txn(new.id);
  return null;
end $$;
