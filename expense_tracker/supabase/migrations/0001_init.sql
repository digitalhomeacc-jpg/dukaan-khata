-- Expense Tracker schema. Every row belongs to one user; Row Level Security
-- makes sure a user can only ever see and change their own rows.

create extension if not exists pgcrypto;

-- ------------------------------------------------------------------ profiles
create table public.profiles (
  id            uuid primary key references auth.users on delete cascade,
  display_name  text,
  -- Secret the user's Google Apps Script sends with each batch of emails.
  ingest_token  text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  last_sync_at  timestamptz,
  created_at    timestamptz not null default now()
);

-- -------------------------------------------------------------- categories
create table public.categories (
  id       uuid primary key default gen_random_uuid(),
  user_id  uuid not null default auth.uid() references auth.users on delete cascade,
  name     text not null check (length(btrim(name)) between 1 and 40),
  icon     text not null default 'label',
  color    bigint not null default 4284513675, -- 0xFF607D8B
  unique (user_id, name)
);

-- ------------------------------------------------------------ transactions
create table public.transactions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users on delete cascade,
  amount         numeric(14, 2) not null check (amount > 0),
  direction      text not null check (direction in ('debit', 'credit')),
  merchant       text,
  merchant_key   text generated always as
                   (btrim(lower(regexp_replace(coalesce(merchant, ''), '\s+', ' ', 'g')))) stored,
  note           text,
  bank           text,
  account_last4  text,
  method         text not null default 'other'
                   check (method in ('upi', 'card', 'netbanking', 'atm', 'cash', 'other')),
  txn_at         timestamptz not null default now(),
  category_id    uuid references public.categories on delete set null,
  source         text not null default 'manual' check (source in ('manual', 'email')),
  email_id       text,
  email_subject  text,
  -- Left out of the spent / received totals (card bill payments, own transfers).
  excluded       boolean not null default false,
  needs_review   boolean not null default false,
  created_at     timestamptz not null default now(),
  unique (user_id, email_id)
);
create index transactions_user_time on public.transactions (user_id, txn_at desc);

-- Category remembered per merchant: "SWIGGY" → Food.
create table public.merchant_rules (
  user_id       uuid not null default auth.uid() references auth.users on delete cascade,
  merchant_key  text not null,
  category_id   uuid not null references public.categories on delete cascade,
  primary key (user_id, merchant_key)
);

-- Bank emails that looked like a transaction but could not be read.
create table public.unparsed_emails (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  email_id     text not null,
  from_addr    text,
  subject      text,
  body         text,
  received_at  timestamptz,
  created_at   timestamptz not null default now(),
  unique (user_id, email_id)
);

-- --------------------------------------------------------------------- RLS
alter table public.profiles        enable row level security;
alter table public.categories      enable row level security;
alter table public.transactions    enable row level security;
alter table public.merchant_rules  enable row level security;
alter table public.unparsed_emails enable row level security;

create policy "own profile" on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());
create policy "own categories" on public.categories
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own transactions" on public.transactions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own rules" on public.merchant_rules
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own unparsed" on public.unparsed_emails
  for select using (user_id = auth.uid());
create policy "delete own unparsed" on public.unparsed_emails
  for delete using (user_id = auth.uid());

-- Users may rename themselves but never set their own token or sync time.
revoke insert, update, delete on public.profiles from authenticated, anon;
grant update (display_name) on public.profiles to authenticated;

-- ------------------------------------------------------- new user set-up
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)));

  insert into public.categories (user_id, name, icon, color) values
    (new.id, 'Food & Dining',   'restaurant',     4294924066),  -- 0xFFFF5722
    (new.id, 'Groceries',       'shopping_cart',  4283215696),  -- 0xFF4CAF50
    (new.id, 'Shopping',        'shopping_bag',   4293467747),  -- 0xFFE91E63
    (new.id, 'Transport',       'directions_car', 4280391411),  -- 0xFF2196F3
    (new.id, 'Bills & Utilities','receipt',       4294940672),  -- 0xFFFF9800
    (new.id, 'Entertainment',   'movie',          4288423856),  -- 0xFF9C27B0
    (new.id, 'Health',          'local_hospital', 4294198070),  -- 0xFFF44336
    (new.id, 'Travel',          'flight',         4278238420),  -- 0xFF00BCD4
    (new.id, 'Rent',            'home',           4286141768),  -- 0xFF795548
    (new.id, 'Salary',          'payments',       4278228616),  -- 0xFF009688
    (new.id, 'Transfers',       'swap_horiz',     4284513675),  -- 0xFF607D8B
    (new.id, 'Other',           'label',          4288585374);  -- 0xFF9E9E9E
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- New secret for the Gmail script (old script stops working until updated).
create or replace function public.regenerate_ingest_token()
returns text language plpgsql security definer set search_path = public as $$
declare t text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  update public.profiles set ingest_token = t where id = auth.uid();
  return t;
end $$;
revoke execute on function public.regenerate_ingest_token() from anon, public;
grant execute on function public.regenerate_ingest_token() to authenticated;

-- Set a transaction's category; optionally remember it for the merchant and
-- apply it to that merchant's other uncategorised transactions.
create or replace function public.set_category(p_txn uuid, p_category uuid, p_remember boolean)
returns integer language plpgsql security invoker set search_path = public as $$
declare k text; n integer := 0;
begin
  update public.transactions set category_id = p_category, needs_review = false
   where id = p_txn returning merchant_key into k;
  if p_remember and p_category is not null and coalesce(k, '') <> '' then
    insert into public.merchant_rules (user_id, merchant_key, category_id)
    values (auth.uid(), k, p_category)
    on conflict (user_id, merchant_key) do update set category_id = excluded.category_id;
    update public.transactions set category_id = p_category
     where user_id = auth.uid() and merchant_key = k and category_id is null;
    get diagnostics n = row_count;
  end if;
  return n;
end $$;

-- Live updates in the app when the Gmail script adds transactions.
alter publication supabase_realtime add table public.transactions, public.categories, public.profiles;
