-- A payee written as its UPI ID ("Sindgineelokicici" = sindgineel@okicici, "Vaibhavparmar25okici") takes the
-- real name the bank gave the same UPI ID elsewhere, when that name's words are in it. No digits needed.
create or replace function public.fix_vpa_names(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  with named as (
    select payee_vpa, merchant, count(*) c from public.transactions
     where user_id = p_user and payee_vpa is not null and merchant ~ ' ' group by 1, 2
  ), best as (
    select distinct on (payee_vpa) payee_vpa, merchant from named order by payee_vpa, c desc
  )
  update public.transactions t set merchant = best.merchant
    from best
   where t.user_id = p_user and not t.edited and t.payee_vpa = best.payee_vpa and t.merchant !~ ' '
     and exists (select 1 from regexp_split_to_table(lower(best.merchant), '\s+') w
                  where length(w) >= 4 and position(w in lower(t.merchant)) > 0);
  get diagnostics n = row_count;
  return n;
end $$;

do $$ declare u uuid; begin
  for u in select id from auth.users loop
    perform public.fix_vpa_names(u);
    perform public.apply_friend_aliases(u);
  end loop;
end $$;
