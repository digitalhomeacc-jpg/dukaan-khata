-- 1. Tell places with the same name apart by their UPI ID ("Hotel Vijay" nashta centre vs
--    "HOTEL VIJAY" restaurant). Emails mask the ID (******6712@ybl), so the last 4 characters
--    before the @ plus the bank handle are kept: "6712@ybl".
alter table public.transactions add column if not exists payee_vpa text;

create or replace function public.vpa_tail(p_vpa text)
returns text language sql immutable as $$
  -- Statements cut the bank handle short ("…7243@y"), so only its first letter is kept.
  select case when p_vpa ~ '@' then lower(right(split_part(p_vpa, '@', 1), 4) || '@' || left(split_part(p_vpa, '@', 2), 1)) end
$$;

update public.transactions
   set payee_vpa = public.vpa_tail(substring(regexp_replace(email_body, '\s+', ' ', 'g') from '(?i)VPA:?\s*\**([A-Za-z0-9.\-_]*@[A-Za-z0-9.\-]+)'))
 where payee_vpa is null and source = 'email' and email_body ~* 'VPA';
update public.transactions
   set payee_vpa = public.vpa_tail(substring(note from '^UPI[-/][^-]+?-([^\s]*@[^-\s]+)'))
 where payee_vpa is null and source = 'statement' and note ~* '^UPI[-/]';

-- 2. Your own name for a place ("Hotel Vijay (nashta)"), by UPI ID, else by name.
create table if not exists public.payee_names (
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  match_key  text not null,              -- 'vpa:6712@ybl' or 'name:hotel vijay'
  nickname   text not null check (length(btrim(nickname)) between 1 and 48),
  primary key (user_id, match_key)
);
alter table public.payee_names enable row level security;
drop policy if exists "own payee names" on public.payee_names;
create policy "own payee names" on public.payee_names
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.apply_payee_names(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; c integer;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  update public.transactions t set merchant = p.nickname
    from public.payee_names p
   where p.user_id = p_user and t.user_id = p_user and not t.edited and t.merchant is distinct from p.nickname
     and ((p.match_key like 'vpa:%' and t.payee_vpa = substr(p.match_key, 5))
       or (p.match_key like 'name:%' and t.payee_vpa is null and t.merchant_key = substr(p.match_key, 6)));
  get diagnostics c = row_count; n := n + c;
  return n;
end $$;
grant execute on function public.apply_payee_names(uuid) to authenticated, service_role;

-- Rename a place everywhere (by its UPI IDs, or names when it has none), now and later.
create or replace function public.rename_place(p_vpas text[], p_names text[], p_nickname text)
returns integer language plpgsql security invoker set search_path = public as $$
begin
  insert into public.payee_names (user_id, match_key, nickname)
  select auth.uid(), 'vpa:' || v, btrim(p_nickname) from unnest(coalesce(p_vpas, '{}')) v where v is not null and v <> ''
  union
  select auth.uid(), 'name:' || n, btrim(p_nickname) from unnest(coalesce(p_names, '{}')) n where n is not null and n <> ''
  on conflict (user_id, match_key) do update set nickname = excluded.nickname;
  return public.apply_payee_names(auth.uid());
end $$;
grant execute on function public.rename_place(text[], text[], text) to authenticated;

-- 3. Category groups: "Smoking & alcohol" → Cigarettes, Alcohol.
alter table public.categories add column if not exists parent_id uuid references public.categories on delete set null;
