-- Money added to a wallet from the bank (e.g. "Amazon Pay Balance") is a move between
-- your own accounts, not spending: the wallet's own payments are the spending.
create or replace function public.link_wallet_topups(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; c integer; w record;
begin
  if p_user is distinct from auth.uid() and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'not allowed';
  end if;
  for w in select id, bank from public.accounts where user_id = p_user and kind = 'wallet' and bank is not null loop
    update public.transactions t set excluded = true, counter_account_id = w.id, needs_review = false
     where t.user_id = p_user and t.direction = 'debit' and not t.excluded and not t.edited
       and t.account_id is distinct from w.id
       and t.merchant_key in (lower(w.bank) || ' balance', lower(w.bank) || ' wallet', lower(w.bank) || ' add money',
                              lower(w.bank) || ' topup', lower(w.bank) || ' top up');
    get diagnostics c = row_count;
    n := n + c;
  end loop;
  return n;
end $$;
grant execute on function public.link_wallet_topups(uuid) to authenticated, service_role;
