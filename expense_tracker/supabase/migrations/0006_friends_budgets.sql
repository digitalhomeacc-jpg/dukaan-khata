-- Friends (Splitwise-style) and monthly budgets.

-- The loan-kind category becomes "Friends": money to/from friends is not spending or income.
update public.categories set name = 'Friends', icon = 'group'
 where kind = 'loan' and name = 'Personal loans'
   and not exists (select 1 from public.categories c2 where c2.user_id = categories.user_id and c2.name = 'Friends');

-- An expense a friend paid for you: `amount` is your share, `paid_by` the friend you now owe.
alter table public.transactions add column if not exists paid_by text;

-- Mark a payee as a friend: remember it, and move their past transactions to Friends.
create or replace function public.mark_friend(p_merchant_key text, p_friend boolean default true)
returns integer language plpgsql security invoker set search_path = public as $$
declare cat uuid; n integer;
begin
  select id into cat from public.categories where user_id = auth.uid() and kind = 'loan' order by name = 'Friends' desc limit 1;
  if cat is null then
    insert into public.categories (user_id, name, icon, color, kind)
    values (auth.uid(), 'Friends', 'group', 4282339765, 'loan') returning id into cat;
  end if;
  if p_friend then
    insert into public.merchant_rules (user_id, merchant_key, category_id) values (auth.uid(), p_merchant_key, cat)
    on conflict (user_id, merchant_key) do update set category_id = excluded.category_id;
    update public.transactions set category_id = cat, needs_review = false
     where user_id = auth.uid() and merchant_key = p_merchant_key and not edited and loan_role is null;
  else
    delete from public.merchant_rules where user_id = auth.uid() and merchant_key = p_merchant_key and category_id = cat;
    update public.transactions set category_id = null
     where user_id = auth.uid() and merchant_key = p_merchant_key and category_id = cat and not edited;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.mark_friend(text, boolean) to authenticated;

-- Monthly budget: per category, or overall when category_id is null.
create table public.budgets (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users on delete cascade,
  category_id  uuid references public.categories on delete cascade,
  amount       numeric(14, 2) not null check (amount > 0),
  created_at   timestamptz not null default now()
);
create unique index budgets_one_per_category on public.budgets (user_id, coalesce(category_id, '00000000-0000-0000-0000-000000000000'::uuid));
alter table public.budgets enable row level security;
create policy "own budgets" on public.budgets
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
alter publication supabase_realtime add table public.budgets;

-- New users start with a "Friends" category.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)));

  insert into public.categories (user_id, name, icon, color, kind) values
    (new.id, 'Food & Dining',    'restaurant',     4294924066, 'normal'),
    (new.id, 'Groceries',        'shopping_cart',  4283215696, 'normal'),
    (new.id, 'Shopping',         'shopping_bag',   4293467747, 'normal'),
    (new.id, 'Transport',        'directions_car', 4280391411, 'normal'),
    (new.id, 'Bills & Utilities','receipt',        4294940672, 'normal'),
    (new.id, 'Entertainment',    'movie',          4288423856, 'normal'),
    (new.id, 'Health',           'local_hospital', 4294198070, 'normal'),
    (new.id, 'Travel',           'flight',         4278238420, 'normal'),
    (new.id, 'Rent',             'home',           4286141768, 'normal'),
    (new.id, 'Salary',           'payments',       4278228616, 'normal'),
    (new.id, 'Transfers',        'swap_horiz',     4284513675, 'normal'),
    (new.id, 'Friends',          'group',          4282339765, 'loan'),
    (new.id, 'Other',            'label',          4288585374, 'normal');

  insert into public.accounts (user_id, name, kind) values (new.id, 'Cash', 'cash');
  return new;
end $$;

-- Payees the user said are not friends (e.g. a shop on a personal UPI ID): not suggested again.
alter table public.profiles add column if not exists not_friends text[] not null default '{}';
grant update (not_friends) on public.profiles to authenticated;
