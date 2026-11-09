-- Book settings, genuine GST bills, party GSTIN, bank statement matching.
alter table businesses add column if not exists gstin text;
alter table businesses add column if not exists books_start text;         -- YYYY-MM-DD
alter table businesses add column if not exists fy_start_month integer default 4;
alter table ledgers add column if not exists gstin text;
alter table vouchers add column if not exists gst_rate integer not null default 0; -- percent x 100
alter table vouchers add column if not exists gst bigint not null default 0;

create table if not exists bank_lines (
  id text primary key,
  business_id text not null references businesses(id) on delete cascade,
  bank_ledger_id text not null,
  import_id text,
  tdate text not null,
  description text,
  ref text,
  debit bigint not null default 0,
  credit bigint not null default 0,
  balance bigint,
  fingerprint text,
  voucher_id text,
  status text not null default 'open',
  created_at text
);
create index if not exists bank_lines_business on bank_lines(business_id);
alter table bank_lines enable row level security;
-- bank statements: owner only
create policy bl_owner on bank_lines for all using (is_owner(business_id)) with check (is_owner(business_id));

-- GST bills and old (pre-books) entries: owner only
drop policy if exists v_ins on vouchers;
create policy v_ins on vouchers for insert with check (
  is_owner(business_id) or (is_member(business_id) and vdate >= today_ist() and gst = 0 and vtype <> 'history'));

alter publication powersync add table bank_lines;
