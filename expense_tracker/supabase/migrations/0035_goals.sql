-- Goals: save an amount by a date (measured as money kept, or an account's balance growing), or spend less
-- in a category (a percentage below its usual month).
create table if not exists public.goals (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users on delete cascade,
  kind          text not null check (kind in ('save', 'cut')),
  name          text not null check (length(btrim(name)) between 1 and 80),
  emoji         text,
  starts_on     date not null default current_date,
  target_amount numeric(14,2) check (target_amount > 0),             -- save
  deadline      date,                                                -- save
  account_id    uuid references public.accounts on delete set null,  -- save: this account's growth; else money kept
  category_id   uuid references public.categories on delete cascade, -- cut
  cut_pct       numeric(5,2) check (cut_pct > 0 and cut_pct <= 100),  -- cut
  archived      boolean not null default false,
  created_at    timestamptz not null default now(),
  check ((kind = 'save' and target_amount is not null and deadline is not null)
      or (kind = 'cut' and category_id is not null and cut_pct is not null))
);
alter table public.goals enable row level security;
drop policy if exists "own goals" on public.goals;
create policy "own goals" on public.goals for all using (user_id = auth.uid()) with check (user_id = auth.uid());
do $$ begin
  alter publication supabase_realtime add table public.goals;
exception when duplicate_object then null; end $$;
drop trigger if exists log_change on public.goals;
create trigger log_change after insert or update or delete on public.goals for each row execute function public.log_change();
