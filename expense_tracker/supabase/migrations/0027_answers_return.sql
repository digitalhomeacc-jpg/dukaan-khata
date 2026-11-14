-- The app's answer buttons get a result back (true = done), so a failure is never silent.
drop function if exists public.answer_match(uuid, boolean);
drop function if exists public.request_remove_shared(uuid);
drop function if exists public.answer_shared(uuid, boolean);
create or replace function public.answer_match(p_question uuid, p_yes boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare q record; se record; t record; fname text; cat uuid;
begin
  select * into q from public.match_questions where id = p_question and user_id = auth.uid();
  if q is null then return false; end if;
  if not p_yes then delete from public.match_questions where id = q.id; return true; end if;
  select * into se from public.shared_entries where id = q.entry_id;
  select * into t from public.transactions where id = q.txn_id;
  select case when l.a = auth.uid() then l.a_name_for_b else l.b_name_for_a end into fname
    from public.friend_links l where l.id = se.link_id;
  if se.creditor = auth.uid() then update public.shared_entries set creditor_txn = t.id where id = se.id;
  else update public.shared_entries set debtor_txn = t.id where id = se.id; end if;
  select id into cat from public.categories where user_id = auth.uid() and kind = 'loan' order by name = 'Friends' desc limit 1;
  update public.transactions set category_id = cat, needs_review = false where id = t.id;
  if coalesce(t.merchant_key, '') <> '' and lower(t.merchant_key) <> lower(fname) then
    insert into public.friend_aliases (user_id, alias_key, friend_name) values (auth.uid(), t.merchant_key, fname)
    on conflict (user_id, alias_key) do update set friend_name = excluded.friend_name;
    insert into public.merchant_rules (user_id, merchant_key, category_id) values (auth.uid(), t.merchant_key, cat)
    on conflict (user_id, merchant_key) do update set category_id = excluded.category_id;
  end if;
  delete from public.match_questions where entry_id = se.id;
  return true;
end $$;
grant execute on function public.answer_match(uuid, boolean) to authenticated;

create or replace function public.request_remove_shared(p_entry uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare e record; me uuid := auth.uid();
begin
  select * into e from public.shared_entries where id = p_entry and me in (creditor, debtor) and deleted_at is null;
  if e is null then raise exception 'not found'; end if;
  if e.confirmed_amount is null then
    -- Never agreed: whoever added it can take it back; the other can turn it down.
    update public.shared_entries set deleted_at = now(), deleted_by = me,
      rejected_by = case when e.changed_by = me then null else me end where id = p_entry;
  else
    update public.shared_entries set remove_requested_by = me, changed_by = me where id = p_entry;
  end if;
  return true;
end $$;
grant execute on function public.request_remove_shared(uuid) to authenticated;

create or replace function public.answer_shared(p_entry uuid, p_ok boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare e record; me uuid := auth.uid();
begin
  select * into e from public.shared_entries where id = p_entry and me in (creditor, debtor) and deleted_at is null;
  if e is null then raise exception 'not found'; end if;
  if e.changed_by = me then raise exception 'waiting for the other person'; end if;
  if e.remove_requested_by is not null then
    if p_ok then
      update public.shared_entries set deleted_at = now(), deleted_by = e.remove_requested_by, remove_requested_by = null
       where id = p_entry;
    else
      update public.shared_entries set remove_requested_by = null, changed_by = null where id = p_entry;
    end if;
  elsif e.confirmed_at is null then
    if p_ok then
      update public.shared_entries set confirmed_amount = amount, confirmed_at = now(), changed_by = null where id = p_entry;
    elsif e.confirmed_amount is null then
      update public.shared_entries set deleted_at = now(), deleted_by = me, rejected_by = me where id = p_entry;
    else
      -- A changed amount turned down: back to what was agreed.
      update public.shared_entries set amount = confirmed_amount, confirmed_at = now(), changed_by = null where id = p_entry;
    end if;
  end if;
  return true;
end $$;
grant execute on function public.answer_shared(uuid, boolean) to authenticated;
