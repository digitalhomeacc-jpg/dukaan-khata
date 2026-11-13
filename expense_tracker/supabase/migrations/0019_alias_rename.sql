-- "Also known as" shows a friend under one name: payments under the other name are renamed to the friend
-- (the bank's own name is kept in bank_name), now and for new payments. They take the friend's treatment
-- (spends, or the Friends ledger when the friend is set that way) instead of all going to the ledger.
alter table public.transactions add column if not exists bank_name text;

create or replace function public.apply_friend_aliases(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  update public.transactions t
     set bank_name = coalesce(t.bank_name, t.merchant), merchant = a.friend_name
    from public.friend_aliases a
   where a.user_id = p_user and t.user_id = p_user and not t.edited
     and t.merchant_key = a.alias_key and t.merchant is distinct from a.friend_name;
  get diagnostics n = row_count;
  -- The friend's own rule (e.g. Friends ledger) applies to payments that have no category yet.
  update public.transactions t set category_id = r.category_id, needs_review = false
    from public.merchant_rules r
   where r.user_id = p_user and t.user_id = p_user and not t.edited and t.category_id is null
     and t.bank_name is not null and t.merchant_key = r.merchant_key;
  return n;
end $$;
grant execute on function public.apply_friend_aliases(uuid) to authenticated, service_role;

create or replace function public.add_friend_alias(p_alias text, p_friend text)
returns integer language plpgsql security invoker set search_path = public as $$
declare k text := btrim(lower(regexp_replace(p_alias, '\s+', ' ', 'g')));
        f text := btrim(lower(regexp_replace(p_friend, '\s+', ' ', 'g')));
        cat uuid;
begin
  if k = f then return 0; end if;
  -- One direction only: the chosen main name is never itself an alias.
  delete from public.friend_aliases where user_id = auth.uid() and alias_key = f;
  insert into public.friend_aliases (user_id, alias_key, friend_name) values (auth.uid(), k, btrim(p_friend))
  on conflict (user_id, alias_key) do update set friend_name = excluded.friend_name;
  -- Names that pointed at the alias now point at the main name.
  update public.friend_aliases set friend_name = btrim(p_friend)
   where user_id = auth.uid() and btrim(lower(regexp_replace(friend_name, '\s+', ' ', 'g'))) = k;
  -- The other name's own ledger rule goes: it follows the friend now.
  select id into cat from public.categories where user_id = auth.uid() and kind = 'loan' limit 1;
  delete from public.merchant_rules where user_id = auth.uid() and merchant_key = k and category_id = cat;
  return public.apply_friend_aliases(auth.uid());
end $$;
grant execute on function public.add_friend_alias(text, text) to authenticated;
