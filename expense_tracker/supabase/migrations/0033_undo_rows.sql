-- Undo single changes (one payment from its own history), not only whole actions.
create or replace function public.undo_change_rows(p_ids bigint[])
returns integer language plpgsql security definer set search_path = public as $$
declare e record; k text; cols text; sets text; cond text; mine text; n integer := 0; c integer; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  for e in select * from public.change_log where user_id = me and id = any(p_ids) and not undone order by id desc loop
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
  update public.change_log set undone = true where user_id = me and id = any(p_ids);
  return n;
end $$;

create or replace function public.undo_change(p_batch bigint)
returns integer language sql security definer set search_path = public as $$
  select public.undo_change_rows(array(select id from public.change_log where user_id = auth.uid() and batch = p_batch));
$$;

create index if not exists change_log_mine on public.change_log (user_id, id desc) where by_user or actor is not null;
