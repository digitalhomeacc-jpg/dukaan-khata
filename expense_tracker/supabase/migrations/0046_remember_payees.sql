-- A payee you sorted stays sorted. A new payment (or one renamed by a rule, e.g. from its UPI ID to the
-- person's full name) with no category takes the category you chose for that payee: your saved rules first,
-- else your past sorting when it all agrees (one category). Names match exactly, or when one is the other cut
-- short by a statement (12+ letters), or the other plus more words (two words or more: a first name alone
-- never matches). Never a payment you edited; never when you gave the payee different categories.

create or replace function public.same_payee(a text, b text)
returns boolean language sql immutable as $$
  select a = b
      or (length(a) >= 12 and b like a || '%') or (length(b) >= 12 and a like b || '%')
      or (a like '% %' and b like a || ' %') or (b like '% %' and a like b || ' %')
$$;

create or replace function public.payee_category(p_user uuid, p_key text, p_vpa text, p_except uuid default null)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare c uuid; n integer;
begin
  if coalesce(p_key, '') = '' then return null; end if;
  select category_id into c from public.merchant_rules where user_id = p_user and merchant_key = p_key;
  if c is not null then return c; end if;
  select count(distinct category_id), min(category_id::text)::uuid into n, c from public.merchant_rules
   where user_id = p_user and public.same_payee(merchant_key, p_key);
  if n = 1 then return c; end if;
  if p_vpa is not null then
    select category_id into c from public.vpa_rules where user_id = p_user and vpa = p_vpa;
    if c is not null then return c; end if;
  end if;
  select count(distinct category_id), min(category_id::text)::uuid into n, c from public.transactions
   where user_id = p_user and category_id is not null and not excluded and loan_role is null
     and id is distinct from p_except and public.same_payee(merchant_key, p_key);
  if n = 1 then return c; end if;
  return null;
end $$;

create or replace function public.fill_payee_category()
returns trigger language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  if new.category_id is not null or new.excluded or new.loan_role is not null or new.paid_by is not null then return new; end if;
  if tg_op = 'UPDATE' and new.edited then return new; end if;
  c := public.payee_category(new.user_id, btrim(lower(regexp_replace(coalesce(new.merchant, ''), '\s+', ' ', 'g'))),
                             new.payee_vpa, new.id);
  if c is not null then
    new.category_id := c;
    new.needs_review := false;
  end if;
  return new;
end $$;
drop trigger if exists fill_payee_category on public.transactions;
create trigger fill_payee_category before insert or update of merchant, payee_vpa on public.transactions
  for each row execute function public.fill_payee_category();

-- Unsorted payments of payees you already sorted: sorted now.
update public.transactions t set category_id = x.c, needs_review = false
  from (select id, public.payee_category(user_id, merchant_key, payee_vpa, id) c from public.transactions
         where category_id is null and not edited and not excluded and loan_role is null and paid_by is null) x
 where t.id = x.id and x.c is not null;
