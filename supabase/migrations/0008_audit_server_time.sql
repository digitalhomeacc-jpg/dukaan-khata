-- बदल इतिहास: the server stamps when each change reached it, so a phone with
-- a wrong clock can't give a wrong time (and no phone can set this value).
-- The log stays append-only: members may add rows, nobody may edit or delete them.
alter table audit_log add column if not exists received_at timestamptz;

create or replace function audit_stamp_received() returns trigger
language plpgsql as $$
begin
  new.received_at := now();
  return new;
end $$;

drop trigger if exists audit_received on audit_log;
create trigger audit_received before insert or update on audit_log
  for each row execute function audit_stamp_received();
