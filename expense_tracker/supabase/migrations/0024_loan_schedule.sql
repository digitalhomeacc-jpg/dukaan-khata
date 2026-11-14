-- A loan's own repayment schedule (e.g. Slice's), when its dues are not one fixed EMI: [{"date","amount"}].
alter table public.loans add column if not exists schedule jsonb not null default '[]';
