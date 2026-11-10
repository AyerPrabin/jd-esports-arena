-- Welcome card (owner, 8 Nov 2026): every NEW player gets 1 free-event entry card, valid 7 days.
-- It is given when the player first saves their Free Fire UID (Account > Game UID & name), once per UID ever,
-- so throwaway accounts with the same UID can't farm cards (captcha is still off).
-- Offer runs for players who sign up between 8 Nov 2026 and 8 Dec 2026; change the dates in _welcome_card() to extend.
-- Rollback: welcome_card_rollback.sql. Safe to run again.
begin;

create table if not exists public.welcome_cards (
  ff_uid text primary key,
  player_id uuid references public.players(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.welcome_cards enable row level security;   -- no policies: server only
revoke all on public.welcome_cards from anon, authenticated;

create or replace function public._welcome_card() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.ff_uid is null or old.ff_uid is not null then return new; end if;
  if new.created_at < timestamptz '2026-11-08 00:00+00' or now() > timestamptz '2026-12-08 23:59+00' then return new; end if;
  begin   -- a card problem must never stop the player saving their UID
    insert into public.welcome_cards (ff_uid, player_id) values (new.ff_uid, new.id) on conflict (ff_uid) do nothing;
    if found then
      insert into public.entry_vouchers (player_id, expires_at, tier, max_npr) values (new.id, now() + interval '7 days', 'free', 1);
      insert into public.notifications (player_id, title, body) values (new.id, 'Welcome gift: 1 free card',
        'Welcome to JD Arena! You got a free card. It joins one free tournament and lasts 7 days. Open Events and tap Join.');
    end if;
  exception when others then
    raise warning 'welcome card: %', sqlerrm;
  end;
  return new;
end $$;
revoke all on function public._welcome_card() from public, anon, authenticated;

drop trigger if exists welcome_card on public.players;
create trigger welcome_card after update of ff_uid on public.players
  for each row execute function public._welcome_card();

commit;
