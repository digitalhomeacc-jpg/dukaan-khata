-- Pairs of payments you checked and said are not duplicates (each pair as "id1|id2"), so they are not asked again.
alter table public.profiles add column if not exists not_duplicates text[] not null default '{}';

-- Your UPI ID, for "pay me" links in reminders to friends.
alter table public.profiles add column if not exists upi_id text;

-- Receipts: a photo of the bill on any payment, in a private folder per person.
alter table public.transactions add column if not exists receipt_path text;
insert into storage.buckets (id, name, public) values ('receipts', 'receipts', false) on conflict (id) do nothing;
drop policy if exists "own receipts: see" on storage.objects;
create policy "own receipts: see" on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own receipts: add" on storage.objects;
create policy "own receipts: add" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own receipts: remove" on storage.objects;
create policy "own receipts: remove" on storage.objects for delete to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
