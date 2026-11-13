-- 1. A payee shown as its UPI ID ("Vaibhavparmar25okici") gets the name the bank gave the same UPI ID elsewhere.
create or replace function public.fix_vpa_names(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  with named as (
    select distinct on (payee_vpa) payee_vpa, merchant
      from public.transactions
     where user_id = p_user and payee_vpa is not null and merchant ~ ' '
     group by payee_vpa, merchant
     order by payee_vpa, count(*) desc
  )
  update public.transactions t set merchant = named.merchant
    from named
   where t.user_id = p_user and not t.edited and t.payee_vpa = named.payee_vpa
     and t.merchant !~ ' ' and t.merchant ~ '[0-9]';
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.fix_vpa_names(uuid) to authenticated, service_role;

do $$ declare u uuid; begin
  for u in select id from auth.users loop perform public.fix_vpa_names(u); end loop;
end $$;

-- 2. "Not the same person": names the app should stop suggesting as another name for a friend.
alter table public.profiles add column if not exists not_same text[] not null default '{}';
