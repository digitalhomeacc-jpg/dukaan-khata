-- What the bank wrote about a payment (statement narration) is kept apart from your own note.
alter table public.transactions add column if not exists details text;

update public.transactions
   set details = note,
       note = case when edited and note !~* '^(UPI|NEFT|IMPS|RTGS|POS|CRV|ATW|NWD|EAW|ACH|BW|repayment|interest|Fund|IB |MB |CC |EMI|.{0,4}Credit|.{0,4}Debit)' then note end
 where source = 'statement' and details is null and note is not null;
