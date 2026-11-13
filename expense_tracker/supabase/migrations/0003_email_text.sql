-- Keep the original bank email with each transaction, so it can be shown in the
-- app and read again when the email reader improves. `edited` marks rows the
-- user changed by hand; re-reading an email never overwrites those.

alter table public.transactions
  add column if not exists email_body        text,
  add column if not exists email_from        text,
  add column if not exists email_received_at timestamptz,
  add column if not exists edited            boolean not null default false;

-- Lender emails (Slice, KreditBee, Fibe…) kept whole while loan tracking is built.
alter table public.unparsed_emails
  add column if not exists kind text not null default 'unreadable'
    check (kind in ('unreadable', 'lender'));
