-- कर्मचारी: monthly salary and advance recovered per month (paise).
alter table ledgers add column if not exists salary integer not null default 0;
alter table ledgers add column if not exists salary_cut integer not null default 0;
