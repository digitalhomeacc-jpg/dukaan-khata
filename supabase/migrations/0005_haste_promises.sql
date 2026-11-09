-- हस्ते (who brought / took it) on every entry, and payment promises (वसुली वायदे).
alter table vouchers add column if not exists haste text;
alter table vouchers add column if not exists status text;   -- promises: open | done | missed

-- Anyone in the shop may record a promise's outcome (kept / put off),
-- even after its date has passed.
drop policy if exists v_upd on vouchers;
create policy v_upd on vouchers for update using (
  is_owner(business_id)
  or (is_member(business_id) and vdate >= today_ist() and deleted = 0)
  or (is_member(business_id) and vtype = 'promise'))
  with check (
  is_owner(business_id)
  or (vdate >= today_ist() and deleted = 0)
  or (vtype = 'promise'));

-- Staff may note promises; old (pre-books) entries and GST bills stay owner-only.
drop policy if exists v_ins on vouchers;
create policy v_ins on vouchers for insert with check (
  is_owner(business_id)
  or (is_member(business_id) and vdate >= today_ist() and gst = 0 and vtype <> 'history'));

-- Old entries are reference only: they never had to move balances.
update voucher_lines set deleted = 1
where deleted = 0 and voucher_id in (select id from vouchers where vtype = 'history');
