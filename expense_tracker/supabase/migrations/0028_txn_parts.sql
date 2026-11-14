-- One payment split across your own categories (₹500 = ₹300 Groceries + ₹200 Cigarettes). The payment's
-- amount never changes; what is not in a part stays in the payment's own category.
create table if not exists public.txn_parts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users on delete cascade,
  txn_id      uuid not null references public.transactions on delete cascade,
  category_id uuid references public.categories on delete set null,
  amount      numeric(14,2) not null check (amount > 0),
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists txn_parts_txn on public.txn_parts (txn_id);
alter table public.txn_parts enable row level security;
drop policy if exists "own parts" on public.txn_parts;
create policy "own parts" on public.txn_parts for all using (user_id = auth.uid())
  with check (user_id = auth.uid() and exists (select 1 from public.transactions t where t.id = txn_id and t.user_id = auth.uid()));
do $$ begin
  alter publication supabase_realtime add table public.txn_parts;
exception when duplicate_object then null; end $$;

-- Parts can never add up to more than the payment.
create or replace function public.check_parts()
returns trigger language plpgsql security definer set search_path = public as $$
declare total numeric; amt numeric;
begin
  select amount into amt from public.transactions where id = new.txn_id;
  select coalesce(sum(amount), 0) into total from public.txn_parts where txn_id = new.txn_id and id <> new.id;
  if total + new.amount > amt + 0.001 then
    raise exception 'parts (₹%) are more than the payment (₹%)', total + new.amount, amt;
  end if;
  return new;
end $$;
drop trigger if exists check_parts on public.txn_parts;
create trigger check_parts before insert or update on public.txn_parts for each row execute function public.check_parts();

-- In the change history (with undo), like payments and rules.
create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  pk text[] := case tg_table_name
    when 'transactions' then array['id'] when 'txn_parts' then array['id'] when 'merchant_rules' then array['user_id', 'merchant_key']
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
drop trigger if exists log_change on public.txn_parts;
create trigger log_change after insert or update or delete on public.txn_parts for each row execute function public.log_change();
