-- Start a friend's balance fresh: from ledger_from on, with an opening balance (positive: you owe them).
-- Earlier entries stay as history but no longer count.
alter table public.people add column if not exists ledger_from date;
alter table public.people add column if not exists opening numeric(12,2) not null default 0;
