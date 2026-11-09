-- Dukaan Khata – Supabase (Postgres) schema.
-- Mirrors lib/core/schema.dart. Money = bigint paise, qty = numeric.
-- Run in Supabase SQL editor (or `supabase db push`).

create table if not exists businesses (
  id text primary key,
  name text not null,
  phone text,
  address text,
  created_at text
);

create table if not exists members (
  id text primary key,
  business_id text not null references businesses(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  email text,
  name text,
  role text not null default 'staff' check (role in ('owner', 'staff'))
);
create index if not exists members_user on members(user_id);
create index if not exists members_business on members(business_id);
create unique index if not exists members_business_email on members(business_id, lower(email));

create table if not exists ledgers (
  id text primary key,
  business_id text not null references businesses(id) on delete cascade,
  name text not null,
  name_en text,
  grp text not null,
  phone text,
  address text,
  page_no text,
  short_code text,
  opening_balance bigint not null default 0,
  credit_limit bigint not null default 0,
  system integer not null default 0,
  archived integer not null default 0,
  created_at text
);
create index if not exists ledgers_business_grp on ledgers(business_id, grp);

create table if not exists items (
  id text primary key,
  business_id text not null references businesses(id) on delete cascade,
  name text not null,
  name_en text,
  category text,
  unit text,
  short_code text,
  sale_rate bigint default 0,
  purchase_rate bigint default 0,
  opening_qty double precision default 0,
  opening_rate bigint default 0,
  low_stock double precision default 0,
  sort_order integer default 0,
  archived integer not null default 0,
  created_at text
);
create index if not exists items_business on items(business_id);

create table if not exists vouchers (
  id text primary key,
  business_id text not null references businesses(id) on delete cascade,
  vtype text not null,
  vno integer,
  vdate text not null,              -- YYYY-MM-DD
  party_id text,
  pay_ledger_id text,
  amount bigint not null default 0,
  paid bigint not null default 0,
  narration text,
  ref_no text,
  gst_bill_needed integer not null default 0,
  created_by text,
  created_at text,
  updated_at text,
  deleted integer not null default 0,
  version integer not null default 1
);
create index if not exists vouchers_business_date on vouchers(business_id, vdate);

create table if not exists voucher_lines (
  id text primary key,
  business_id text not null references businesses(id) on delete cascade,
  voucher_id text not null,
  ledger_id text not null,
  debit bigint not null default 0,
  credit bigint not null default 0,
  vdate text not null,
  deleted integer not null default 0
);
create index if not exists vlines_voucher on voucher_lines(voucher_id);
create index if not exists vlines_business on voucher_lines(business_id);

create table if not exists inventory_lines (
  id text primary key,
  business_id text not null references businesses(id) on delete cascade,
  voucher_id text not null,
  item_id text not null,
  qty double precision not null,
  rate bigint not null default 0,
  amount bigint not null default 0,
  direction integer not null,
  vdate text not null,
  deleted integer not null default 0
);
create index if not exists ilines_voucher on inventory_lines(voucher_id);
create index if not exists ilines_business on inventory_lines(business_id);

create table if not exists audit_log (
  id text primary key,
  business_id text not null references businesses(id) on delete cascade,
  voucher_id text,
  action text not null,
  user_id text,
  user_name text,
  at text,
  snapshot text
);
create index if not exists audit_business on audit_log(business_id);

-- ---------------------------------------------------------------------------
-- Helper functions (security definer so RLS policies can call them cheaply)
-- ---------------------------------------------------------------------------
create or replace function is_member(bid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where business_id = bid and user_id = auth.uid());
$$;

create or replace function is_owner(bid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where business_id = bid and user_id = auth.uid() and role = 'owner');
$$;

-- India time "today", used to stop staff changing old entries.
create or replace function today_ist() returns text
language sql stable as $$
  select to_char((now() at time zone 'Asia/Kolkata')::date, 'YYYY-MM-DD');
$$;

-- Called by a new owner after sign-up: creates the shop + owner membership.
create or replace function create_business(p_name text, p_owner_name text) returns text
language plpgsql security definer set search_path = public as $$
declare bid text := gen_random_uuid()::text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into businesses (id, name, created_at) values (bid, p_name, now()::text);
  insert into members (id, business_id, user_id, email, name, role)
  values (gen_random_uuid()::text, bid, auth.uid(), (select email from auth.users where id = auth.uid()), p_owner_name, 'owner');
  return bid;
end $$;

-- Called on every login: links invitations (by email) to this user.
create or replace function claim_membership() returns void
language sql security definer set search_path = public as $$
  update members set user_id = auth.uid()
  where user_id is null and lower(email) = lower((select email from auth.users where id = auth.uid()));
$$;

grant execute on function create_business(text, text) to authenticated;
grant execute on function claim_membership() to authenticated;

-- ---------------------------------------------------------------------------
-- Row level security
--   * everyone only sees their own shop
--   * staff: can add entries; can change only today's entries; cannot delete
--   * owner: everything
-- ---------------------------------------------------------------------------
alter table businesses enable row level security;
alter table members enable row level security;
alter table ledgers enable row level security;
alter table items enable row level security;
alter table vouchers enable row level security;
alter table voucher_lines enable row level security;
alter table inventory_lines enable row level security;
alter table audit_log enable row level security;

create policy biz_read on businesses for select using (is_member(id));
create policy biz_owner on businesses for update using (is_owner(id));

create policy mem_read on members for select using (is_member(business_id) or user_id = auth.uid());
create policy mem_owner_ins on members for insert with check (is_owner(business_id));
create policy mem_owner_upd on members for update using (is_owner(business_id));
create policy mem_owner_del on members for delete using (is_owner(business_id) and role <> 'owner');

-- masters: staff may add customers; only owner edits system ledgers / opening balances
create policy led_read on ledgers for select using (is_member(business_id));
create policy led_ins on ledgers for insert with check (is_member(business_id) and (system = 0 or is_owner(business_id)));
create policy led_upd on ledgers for update using (is_owner(business_id) or (is_member(business_id) and system = 0));
create policy led_del on ledgers for delete using (is_owner(business_id));

create policy item_read on items for select using (is_member(business_id));
create policy item_write on items for insert with check (is_owner(business_id));
create policy item_upd on items for update using (is_owner(business_id));
create policy item_del on items for delete using (is_owner(business_id));

-- vouchers and their lines
create policy v_read on vouchers for select using (is_member(business_id));
create policy v_ins on vouchers for insert with check (
  is_owner(business_id) or (is_member(business_id) and vdate >= today_ist()));
create policy v_upd on vouchers for update using (
  is_owner(business_id) or (is_member(business_id) and vdate >= today_ist() and deleted = 0))
  with check (is_owner(business_id) or (vdate >= today_ist() and deleted = 0));
create policy v_del on vouchers for delete using (is_owner(business_id));

create policy vl_read on voucher_lines for select using (is_member(business_id));
create policy vl_ins on voucher_lines for insert with check (
  is_owner(business_id) or (is_member(business_id) and vdate >= today_ist()));
create policy vl_upd on voucher_lines for update using (is_owner(business_id));
-- editing an entry replaces its lines (delete + insert)
create policy vl_del on voucher_lines for delete using (
  is_owner(business_id) or (is_member(business_id) and vdate >= today_ist()));

create policy il_read on inventory_lines for select using (is_member(business_id));
create policy il_ins on inventory_lines for insert with check (
  is_owner(business_id) or (is_member(business_id) and vdate >= today_ist()));
create policy il_upd on inventory_lines for update using (is_owner(business_id));
create policy il_del on inventory_lines for delete using (
  is_owner(business_id) or (is_member(business_id) and vdate >= today_ist()));

-- audit log is append-only
create policy a_read on audit_log for select using (is_member(business_id));
create policy a_ins on audit_log for insert with check (is_member(business_id));

-- PowerSync replication
create publication powersync for table
  businesses, members, ledgers, items, vouchers, voucher_lines, inventory_lines, audit_log;
