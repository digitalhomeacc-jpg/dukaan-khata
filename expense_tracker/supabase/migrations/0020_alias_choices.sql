-- Renaming a place keeps "Also known as" links pointing at the new name, so the two never fight.
create or replace function public.rename_place(p_vpas text[], p_names text[], p_nickname text)
returns integer language plpgsql security invoker set search_path = public as $$
declare nk text := btrim(lower(regexp_replace(p_nickname, '\s+', ' ', 'g')));
        olds text[];
begin
  select array_agg(btrim(lower(regexp_replace(n, '\s+', ' ', 'g')))) into olds from unnest(coalesce(p_names, '{}')) n;
  insert into public.payee_names (user_id, match_key, nickname)
  select auth.uid(), 'vpa:' || v, btrim(p_nickname) from unnest(coalesce(p_vpas, '{}')) v where v is not null and v <> ''
  union
  select auth.uid(), 'name:' || n, btrim(p_nickname) from unnest(coalesce(p_names, '{}')) n where n is not null and n <> ''
  on conflict (user_id, match_key) do update set nickname = excluded.nickname;
  -- Links to the old name follow it; a link that would rename the new name away is dropped.
  update public.friend_aliases set friend_name = btrim(p_nickname)
   where user_id = auth.uid() and btrim(lower(regexp_replace(friend_name, '\s+', ' ', 'g'))) = any(coalesce(olds, '{}'));
  delete from public.friend_aliases where user_id = auth.uid() and alias_key = nk;
  update public.people set name_key = nk, name = btrim(p_nickname)
   where user_id = auth.uid() and name_key = any(coalesce(olds, '{}'))
     and not exists (select 1 from public.people p2 where p2.user_id = auth.uid() and p2.name_key = nk);
  return public.apply_payee_names(auth.uid()) + public.apply_friend_aliases(auth.uid());
end $$;
grant execute on function public.rename_place(text[], text[], text) to authenticated;

-- Undo "Also known as": the other name's payments get their bank name back.
create or replace function public.remove_friend_alias(p_alias text)
returns integer language plpgsql security invoker set search_path = public as $$
declare k text := btrim(lower(regexp_replace(p_alias, '\s+', ' ', 'g'))); n integer;
begin
  delete from public.friend_aliases where user_id = auth.uid() and alias_key = k;
  update public.transactions set merchant = bank_name, bank_name = null
   where user_id = auth.uid() and not edited and bank_name is not null
     and btrim(lower(regexp_replace(bank_name, '\s+', ' ', 'g'))) = k;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.remove_friend_alias(text) to authenticated;
