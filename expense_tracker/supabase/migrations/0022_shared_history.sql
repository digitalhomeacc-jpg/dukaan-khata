-- Entries between connected friends show in both people's change history, with who changed them.
alter table public.change_log add column if not exists actor uuid;
alter table public.change_log alter column actor set default auth.uid();

create or replace function public.log_shared_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  b jsonb := '{}'; a jsonb := '{}'; k text; who uuid;
begin
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if k <> 'created_at' and (o -> k) is distinct from (n -> k) then
        b := b || jsonb_build_object(k, o -> k); a := a || jsonb_build_object(k, n -> k);
      end if;
    end loop;
    if a = '{}' then return null; end if;
  elsif tg_op = 'INSERT' then a := n;
  else b := o;
  end if;
  foreach who in array array[(r ->> 'creditor')::uuid, (r ->> 'debtor')::uuid] loop
    insert into public.change_log (user_id, tbl, op, row_key, before, after, context, by_user, actor)
    values (who, 'shared_entries', lower(tg_op), jsonb_build_object('id', r -> 'id'), nullif(b, '{}'), nullif(a, '{}'),
      jsonb_build_object('amount', r -> 'amount', 'kind', r -> 'kind', 'description', r -> 'description',
        'txn_at', r -> 'at', 'creditor', r -> 'creditor', 'debtor', r -> 'debtor', 'link_id', r -> 'link_id'),
      coalesce(auth.uid() = who, false), auth.uid());
  end loop;
  return null;
end $$;
drop trigger if exists log_change on public.shared_entries;
create trigger log_change after insert or update or delete on public.shared_entries
  for each row execute function public.log_shared_change();

-- Undo also handles entries between friends: an added entry is removed for both (as "removed by you"),
-- a removal is brought back, other changes are put back.
create or replace function public.undo_change(p_batch bigint)
returns integer language plpgsql security definer set search_path = public as $$
declare e record; k text; cols text; sets text; cond text; mine text; n integer := 0; c integer; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  for e in select * from public.change_log where user_id = me and batch = p_batch and not undone order by id desc loop
    cond := (select string_agg(format('%I = %L', key, value #>> '{}'), ' and ') from jsonb_each(e.row_key));
    mine := case when e.tbl = 'shared_entries' then format('%L in (creditor, debtor)', me) else format('user_id = %L', me) end;
    if e.tbl = 'shared_entries' and e.op = 'insert' then
      update public.shared_entries set deleted_at = now(), deleted_by = me
       where id = (e.row_key ->> 'id')::uuid and me in (creditor, debtor) and deleted_at is null;
    elsif e.op = 'insert' then
      execute format('delete from public.%I where %s and %s', e.tbl, cond, mine);
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
        execute format('update public.%I t set %s where %s and %s', e.tbl, sets, cond, mine);
      end if;
    end if;
    get diagnostics c = row_count; n := n + c;
  end loop;
  update public.change_log set undone = true where user_id = me and batch = p_batch;
  return n;
end $$;
grant execute on function public.undo_change(bigint) to authenticated;
