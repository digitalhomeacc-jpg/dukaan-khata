-- Money between your own accounts: a payment out of one and the same amount into another. Bank alerts carry
-- the real time, so 30 minutes apart is enough. Statement lines have no time (the app puts them at 6 am), so
-- they pair only when both sides carry the same UPI / IMPS reference number: never two unrelated payments
-- of the same amount on the same day.
create or replace function public.link_self_transfers(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; r record;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  for r in
    select d.id did, c.id cid
      from public.transactions d
      join public.transactions c
        on c.user_id = d.user_id and c.direction = 'credit' and c.amount = d.amount
       and c.account_id is not null and c.account_id <> d.account_id
       and abs(extract(epoch from c.txn_at - d.txn_at)) <= case
             when d.source = 'statement' or c.source = 'statement' then 3 * 86400 else 1800 end
     where d.user_id = p_user and d.direction = 'debit' and d.account_id is not null
       and not d.excluded and not c.excluded and not d.edited and not c.edited
       and d.loan_role is null and c.loan_role is null
       and ((d.source <> 'statement' and c.source <> 'statement')
         or exists (select 1 from regexp_matches(coalesce(d.details, '') || ' ' || coalesce(d.email_body, ''), '(?<![0-9])([0-9]{12})(?![0-9])', 'g') x
                     where position(x[1] in coalesce(c.details, '') || ' ' || coalesce(c.email_body, '')) > 0))
     order by abs(extract(epoch from c.txn_at - d.txn_at))
  loop
    -- skip rows already used by a closer pair in this run
    -- (no counter_account_id: both sides are real entries, each moves its own account once)
    update public.transactions set excluded = true, needs_review = false
     where id in (r.did, r.cid) and not excluded
       and (select count(*) from public.transactions x where x.id in (r.did, r.cid) and not x.excluded) = 2;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;
