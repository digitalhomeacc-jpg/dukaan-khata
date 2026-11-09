-- English shop name (printed on PDFs and bills) and party-wise interest rate.
alter table businesses add column if not exists name_en text;
alter table ledgers add column if not exists interest_rate integer not null default 0;  -- % per month × 100 (150 = 1.5 %)
