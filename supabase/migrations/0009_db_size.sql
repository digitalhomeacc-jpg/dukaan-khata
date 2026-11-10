-- Storage meter: lets the app show how much of the free 500 MB database is used.
-- Read-only: it only reports the database size.
create or replace function db_size() returns bigint
language sql stable security definer set search_path = public as $$
  select pg_database_size(current_database());
$$;
revoke all on function db_size() from public;
grant execute on function db_size() to authenticated;
