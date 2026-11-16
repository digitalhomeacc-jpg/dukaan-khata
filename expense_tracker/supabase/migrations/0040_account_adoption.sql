-- No more surprise accounts. An account you made or renamed in the app had no bank / last 4 digits, so the
-- first bank email or statement for it created a second account ("HDFC A/c ••6516") and the payments went
-- there. Now:
-- 1. A new account for a bank + last 4 digits is not made when you have exactly one account of that bank and
--    kind without digits: that account takes the digits instead.
-- 2. A payment that arrives without an account goes to the account with its bank + last 4 digits.

-- The bank email and statement functions create an account with "insert, or update the one with this name".
-- Giving the new row your account's name makes that your account: it is updated with the bank + digits and
-- returned to them, so their payments land in it.
create or replace function public.adopt_account()
returns trigger language plpgsql security definer set search_path = public as $$
declare existing text; n integer;
begin
  if new.last4 is null or new.bank is null then return new; end if;
  select name into existing from public.accounts
   where user_id = new.user_id and lower(bank) = lower(new.bank) and last4 = new.last4
   order by archived, created_at limit 1;
  if existing is null then
    select count(*), min(name) into n, existing from public.accounts
     where user_id = new.user_id and last4 is null and not archived and kind = new.kind
       and (lower(coalesce(bank, '')) = lower(new.bank)
            or (bank is null and lower(name) like '%' || lower(new.bank) || '%'));
    if n <> 1 then existing := null; end if;
  end if;
  if existing is not null then
    new.name := existing;  -- "insert or update by name" now updates your account
  end if;
  return new;
end $$;
drop trigger if exists adopt_account on public.accounts;
create trigger adopt_account before insert on public.accounts
  for each row execute function public.adopt_account();

create or replace function public.fill_txn_account()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.account_id is null and new.bank is not null and new.account_last4 is not null and new.source in ('email', 'statement') then
    select id into new.account_id from public.accounts
     where user_id = new.user_id and lower(bank) = lower(new.bank) and last4 = new.account_last4
     order by archived, created_at limit 1;
  end if;
  return new;
end $$;
drop trigger if exists fill_txn_account on public.transactions;
create trigger fill_txn_account before insert on public.transactions
  for each row execute function public.fill_txn_account();
