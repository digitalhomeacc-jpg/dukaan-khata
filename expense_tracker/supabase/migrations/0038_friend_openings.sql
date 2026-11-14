-- Connected friends: an agreed opening balance, what was owed at the end of a day. The balance is this amount plus
-- the entries after that day; entries on or before it (including ones a bank import brings in later) are history.
-- Either person proposes it, the other says OK; until then nothing changes. The latest agreed one counts.
create table if not exists public.friend_openings (
  id           uuid primary key default gen_random_uuid(),
  link_id      uuid not null references public.friend_links on delete cascade,
  as_of        date not null,                      -- owed at the end of this day; later entries count
  owed_by      uuid references auth.users on delete cascade,  -- who owes on that day; null: all square
  amount       numeric(14,2) not null default 0 check (amount >= 0),
  note         text,
  created_by   uuid not null default auth.uid() references auth.users on delete cascade,
  created_at   timestamptz not null default now(),
  confirmed_at timestamptz,
  rejected_by  uuid references auth.users on delete set null,
  deleted_at   timestamptz,
  check ((owed_by is null) = (amount = 0))
);
create index if not exists friend_openings_link on public.friend_openings (link_id, as_of desc);
alter table public.friend_openings enable row level security;

drop policy if exists "see openings" on public.friend_openings;
create policy "see openings" on public.friend_openings for select
  using (exists (select 1 from public.friend_links l where l.id = link_id and auth.uid() in (l.a, l.b)));
do $$ begin
  alter publication supabase_realtime add table public.friend_openings;
exception when duplicate_object then null; end $$;

-- Propose an opening balance (changes go through these functions only).
create or replace function public.propose_friend_opening(p_link uuid, p_as_of date, p_owed_by uuid, p_amount numeric, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare l record; new_id uuid; amt numeric := round(coalesce(p_amount, 0), 2);
begin
  select * into l from public.friend_links fl where fl.id = p_link and fl.b is not null and auth.uid() in (fl.a, fl.b);
  if l is null then raise exception 'not connected'; end if;
  if amt < 0 then raise exception 'amount must not be negative'; end if;
  if amt > 0 and (p_owed_by is null or p_owed_by not in (l.a, l.b)) then raise exception 'who owes?'; end if;
  -- One proposal waits at a time: a new one replaces the one not answered yet.
  update public.friend_openings set deleted_at = now()
   where link_id = p_link and confirmed_at is null and deleted_at is null;
  insert into public.friend_openings (link_id, as_of, owed_by, amount, note, created_by)
  values (p_link, p_as_of, case when amt = 0 then null else p_owed_by end, amt, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning friend_openings.id into new_id;
  return new_id;
end $$;
grant execute on function public.propose_friend_opening(uuid, date, uuid, numeric, text) to authenticated;

-- The other person says OK or no. Returns true when saved.
create or replace function public.answer_friend_opening(p_id uuid, p_ok boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select f.* into o from public.friend_openings f join public.friend_links l on l.id = f.link_id
   where f.id = p_id and f.deleted_at is null and f.confirmed_at is null and auth.uid() in (l.a, l.b);
  if o is null then return false; end if;
  if o.created_by = auth.uid() then
    -- Whoever proposed it can only take it back.
    if not p_ok then update public.friend_openings set deleted_at = now() where id = p_id; return true; end if;
    raise exception 'waiting for the other person';
  end if;
  if p_ok then update public.friend_openings set confirmed_at = now() where id = p_id;
  else update public.friend_openings set deleted_at = now(), rejected_by = auth.uid() where id = p_id; end if;
  return true;
end $$;
grant execute on function public.answer_friend_opening(uuid, boolean) to authenticated;
