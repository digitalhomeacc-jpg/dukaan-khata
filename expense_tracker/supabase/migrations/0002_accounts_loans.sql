-- Accounts (cash, bank accounts, cards, wallets) and personal loans.

-- --------------------------------------------------------------- accounts
create table public.accounts (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users on delete cascade,
  name             text not null check (length(btrim(name)) between 1 and 40),
  kind             text not null default 'bank' check (kind in ('cash', 'bank', 'card', 'wallet')),
  bank             text,
  last4            text,
  -- Money in the account before the first transaction in the app.
  -- For a credit card: minus what was owed (e.g. -12000).
  opening_balance  numeric(14, 2) not null default 0,
  archived         boolean not null default false,
  created_at       timestamptz not null default now(),
  unique (user_id, name)
);
create index accounts_bank_last4 on public.accounts (user_id, bank, last4);

alter table public.accounts enable row level security;
create policy "own accounts" on public.accounts
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Where the money left (debit) or arrived (credit), and for a move between
-- your own accounts the other side (e.g. ATM withdrawal: bank → Cash).
alter table public.transactions
  add column account_id          uuid references public.accounts on delete set null,
  add column counter_account_id  uuid references public.accounts on delete set null;

-- --------------------------------------------------------- personal loans
-- A 'loan' category is left out of spending / income. Its transactions use the
-- merchant field for the friend's name: received = you borrowed or were repaid,
-- spent = you lent or repaid.
alter table public.categories
  add column kind text not null default 'normal' check (kind in ('normal', 'loan'));

-- --------------------------------------------------- existing users
insert into public.categories (user_id, name, icon, color, kind)
select id, 'Personal loans', 'handshake', 4282339765, 'loan' from auth.users  -- 0xFF3F51B5
on conflict (user_id, name) do update set kind = 'loan';

insert into public.accounts (user_id, name, kind)
select id, 'Cash', 'cash' from auth.users
on conflict (user_id, name) do nothing;

-- One account per bank + last 4 digits seen in imported emails.
insert into public.accounts (user_id, name, kind, bank, last4)
select distinct on (user_id, bank, account_last4)
       user_id,
       left(bank || case when email_subject ilike '%credit card%' then ' Card' else ' A/c' end || ' ••' || account_last4, 40),
       case when email_subject ilike '%credit card%' then 'card' else 'bank' end,
       bank, account_last4
  from public.transactions
 where bank is not null and account_last4 is not null
on conflict (user_id, name) do nothing;

update public.transactions t set account_id = a.id
  from public.accounts a
 where t.account_id is null and a.user_id = t.user_id and a.bank = t.bank and a.last4 = t.account_last4;

-- ----------------------------------------------------- new user set-up
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
    (new.id, 'Personal loans',   'handshake',      4282339765, 'loan'),
    (new.id, 'Other',            'label',          4288585374, 'normal');

  insert into public.accounts (user_id, name, kind) values (new.id, 'Cash', 'cash');
  return new;
end $$;

alter publication supabase_realtime add table public.accounts;
