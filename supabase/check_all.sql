-- Read-only: shows whether each SQL update is in this database. Changes nothing.
with c as (select table_name t, column_name c from information_schema.columns where table_schema = 'public'),
     f as (select proname, prosrc from pg_proc where pronamespace = 'public'::regnamespace),
     pub as (select tablename from pg_publication_tables where pubname = 'powersync')
select step, case when ok then '✅' else '❌ run this one' end as status from (values
 ('0001 tables + sync',     (select count(*) from pub where tablename in ('businesses','members','ledgers','items','vouchers','voucher_lines','inventory_lines','audit_log')) = 8),
 ('0002 hamali / transport',exists (select 1 from c where t = 'vouchers' and c = 'transporter_fare')),
 ('0003 GST / bank',        exists (select 1 from c where t = 'bank_lines' and c = 'fingerprint') and exists (select 1 from pub where tablename = 'bank_lines')),
 ('0004 one-piece upload',  exists (select 1 from f where proname = 'apply_crud')),
 ('0005 haste / promises',  exists (select 1 from c where t = 'vouchers' and c = 'haste') and exists (select 1 from pg_policies where policyname = 'v_upd' and qual like '%promise%')),
 ('0006 interest / name_en',exists (select 1 from c where t = 'ledgers' and c = 'interest_rate') and exists (select 1 from c where t = 'businesses' and c = 'name_en')),
 ('0007 staff salary',      exists (select 1 from c where t = 'ledgers' and c = 'salary_cut')),
 ('0008 history time',      exists (select 1 from c where t = 'audit_log' and c = 'received_at') and exists (select 1 from pg_trigger where tgname = 'audit_received')),
 ('0009 storage meter',     exists (select 1 from f where proname = 'db_size')),
 ('0010 staff old entries', exists (select 1 from f where proname = 'history_editable')),
 ('0011 item subcategory',  exists (select 1 from c where t = 'items' and c = 'subcategory')),
 ('0012 backup link',       exists (select 1 from c where t = 'businesses' and c = 'backup_url')),
 ('0013 history sent twice',exists (select 1 from f where proname = 'apply_crud' and prosrc like '%audit_log%do nothing%' or proname = 'apply_crud' and prosrc like '%not allowed to change%')),
 ('0014 accounts kept',     exists (select 1 from f where proname = 'apply_crud' and (prosrc like '%''ledgers'',''items'') then%' or prosrc like '%''audit_log'', ''ledgers'', ''items'')%'))),
 ('0015 resend safe',       exists (select 1 from f where proname = 'apply_crud' and prosrc like '%not allowed to change%'))
) v(step, ok);
