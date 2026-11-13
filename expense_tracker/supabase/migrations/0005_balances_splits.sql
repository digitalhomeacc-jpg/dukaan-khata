-- Bank balances read from emails, and payments shared with friends.

-- "Balance as of yesterday: Rs. 21.91" / "Avl Bal Rs 22,341.10" for one account.
create table public.balance_readings (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users on delete cascade,
  account_id  uuid not null references public.accounts on delete cascade,
  balance     numeric(14, 2) not null,
  as_of       timestamptz not null,
  email_id    text,
  created_at  timestamptz not null default now(),
  unique (user_id, email_id)
);
create index balance_readings_account on public.balance_readings (account_id, as_of desc);

-- One friend's part of a payment you made for a group (e.g. a food order).
-- paid_txn_id: the money they sent you back; until then they owe you.
create table public.txn_shares (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users on delete cascade,
  txn_id       uuid not null references public.transactions on delete cascade,
  person       text not null check (length(btrim(person)) between 1 and 60),
  amount       numeric(14, 2) not null check (amount > 0),
  paid_txn_id  uuid references public.transactions on delete set null,
  paid_at      timestamptz,
  created_at   timestamptz not null default now()
);
create index txn_shares_txn on public.txn_shares (txn_id);
create unique index txn_shares_paid_once on public.txn_shares (paid_txn_id) where paid_txn_id is not null;

alter table public.balance_readings enable row level security;
alter table public.txn_shares       enable row level security;
create policy "own balances" on public.balance_readings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own shares" on public.txn_shares
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table public.unparsed_emails drop constraint if exists unparsed_emails_kind_check;
alter table public.unparsed_emails add constraint unparsed_emails_kind_check
  check (kind in ('unreadable', 'lender', 'review'));

alter publication supabase_realtime add table public.balance_readings, public.txn_shares;
