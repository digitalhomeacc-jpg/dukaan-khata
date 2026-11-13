-- 0014: an account or item is only ever CREATED by a full upload (PUT);
-- edits are always partial (PATCH). So a full upload of an account or item
-- that already exists is now skipped instead of replacing it. This stops a
-- phone that had not finished downloading from wiping real opening balances
-- with a fresh blank copy. Includes 0013 (history rows added once).
create or replace function apply_crud(ops jsonb) returns void
language plpgsql security invoker set search_path = public as $$
declare
  op jsonb;
  t text;
  rid text;
  data jsonb;
  cols text;
begin
  for op in select * from jsonb_array_elements(ops) loop
    t := op->>'table';
    rid := op->>'id';
    data := coalesce(op->'data', '{}'::jsonb) || jsonb_build_object('id', rid);
    if t not in ('businesses','members','ledgers','items','vouchers','voucher_lines',
                 'inventory_lines','audit_log','bank_lines') then
      raise exception 'table % not allowed', t using errcode = '42501';
    end if;
    if op->>'op' = 'DELETE' then
      execute format('delete from %I where id = $1', t) using rid;
    elsif op->>'op' = 'PATCH' then
      select string_agg(format('%I', k), ', ') into cols from jsonb_object_keys(op->'data') k where k <> 'id';
      if cols is not null then
        execute format('update %I set (%s) = (select %s from jsonb_populate_record(null::%I, $1)) where id = $2',
                       t, cols, cols, t) using data, rid;
      end if;
    elsif t in ('audit_log','ledgers','items') then -- add once, never replace
      select string_agg(format('%I', k), ', ') into cols from jsonb_object_keys(data) k;
      execute format('insert into %I (%s) select %s from jsonb_populate_record(null::%I, $1) '
                     'on conflict (id) do nothing', t, cols, cols, t) using data;
    else -- PUT = insert or replace
      select string_agg(format('%I', k), ', ') into cols from jsonb_object_keys(data) k;
      execute format('insert into %I (%s) select %s from jsonb_populate_record(null::%I, $1) '
                     'on conflict (id) do update set (%s) = (select %s from jsonb_populate_record(null::%I, $1))',
                     t, cols, cols, t, cols, cols, t) using data;
    end if;
  end loop;
end $$;

revoke execute on function apply_crud(jsonb) from public, anon;
grant execute on function apply_crud(jsonb) to authenticated;
