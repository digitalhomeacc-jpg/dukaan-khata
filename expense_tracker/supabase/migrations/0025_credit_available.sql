-- A credit line's spending power left ("purchase power"), as the lender showed it, and when.
alter table public.loans add column if not exists available_credit numeric(12,2);
alter table public.loans add column if not exists available_at timestamptz;
