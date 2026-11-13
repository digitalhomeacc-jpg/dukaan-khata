-- The day an account's opening balance is for. Transactions before it stay as history
-- but do not change the account's balance.
alter table public.accounts add column if not exists opening_date date;
