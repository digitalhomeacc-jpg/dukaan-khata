-- An opening balance stands for everything up to the exact moment you set it, not the whole day: a payment
-- earlier that day is history, a payment later that day counts on top. Older ones keep their day.
alter table public.people add column if not exists ledger_at timestamptz;
alter table public.friend_openings add column if not exists at timestamptz;

create or replace function public.propose_friend_opening_at(p_link uuid, p_at timestamptz, p_owed_by uuid, p_amount numeric, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare l record; new_id uuid; amt numeric := round(coalesce(p_amount, 0), 2); moment timestamptz := coalesce(p_at, now());
begin
  select * into l from public.friend_links fl where fl.id = p_link and fl.b is not null and auth.uid() in (fl.a, fl.b);
  if l is null then raise exception 'not connected'; end if;
  if amt < 0 then raise exception 'amount must not be negative'; end if;
  if amt > 0 and (p_owed_by is null or p_owed_by not in (l.a, l.b)) then raise exception 'who owes?'; end if;
  update public.friend_openings set deleted_at = now()
   where link_id = p_link and confirmed_at is null and deleted_at is null;
  insert into public.friend_openings (link_id, as_of, at, owed_by, amount, note, created_by, confirmed_at)
  values (p_link, (moment at time zone 'Asia/Kolkata')::date, moment, case when amt = 0 then null else p_owed_by end, amt,
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid(), now())
  returning friend_openings.id into new_id;
  return new_id;
end $$;
grant execute on function public.propose_friend_opening_at(uuid, timestamptz, uuid, numeric, text) to authenticated;
