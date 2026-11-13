-- Categories by UPI ID: "everything paid to ••7243@y is Cigarettes", even when the payee is a person's
-- name that you also pay for other things on another UPI ID.
create table if not exists public.vpa_rules (
  user_id     uuid not null default auth.uid() references auth.users on delete cascade,
  vpa         text not null,
  category_id uuid not null references public.categories on delete cascade,
  primary key (user_id, vpa)
);
alter table public.vpa_rules enable row level security;
drop policy if exists "own vpa rules" on public.vpa_rules;
create policy "own vpa rules" on public.vpa_rules
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

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
     and not t.edited and not t.excluded and t.loan_role is null and t.category_id is distinct from r.category_id;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.apply_vpa_rules(uuid) to authenticated, service_role;

-- Set the category of a place's payments (by id) and remember it for new ones: by UPI ID, and by name
-- when the app passes names (businesses). A null category forgets the rules.
create or replace function public.categorize_place(p_ids uuid[], p_vpas text[], p_names text[], p_category uuid)
returns integer language plpgsql security invoker set search_path = public as $$
declare n integer;
begin
  update public.transactions set category_id = p_category, needs_review = false
   where user_id = auth.uid() and id = any(coalesce(p_ids, '{}')) and not edited;
  get diagnostics n = row_count;
  if p_category is null then
    delete from public.vpa_rules where user_id = auth.uid() and vpa = any(coalesce(p_vpas, '{}'));
    delete from public.merchant_rules where user_id = auth.uid() and merchant_key = any(coalesce(p_names, '{}'));
  else
    insert into public.vpa_rules (user_id, vpa, category_id)
    select auth.uid(), v, p_category from unnest(coalesce(p_vpas, '{}')) v where coalesce(v, '') <> ''
    on conflict (user_id, vpa) do update set category_id = excluded.category_id;
    insert into public.merchant_rules (user_id, merchant_key, category_id)
    select auth.uid(), k, p_category from unnest(coalesce(p_names, '{}')) k where coalesce(k, '') <> ''
    on conflict (user_id, merchant_key) do update set category_id = excluded.category_id;
    n := n + public.apply_vpa_rules(auth.uid());
  end if;
  return n;
end $$;
grant execute on function public.categorize_place(uuid[], text[], text[], uuid) to authenticated;
