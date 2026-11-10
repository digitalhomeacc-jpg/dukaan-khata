-- Staff may write old khata entries (जुनी नोंद – reference only, they change no
-- figure) and correct one on the day they typed it in. Deleting stays owner-only.

-- Was this row typed in today (India time)? created_at is UTC ISO text.
create or replace function entered_today_ist(c text) returns boolean
language sql stable as $$
  select c >= to_char((today_ist()::date::timestamp at time zone 'Asia/Kolkata') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS');
$$;

-- An old entry a member may still change (and its item lines).
create or replace function history_editable(vid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vouchers v where v.id = vid and v.vtype = 'history' and v.deleted = 0
                 and entered_today_ist(v.created_at) and is_member(v.business_id));
$$;

drop policy if exists v_ins on vouchers;
create policy v_ins on vouchers for insert with check (
  is_owner(business_id)
  or (is_member(business_id) and vdate >= today_ist() and gst = 0 and vtype <> 'history')
  or (is_member(business_id) and vtype = 'history' and gst = 0));

drop policy if exists v_upd on vouchers;
create policy v_upd on vouchers for update using (
  is_owner(business_id)
  or (is_member(business_id) and vdate >= today_ist() and deleted = 0)
  or (is_member(business_id) and vtype = 'promise')
  or (is_member(business_id) and vtype = 'history' and deleted = 0 and entered_today_ist(created_at)))
  with check (
  is_owner(business_id)
  or (vdate >= today_ist() and deleted = 0)
  or (vtype = 'promise')
  or (vtype = 'history' and deleted = 0 and entered_today_ist(created_at)));

drop policy if exists il_ins on inventory_lines;
create policy il_ins on inventory_lines for insert with check (
  is_owner(business_id)
  or (is_member(business_id) and vdate >= today_ist())
  or (is_member(business_id) and history_editable(voucher_id)));

drop policy if exists il_del on inventory_lines;
create policy il_del on inventory_lines for delete using (
  is_owner(business_id)
  or (is_member(business_id) and vdate >= today_ist())
  or (is_member(business_id) and history_editable(voucher_id)));
