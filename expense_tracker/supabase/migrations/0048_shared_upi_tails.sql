-- The app keeps only the end of a UPI ID ("kunal2002@okaxis" → "2002@o"), because statements cut it short.
-- Different people can end the same way (born in 2002, the same last digits): such an ending says nothing about
-- who was paid. It is ignored for category rules: the payee's name (and what you did with it before) decides.
-- A real UPI ID has one account holder, so: 3 or more full names on one ending, or 2 on an ending that is a year.
create or replace function public.vpa_is_shared(p_user uuid, p_vpa text)
returns boolean language sql stable security definer set search_path = public as $$
  with names as (
    select distinct merchant_key from public.transactions
     where user_id = p_user and payee_vpa = p_vpa and merchant_key ~ '^[a-z]+ [a-z]'
  )
  select p_vpa is not null and ((select count(*) from names) >= 3
         or ((select count(*) from names) >= 2 and p_vpa ~ '^(19[5-9][0-9]|20[0-2][0-9])@'))
$$;

create or replace function public.payee_category(p_user uuid, p_key text, p_vpa text, p_except uuid default null)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare c uuid; n integer;
begin
  if coalesce(p_key, '') = '' then return null; end if;
  select category_id into c from public.merchant_rules where user_id = p_user and merchant_key = p_key;
  if c is not null then return c; end if;
  select count(distinct category_id), min(category_id::text)::uuid into n, c from public.merchant_rules
   where user_id = p_user and public.same_payee(merchant_key, p_key);
  if n = 1 then return c; end if;
  if p_vpa is not null and not public.vpa_is_shared(p_user, p_vpa) then
    select category_id into c from public.vpa_rules where user_id = p_user and vpa = p_vpa;
    if c is not null then return c; end if;
  end if;
  select count(distinct category_id), min(category_id::text)::uuid into n, c from public.transactions
   where user_id = p_user and category_id is not null and not excluded and loan_role is null
     and id is distinct from p_except and public.same_payee(merchant_key, p_key);
  if n = 1 then return c; end if;
  return null;
end $$;

create or replace function public.apply_vpa_rules(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  update public.transactions t set category_id = r.category_id, needs_review = false
    from public.vpa_rules r
   where r.user_id = p_user and t.user_id = p_user and t.payee_vpa = r.vpa
     and not t.edited and not t.excluded and t.loan_role is null and t.category_id is distinct from r.category_id
     and not public.vpa_is_shared(p_user, r.vpa);
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.apply_vpa_rules(uuid) to authenticated, service_role;
