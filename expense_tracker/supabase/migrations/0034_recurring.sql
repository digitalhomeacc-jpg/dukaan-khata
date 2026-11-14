-- Repeats: rent, subscriptions, salary, bills. Each due date is settled exactly once (recurring_runs is unique
-- on the repeat and date): matched to the bank payment that came in, added (cash, by itself or by you), or
-- skipped. Two phones open at once can never enter it twice.
create table if not exists public.recurring (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 80),
  amount      numeric(14,2) not null check (amount > 0),
  direction   text not null default 'debit' check (direction in ('debit', 'credit')),
  every       text not null default 'month' check (every in ('week', 'month', 'year')),
  starts_on   date not null,                       -- the first due date; the day repeats from it
  varies      boolean not null default false,      -- bills whose amount changes (electricity): match by name
  auto_add    boolean not null default false,      -- cash: enter it by itself on the day
  category_id uuid references public.categories on delete set null,
  account_id  uuid references public.accounts on delete set null,
  group_id    uuid references public.groups on delete set null,
  note        text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create table if not exists public.recurring_runs (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users on delete cascade,
  recurring_id uuid not null references public.recurring on delete cascade,
  due_on       date not null,
  kind         text not null check (kind in ('matched', 'added', 'skipped')),
  txn_id       uuid references public.transactions on delete set null,
  created_at   timestamptz not null default now(),
  unique (recurring_id, due_on)
);
create index if not exists recurring_runs_txn on public.recurring_runs (txn_id) where txn_id is not null;
alter table public.recurring enable row level security;
alter table public.recurring_runs enable row level security;
drop policy if exists "own recurring" on public.recurring;
create policy "own recurring" on public.recurring for all using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own recurring runs" on public.recurring_runs;
create policy "own recurring runs" on public.recurring_runs for all using (user_id = auth.uid())
  with check (user_id = auth.uid() and exists (select 1 from public.recurring r where r.id = recurring_id and r.user_id = auth.uid()));
do $$ begin
  alter publication supabase_realtime add table public.recurring, public.recurring_runs;
exception when duplicate_object then null; end $$;

-- In the change history (with undo); a run names its payment so it shows in that payment's history.
do $$ declare t text; begin
  foreach t in array array['recurring', 'recurring_runs'] loop
    execute format('drop trigger if exists log_change on public.%I', t);
    execute format('create trigger log_change after insert or update or delete on public.%I
                    for each row execute function public.log_change()', t);
  end loop;
end $$;

create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  pk text[] := case tg_table_name
    when 'merchant_rules' then array['user_id', 'merchant_key']
    when 'vpa_rules' then array['user_id', 'vpa'] when 'friend_aliases' then array['user_id', 'alias_key']
    when 'people' then array['user_id', 'name_key'] when 'payee_names' then array['user_id', 'match_key']
    else array['id'] end;
  watched text[] := array['category_id', 'merchant', 'note', 'details', 'method', 'amount', 'direction', 'txn_at',
    'account_id', 'counter_account_id', 'excluded', 'paid_by', 'loan_id', 'loan_role', 'bank_name', 'payee_vpa'];
  b jsonb := '{}'; a jsonb := '{}'; k text; key jsonb := '{}';
  tx uuid := case when tg_table_name = 'transactions' then (r ->> 'id')::uuid
    when tg_table_name in ('txn_parts', 'txn_shares', 'group_expenses', 'recurring_runs') then (r ->> 'txn_id')::uuid end;
begin
  foreach k in array pk loop key := key || jsonb_build_object(k, r -> k); end loop;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if (tg_table_name <> 'transactions' or k = any(watched)) and k not in ('created_at', 'outstanding_at', 'available_at')
         and (o -> k) is distinct from (n -> k) then
        b := b || jsonb_build_object(k, o -> k); a := a || jsonb_build_object(k, n -> k);
      end if;
    end loop;
    if a = '{}' then return null; end if;
  elsif tg_op = 'INSERT' then a := n;
  else b := o;
  end if;
  insert into public.change_log (user_id, tbl, op, row_key, before, after, context, by_user, txn_id)
  values ((r ->> 'user_id')::uuid, tg_table_name, lower(tg_op), key, nullif(b, '{}'), nullif(a, '{}'),
    case when tg_table_name = 'transactions' then jsonb_build_object(
      'merchant', r -> 'merchant', 'amount', r -> 'amount', 'direction', r -> 'direction', 'txn_at', r -> 'txn_at',
      'source', r -> 'source')
    when tg_table_name in ('txn_parts', 'txn_shares') then (select jsonb_build_object('merchant', t.merchant,
      'amount', t.amount, 'txn_at', t.txn_at, 'part', r -> 'amount', 'person', r -> 'person')
      from public.transactions t where t.id = tx)
    when tg_table_name in ('categories', 'accounts', 'loans', 'recurring') then jsonb_build_object('name', coalesce(r -> 'name', r -> 'lender'))
    when tg_table_name = 'recurring_runs' then (select jsonb_build_object('name', x.name, 'amount', x.amount, 'due_on', r -> 'due_on', 'kind', r -> 'kind')
      from public.recurring x where x.id = (r ->> 'recurring_id')::uuid)
    when tg_table_name = 'budgets' then (select jsonb_build_object('name', coalesce(c.name, 'Total'), 'amount', r -> 'amount')
      from (select 1) x left join public.categories c on c.id = (r ->> 'category_id')::uuid) end,
    coalesce(auth.uid() is not null, false), tx);
  return null;
end $$;

