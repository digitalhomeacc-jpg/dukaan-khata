-- People have a role, which decides what their money is:
--   friend: normal spending/income (they bought something for you); the Friends ledger
--           only gets payments you mark as lent / borrowed / settle, plus splits
--   family: money from them is income ("Money from home"), money to them is "Family" spending
--   me:     your own account elsewhere: a move, not spending or income
--   shop:   a shop or service on a personal UPI ID: normal spending
create table if not exists public.people (
  user_id   uuid not null default auth.uid() references auth.users on delete cascade,
  name_key  text not null,
  name      text not null,
  role      text not null check (role in ('friend', 'family', 'me', 'shop')),
  primary key (user_id, name_key)
);
alter table public.people enable row level security;
drop policy if exists "own people" on public.people;
create policy "own people" on public.people
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
do $$ begin
  alter publication supabase_realtime add table public.people;
exception when duplicate_object then null; end $$;

-- Income and family categories for everyone.
insert into public.categories (user_id, name, icon, color, kind)
select id, 'Money from home', 'home', 4283215696, 'normal' from auth.users   -- 0xFF4CAF50
on conflict (user_id, name) do nothing;
insert into public.categories (user_id, name, icon, color, kind)
select id, 'Family', 'group', 4286141768, 'normal' from auth.users          -- 0xFF795548
on conflict (user_id, name) do nothing;
create or replace function public.add_people_categories()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.categories (user_id, name, icon, color, kind) values
    (new.id, 'Money from home', 'home', 4283215696, 'normal'),
    (new.id, 'Family', 'group', 4286141768, 'normal')
  on conflict (user_id, name) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created_people on auth.users;
create trigger on_auth_user_created_people after insert on auth.users
  for each row execute function public.add_people_categories();

-- Does this payee name mean that person? Statements cut names short ("Shri Dagajirao Luka P").
create or replace function public.is_person(p_merchant_key text, p_name_key text)
returns boolean language sql immutable as $$
  select p_merchant_key = p_name_key
      or p_merchant_key like p_name_key || ' %'
      or (length(p_merchant_key) >= 12 and p_name_key like p_merchant_key || '%')
$$;

-- Apply people's roles to transactions not sorted by hand.
create or replace function public.apply_people(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; c integer; home uuid; fam uuid;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  select id into home from public.categories where user_id = p_user and name = 'Money from home';
  select id into fam from public.categories where user_id = p_user and name = 'Family';

  update public.transactions t set excluded = true, needs_review = false
    from public.people p
   where p.user_id = p_user and p.role = 'me' and t.user_id = p_user
     and not t.edited and not t.excluded and t.loan_role is null and public.is_person(t.merchant_key, p.name_key);
  get diagnostics c = row_count; n := n + c;

  update public.transactions t
     set category_id = case when t.direction = 'credit' then home else fam end, needs_review = false
    from public.people p
   where p.user_id = p_user and p.role = 'family' and t.user_id = p_user
     and not t.edited and not t.excluded and t.loan_role is null
     and (t.category_id is null or t.category_id in (select id from public.categories where user_id = p_user and kind = 'loan'))
     and public.is_person(t.merchant_key, p.name_key);
  get diagnostics c = row_count; n := n + c;
  return n;
end $$;
grant execute on function public.apply_people(uuid) to authenticated, service_role;

-- Set a person's role and apply it.
create or replace function public.set_person_role(p_name text, p_role text)
returns integer language plpgsql security invoker set search_path = public as $$
declare k text := btrim(lower(regexp_replace(p_name, '\s+', ' ', 'g')));
begin
  insert into public.people (user_id, name_key, name, role) values (auth.uid(), k, btrim(p_name), p_role)
  on conflict (user_id, name_key) do update set role = excluded.role, name = excluded.name;
  -- A friend's payments are no longer filed into the ledger automatically.
  delete from public.merchant_rules r using public.categories c
   where r.user_id = auth.uid() and r.category_id = c.id and c.kind = 'loan' and public.is_person(r.merchant_key, k);
  return public.apply_people(auth.uid());
end $$;
grant execute on function public.set_person_role(text, text) to authenticated;
