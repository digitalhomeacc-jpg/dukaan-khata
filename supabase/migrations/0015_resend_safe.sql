-- 0015: a change sent twice is never refused. When a phone loses the server's
-- "saved" reply it sends the same rows again; a row that is already exactly as
-- sent is now simply skipped (before, staff phones got stuck on bill lines).
-- A real change still goes through every permission rule as before.
-- Accounts, items and history rows are added once and never replaced (0013/0014).
create or replace function apply_crud(ops jsonb) returns void
language plpgsql security invoker set search_path = public as $$
declare
  op jsonb;
  t text;
  rid text;
  data jsonb;
  cols text;
  xs text;
  ps text;
  found boolean;
  n bigint;
  same boolean;
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
    else -- PUT: add the row; if it is already there see below
      select string_agg(format('%I', k), ', '), string_agg(format('x.%I', k), ', '), string_agg(format('p.%I', k), ', ')
        into cols, xs, ps from jsonb_object_keys(data) k;
      execute format('select exists (select 1 from %I where id = $1)', t) into found using rid;
      if not found then
        execute format('insert into %I (%s) select %s from jsonb_populate_record(null::%I, $1)', t, cols, cols, t) using data;
      elsif t not in ('audit_log', 'ledgers', 'items') then -- these are added once, never replaced
        execute format('select exists (select 1 from %I x, jsonb_populate_record(null::%I, $1) p '
                       'where x.id = $2 and row(%s) is not distinct from row(%s))', t, t, xs, ps)
          into same using data, rid;
        if not same then -- a real change: replace it (row rules apply)
          execute format('update %I set (%s) = (select %s from jsonb_populate_record(null::%I, $1)) where id = $2',
                         t, cols, cols, t) using data, rid;
          get diagnostics n = row_count;
          if n = 0 then
            raise exception 'not allowed to change % %', t, rid using errcode = '42501';
          end if;
        end if;
      end if;
    end if;
  end loop;
end $$;

revoke execute on function apply_crud(jsonb) from public, anon;
grant execute on function apply_crud(jsonb) to authenticated;
