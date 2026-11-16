-- Pairs of payments you checked and said are not duplicates (each pair as "id1|id2"), so they are not asked again.
alter table public.profiles add column if not exists not_duplicates text[] not null default '{}';
