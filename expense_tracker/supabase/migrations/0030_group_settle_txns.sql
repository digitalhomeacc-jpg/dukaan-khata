-- A group settle-up can add several entries to your Friends ledger (money routed through one friend for
-- another); remember all of them so removing the settle-up removes exactly those.
alter table public.group_expenses add column if not exists txn_ids uuid[] not null default '{}';
