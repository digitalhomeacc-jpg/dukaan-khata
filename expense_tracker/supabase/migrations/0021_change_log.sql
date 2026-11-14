-- Change history: every change to a payment or a rule, with what it was before and after. Changes made
-- together (one tap, one sync) share a batch, and a batch can be undone.
create table if not exists public.change_log (
  id       bigserial primary key,
  user_id  uuid not null,
  batch    bigint not null default txid_current(),
  at       timestamptz not null default now(),
  tbl      text not null,
  op       text not null check (op in ('insert', 'update', 'delete')),
  row_key  jsonb not null,            -- primary key of the row
  before   jsonb,                     -- changed fields before (whole row for a delete)
  after    jsonb,                     -- changed fields after (whole row for an insert)
  context  jsonb,                     -- for display: payee, amount, date
  by_user  boolean not null default false,
  undone   boolean not null default false
);
create index if not exists change_log_user on public.change_log (user_id, id desc);
alter table public.change_log enable row level security;
drop policy if exists "own change log" on public.change_log;
create policy "own change log" on public.change_log for select using (user_id = auth.uid());

create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  pk text[] := case tg_table_name
    when 'transactions' then array['id'] when 'merchant_rules' then array['user_id', 'merchant_key']
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
      'source', r -> 'source') end,
    auth.uid() is not null);
  return null;
end $$;

do $$ declare t text; begin
  foreach t in array array['transactions', 'merchant_rules', 'vpa_rules', 'friend_aliases', 'people', 'payee_names'] loop
    execute format('drop trigger if exists log_change on public.%I', t);
    execute format('create trigger log_change after insert or update or delete on public.%I
                    for each row execute function public.log_change()', t);
  end loop;
end $$;

-- Undo a batch: put back what it changed, newest first. A field changed again since is left alone.
create or replace function public.undo_change(p_batch bigint)
returns integer language plpgsql security definer set search_path = public as $$
declare e record; k text; cols text; sets text; cond text; n integer := 0; c integer; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  for e in select * from public.change_log where user_id = me and batch = p_batch and not undone order by id desc loop
    cond := (select string_agg(format('%I = %L', key, value #>> '{}'), ' and ') from jsonb_each(e.row_key));
    if e.op = 'insert' then
      execute format('delete from public.%I where %s and user_id = %L', e.tbl, cond, me);
    elsif e.op = 'delete' then
      select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
       where table_schema = 'public' and table_name = e.tbl and is_generated = 'NEVER';
      execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, %L) on conflict do nothing',
        e.tbl, cols, cols, e.tbl, e.before);
    else
      sets := null;
      for k in select jsonb_object_keys(e.before) loop
        sets := coalesce(sets || ', ', '') || format(
          '%1$I = case when to_jsonb(t.%1$I) is not distinct from %2$L::jsonb then (jsonb_populate_record(null::public.%3$I, %4$L)).%1$I else t.%1$I end',
          k, e.after -> k, e.tbl, e.before);
      end loop;
      if sets is not null then
        execute format('update public.%I t set %s where %s and user_id = %L', e.tbl, sets, cond, me);
      end if;
    end if;
    get diagnostics c = row_count; n := n + c;
  end loop;
  update public.change_log set undone = true where user_id = me and batch = p_batch;
  return n;
end $$;
grant execute on function public.undo_change(bigint) to authenticated;
