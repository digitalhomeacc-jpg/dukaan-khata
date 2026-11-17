-- Loans follow your payments, always and at once.
-- Before: a bank payment linked to a loan became a loan event only when the lender had never sent an email
-- (to avoid counting an EMI twice), and only when a bank email or import ran the linking. So a KreditBee EMI
-- paid from the bank was linked but the EMIs left never went down. Now each payment linked to a loan has its
-- event, kept in step when it is linked (by you or a rule), changed, unlinked or deleted. An EMI the lender's
-- own email already recorded (same amount, within 5 days) is not counted twice. Money borrowed counts from the
-- day you added the loan (what came before is in the amounts you entered).

create or replace function public.sync_loan_event(p_txn uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.transactions; l public.loans; k text;
begin
  select * into t from public.transactions where id = p_txn;
  if not found then return; end if;
  k := case t.loan_role when 'repay' then 'repay' when 'borrow' then 'borrow' end;
  if t.loan_id is null or k is null then
    delete from public.loan_events where txn_id = p_txn;
    return;
  end if;
  select * into l from public.loans where id = t.loan_id;
  if not found or (k = 'borrow' and t.txn_at < l.created_at) then
    delete from public.loan_events where txn_id = p_txn;
    return;
  end if;
  if exists (select 1 from public.loan_events where txn_id = p_txn) then
    update public.loan_events set loan_id = t.loan_id, kind = k, amount = t.amount, event_at = t.txn_at where txn_id = p_txn;
    return;
  end if;
  -- The lender's email already has it.
  if exists (select 1 from public.loan_events e where e.loan_id = t.loan_id and e.kind = k and e.txn_id is null
              and e.email_id is not null and abs(e.amount - t.amount) < 1
              and abs(extract(epoch from e.event_at - t.txn_at)) <= 5 * 86400) then
    return;
  end if;
  insert into public.loan_events (user_id, loan_id, kind, amount, event_at, txn_id, note)
  values (t.user_id, t.loan_id, k, t.amount, t.txn_at, t.id, 'Bank payment')
  on conflict (txn_id) do nothing;
end $$;

create or replace function public.on_txn_loan_event()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.sync_loan_event(new.id);
  return null;
end $$;
drop trigger if exists txn_loan_event on public.transactions;
create trigger txn_loan_event after insert or update of loan_id, loan_role, amount, txn_at on public.transactions
  for each row execute function public.on_txn_loan_event();

-- Everything linked so far.
do $$ declare t uuid; begin
  for t in select id from public.transactions where loan_id is not null or loan_role is not null loop
    perform public.sync_loan_event(t);
  end loop;
end $$;
