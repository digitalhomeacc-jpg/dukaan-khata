-- Loans have a start and an end. A payment goes to the lender's loan running on its date, closed ones included,
-- so an old, repaid loan's money never lands on today's loan.
alter table public.loans add column if not exists started_on date, add column if not exists ended_on date;

create or replace function public.link_loan_transactions(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;

  update public.transactions t
     set loan_id = x.lid,
         loan_role = case when t.direction = 'credit' then 'borrow' else 'repay' end
    from (
      select c.id tid, (
        select l.id from public.loans l
         where l.user_id = p_user
           and (l.started_on is null or (c.txn_at at time zone 'Asia/Kolkata')::date >= l.started_on - 3)
           and (l.ended_on is null or (c.txn_at at time zone 'Asia/Kolkata')::date <= l.ended_on + 3)
           and (not l.closed or l.ended_on is not null)
           and exists (select 1 from unnest(l.aliases) a
                        where c.merchant_key = lower(a) or c.merchant_key like lower(a) || ' %'
                           -- payment codes like 'fibe.cf.fibe7@cashfree…': in the payee or the email text
                           or (a ~ '[.@]' and (c.merchant_key like lower(a) || '%' or c.email_body ilike '%' || a || '%')))
         -- the loan whose dates hold this payment before one with no dates
         order by (l.started_on is not null) desc, l.started_on desc nulls last
         limit 1) lid
        from public.transactions c
       where c.user_id = p_user and c.loan_id is null and c.loan_role is null and not c.edited
         and (coalesce(c.merchant_key, '') <> '' or c.email_body is not null)
    ) x
   where t.id = x.tid and x.lid is not null;
  get diagnostics n = row_count;

  insert into public.loan_events (user_id, loan_id, kind, amount, event_at, txn_id, note)
  select t.user_id, t.loan_id, 'repay', t.amount, t.txn_at, t.id, 'Bank payment'
    from public.transactions t
    join public.loans l on l.id = t.loan_id
   where t.user_id = p_user and t.loan_role = 'repay'
     and not exists (select 1 from public.loan_events e where e.loan_id = l.id and e.email_id is not null)
  on conflict (txn_id) do nothing;
  return n;
end $$;
