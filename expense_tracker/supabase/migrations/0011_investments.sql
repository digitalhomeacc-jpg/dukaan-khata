-- Investments (Zerodha, Groww, mutual funds…): money moved into investments is not
-- spending, and money coming back is not income.
alter table public.categories drop constraint if exists categories_kind_check;
alter table public.categories add constraint categories_kind_check check (kind in ('normal', 'loan', 'investment'));

insert into public.categories (user_id, name, icon, color, kind)
select id, 'Investments', 'savings', 4278228616, 'investment' from auth.users  -- 0xFF009688
on conflict (user_id, name) do update set kind = 'investment';

-- Imported statement names that kept the UPI ID after a dash: "Shreyash Sandeep Shi-7822965946".
update public.transactions
   set merchant = btrim(regexp_replace(merchant, '-[^ ]*$', ''))
 where source = 'statement' and merchant ~ '-[^ ]+$' and merchant !~ '^[^ ]+-';

-- New users get the Investments category too.
create or replace function public.add_investments_category()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.categories (user_id, name, icon, color, kind)
  values (new.id, 'Investments', 'savings', 4278228616, 'investment') on conflict (user_id, name) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created_investments on auth.users;
create trigger on_auth_user_created_investments after insert on auth.users
  for each row execute function public.add_investments_category();
