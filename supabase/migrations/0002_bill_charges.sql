-- Hamali and transport charges on sale bills.
alter table vouchers add column if not exists hamali bigint not null default 0;
alter table vouchers add column if not exists transport bigint not null default 0;
alter table vouchers add column if not exists transporter_id text;     -- null = own vehicle
alter table vouchers add column if not exists transporter_fare bigint; -- owed to outside transporter
