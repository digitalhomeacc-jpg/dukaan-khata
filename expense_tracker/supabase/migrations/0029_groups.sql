-- Groups (a trip, the flat, office lunch): shared expenses among several people, Splitwise style.
-- Your own part also lives in your normal records (your payment with friends' shares, or "friend paid,
-- you owe"), linked by txn_id, so balances and spending are never counted twice.
create table if not exists public.groups (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  name       text not null check (length(btrim(name)) between 1 and 60),
  emoji      text,
  members    text[] not null default '{}',      -- friends' names; you are always in it
  archived   boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.group_expenses (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users on delete cascade,
  group_id    uuid not null references public.groups on delete cascade,
  kind        text not null default 'expense' check (kind in ('expense', 'settle')),
  description text,
  amount      numeric(14,2) not null check (amount > 0),
  paid_by     text not null,                    -- 'me' or a member's name
  paid_to     text,                             -- for a settle: who received it
  shares      jsonb not null default '{}',      -- {"me": 300, "Ravi": 300, …}; adds up to amount
  at          timestamptz not null default now(),
  category_id uuid references public.categories on delete set null,
  txn_id      uuid references public.transactions on delete set null,
  txn_created boolean not null default false,   -- the linked payment was made for this (removed with it)
  created_at  timestamptz not null default now()
);
create index if not exists group_expenses_group on public.group_expenses (group_id, at desc);
alter table public.groups enable row level security;
alter table public.group_expenses enable row level security;
drop policy if exists "own groups" on public.groups;
create policy "own groups" on public.groups for all using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own group expenses" on public.group_expenses;
create policy "own group expenses" on public.group_expenses for all using (user_id = auth.uid())
  with check (user_id = auth.uid() and exists (select 1 from public.groups g where g.id = group_id and g.user_id = auth.uid()));
do $$ begin
  alter publication supabase_realtime add table public.groups, public.group_expenses;
exception when duplicate_object then null; end $$;

-- An expense's shares must add up to its amount.
create or replace function public.check_group_shares()
returns trigger language plpgsql as $$
declare total numeric;
begin
  if new.kind = 'expense' then
    select coalesce(sum(value::numeric), 0) into total from jsonb_each_text(new.shares);
    if abs(total - new.amount) > 0.05 then
      raise exception 'shares (₹%) do not add up to the amount (₹%)', total, new.amount;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists check_group_shares on public.group_expenses;
create trigger check_group_shares before insert or update on public.group_expenses
  for each row execute function public.check_group_shares();

-- In the change history, with undo.
do $$ declare t text; begin
  foreach t in array array['groups', 'group_expenses'] loop
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
    when 'transactions' then array['id'] when 'txn_parts' then array['id'] when 'groups' then array['id'] when 'group_expenses' then array['id'] when 'merchant_rules' then array['user_id', 'merchant_key']
    when 'vpa_rules' then array['user_id', 'vpa'] when 'friend_aliases' then array['user_id', 'alias_key']
    when 'people' then array['user_id', 'name_key'] when 'payee_names' then array['user_id', 'match_key'] end;
  watched text[] := array['category_id', 'merchant', 'note', 'amount', 'direction', 'txn_at', 'account_id',
    'counter_account_id', 'excluded', 'paid_by', 'loan_id', 'loan_role', 'bank_name', 'payee_vpa'];
  b jsonb := '{}'; a jsonb := '{}'; k text; key jsonb := '{}';
begin
  foreach k in array pk loop key := key || jsonb_build_object(k, r -> k); end loop;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if (tg_table_name <> 'transactions' or k = any(watched)) and (o -> k) is distinct from (n -> k) then
        b := b || jsonb_build_object(k, o -> k); a := a || jsonb_build_object(k, n -> k);
      end if;
    end loop;
    if a = '{}' then return null; end if;
  elsif tg_op = 'INSERT' then a := n;
  else b := o;
  end if;
  insert into public.change_log (user_id, tbl, op, row_key, before, after, context, by_user)
  values ((r ->> 'user_id')::uuid, tg_table_name, lower(tg_op), key, nullif(b, '{}'), nullif(a, '{}'),
    case when tg_table_name = 'transactions' then jsonb_build_object(
      'merchant', r -> 'merchant', 'amount', r -> 'amount', 'direction', r -> 'direction', 'txn_at', r -> 'txn_at',
      'source', r -> 'source')
    when tg_table_name = 'txn_parts' then (select jsonb_build_object('merchant', t.merchant, 'amount', t.amount,
      'txn_at', t.txn_at, 'part', r -> 'amount') from public.transactions t where t.id = (r ->> 'txn_id')::uuid) end,
    coalesce(auth.uid() is not null, false));
  return null;
end $$;
