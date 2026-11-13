-- Loans from lenders (Slice borrow, KreditBee, Fibe…), with details.
-- Friends' loans stay as the 'Personal loans' category.

create table public.loans (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null default auth.uid() references auth.users on delete cascade,
  lender            text not null,                 -- 'slice', 'kreditbee', 'fibe' or any name
  name              text not null,                 -- shown on the card, e.g. 'Slice borrow'
  kind              text not null default 'emi' check (kind in ('emi', 'credit_line')),
  principal         numeric(14, 2),                -- amount borrowed
  emi_amount        numeric(14, 2),
  tenure_months     integer check (tenure_months between 1 and 600),
  emis_paid_before  integer not null default 0,    -- EMIs paid before tracking started
  interest_rate     numeric(6, 2),                 -- % a year
  due_day           integer check (due_day between 1 and 31),
  next_due_amount   numeric(14, 2),
  next_due_date     date,
  outstanding       numeric(14, 2),                -- amount owed at outstanding_at (set by the user)
  outstanding_at    timestamptz,
  aliases           text[] not null default '{}',  -- payee names that mean this lender
  account_id        uuid references public.accounts on delete set null, -- credit line used for purchases
  closed            boolean not null default false,
  created_at        timestamptz not null default now(),
  unique (user_id, name)
);

-- borrow: money lent to you; spend: a purchase paid by the loan; repay: you paid back.
create table public.loan_events (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users on delete cascade,
  loan_id     uuid not null references public.loans on delete cascade,
  kind        text not null check (kind in ('borrow', 'spend', 'repay')),
  amount      numeric(14, 2) not null check (amount > 0),
  event_at    timestamptz not null default now(),
  note        text,
  email_id    text,
  txn_id      uuid references public.transactions on delete cascade,
  created_at  timestamptz not null default now(),
  unique (user_id, email_id),
  unique (txn_id)
);
create index loan_events_loan on public.loan_events (loan_id, event_at);

-- A bank transaction can be money from a loan (borrow) or paying it back (repay):
-- neither is income or spending.
alter table public.transactions
  add column if not exists loan_id   uuid references public.loans on delete set null,
  add column if not exists loan_role text check (loan_role in ('borrow', 'repay', 'spend'));

alter table public.loans       enable row level security;
alter table public.loan_events enable row level security;
create policy "own loans" on public.loans
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own loan events" on public.loan_events
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter publication supabase_realtime add table public.loans, public.loan_events;

-- Link bank transactions to loans by payee name (aliases), and for loans that
-- have no lender emails record each linked repayment as a loan event.
create or replace function public.link_loan_transactions(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;

  update public.transactions t
     set loan_id = l.id,
         loan_role = case when t.direction = 'credit' then 'borrow' else 'repay' end
    from public.loans l
   where t.user_id = p_user and l.user_id = p_user and not l.closed
     and t.loan_id is null and t.loan_role is null and not t.edited
     and coalesce(t.merchant_key, '') <> ''
     and exists (select 1 from unnest(l.aliases) a
                  where t.merchant_key = lower(a) or t.merchant_key like lower(a) || ' %');
  get diagnostics n = row_count;

  insert into public.loan_events (user_id, loan_id, kind, amount, event_at, txn_id, note)
  select t.user_id, t.loan_id, 'repay', t.amount, t.txn_at, t.id, 'Bank payment'
    from public.transactions t
    join public.loans l on l.id = t.loan_id
   where t.user_id = p_user and t.loan_role = 'repay'
     and not exists (select 1 from public.loan_events e where e.loan_id = l.id and e.email_id is not null)
  on conflict (txn_id) do nothing;
  return n;
end $$;
revoke execute on function public.link_loan_transactions(uuid) from anon, public;
grant execute on function public.link_loan_transactions(uuid) to authenticated, service_role;

-- Money moved between two of the user's own accounts shows up as a debit on one
-- and a credit of the same amount on the other within minutes. Mark both as a move
-- (not spending, not income). Each row is paired at most once, closest in time first.
create or replace function public.link_self_transfers(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; r record;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  for r in
    select d.id did, c.id cid
      from public.transactions d
      join public.transactions c
        on c.user_id = d.user_id and c.direction = 'credit' and c.amount = d.amount
       and c.account_id is not null and c.account_id <> d.account_id
       and abs(extract(epoch from c.txn_at - d.txn_at)) <= 1800
     where d.user_id = p_user and d.direction = 'debit' and d.account_id is not null
       and not d.excluded and not c.excluded and not d.edited and not c.edited
       and d.loan_role is null and c.loan_role is null
     order by abs(extract(epoch from c.txn_at - d.txn_at))
  loop
    -- skip rows already used by a closer pair in this run
    update public.transactions set excluded = true, needs_review = false
     where id in (r.did, r.cid) and not excluded
       and (select count(*) from public.transactions x where x.id in (r.did, r.cid) and not x.excluded) = 2;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke execute on function public.link_self_transfers(uuid) from anon, public;
grant execute on function public.link_self_transfers(uuid) to authenticated, service_role;

-- Emails kept whole to learn a new sender's format (e.g. Amazon Pay wallet).
alter table public.unparsed_emails drop constraint if exists unparsed_emails_kind_check;
alter table public.unparsed_emails add constraint unparsed_emails_kind_check
  check (kind in ('unreadable', 'lender', 'review'));
