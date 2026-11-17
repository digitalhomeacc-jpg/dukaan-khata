-- The same bank email read again (the Gmail script re-sends overlapping days) put the raw name back
-- ("sindgineel@") over the name a rule had found ("Neel Asim Sindgi"); the rule fixed it again, and so on:
-- the same two changes in the history every few minutes. Now the bank's raw name is remembered when a rule
-- renames a payment, and an automatic update can no longer put that raw name back. Your own edits always win.
alter table public.transactions add column if not exists raw_merchant text;

create or replace function public.keep_better_name()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.merchant is distinct from old.merchant and auth.uid() is null then
    if old.raw_merchant is not null and new.merchant is not distinct from old.raw_merchant then
      new.merchant := old.merchant;            -- the same email again: keep the better name
      new.bank_name := old.bank_name;
    elsif old.raw_merchant is null then
      new.raw_merchant := old.merchant;        -- a rule renamed it: remember what the bank said
    end if;
  end if;
  return new;
end $$;
drop trigger if exists keep_better_name on public.transactions;
create trigger keep_better_name before update on public.transactions
  for each row execute function public.keep_better_name();

-- Payments already flipping: remember their raw name now (the bank email's name is in the change history).
update public.transactions t set raw_merchant = x.raw
  from (select distinct on (c.txn_id) c.txn_id, c.after ->> 'merchant' as raw
          from public.change_log c
         where c.tbl = 'transactions' and c.op = 'update' and not c.by_user and c.after ? 'merchant'
           and exists (select 1 from public.change_log d where d.txn_id = c.txn_id and d.tbl = 'transactions'
                        and d.before ->> 'merchant' = c.after ->> 'merchant' and d.after ->> 'merchant' = c.before ->> 'merchant')
         order by c.txn_id, c.id desc) x
 where t.id = x.txn_id and t.raw_merchant is null and x.raw is distinct from t.merchant;
