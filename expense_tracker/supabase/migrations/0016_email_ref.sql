-- A bank email that matches a payment already imported from a statement is attached to it (not added twice):
-- its Gmail id is kept here so sending the email again is recognised.
alter table public.transactions add column if not exists email_ref text;
create index if not exists transactions_email_ref on public.transactions (user_id, email_ref) where email_ref is not null;
