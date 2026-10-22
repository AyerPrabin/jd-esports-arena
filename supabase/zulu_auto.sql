-- ── ZULU auto-messages in the JD Esports chat (2026-10-22) ──
-- ZULU (the JD AI) writes to each player's JD Esports chat (jd_chat.sql) by itself:
--   * welcome when an account is made
--   * registration: in a slot / waiting for approval / waitlist (+ "add your WhatsApp" if it's missing)
--   * a waitlist squad moves into a slot, a paid registration is approved or rejected
--   * points loaded or refunded
--   * every 10 min (zulu_auto_sweep): squads in a slot that haven't confirmed 30 min – 3 h before the start,
--     and regular paid players who don't have enough points for a paid event starting in the next 24 h
--   * AI replies: when a player writes in the chat, the zulu-auto Edge Function answers at once (unless a
--     moderator wrote there in the last 20 min). Moderators still see every player message in /mod/ → Chats.
-- staff_email 'zulu' = template, 'zulu-ai' = AI reply; players see both as ZULU inside JD Esports.
-- push = false where the same event already sends a notification with a push, so phones don't buzz twice.
-- Every message is sent once per player + key (zulu_auto_log). Nothing here can block the action that
-- triggered it: all errors are swallowed as warnings.
begin;

alter table public.jd_messages add column if not exists push boolean not null default true;

create table if not exists public.zulu_auto_log (
  player_id uuid not null references public.players(id) on delete cascade,
  key text not null,
  created_at timestamptz not null default now(),
  primary key (player_id, key)
);
alter table public.zulu_auto_log enable row level security;   -- no policies: server only

-- one ZULU message, once per (player, key)
create or replace function public._zulu_say(p_player uuid, p_key text, p_body text, p_push boolean default false)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_player is null or coalesce(p_body, '') = '' then return false; end if;
  insert into public.zulu_auto_log (player_id, key) values (p_player, p_key) on conflict do nothing;
  if not found then return false; end if;
  insert into public.jd_messages (player_id, from_staff, staff_email, body, push)
  values (p_player, true, 'zulu', left(p_body, 1000), p_push);
  return true;
exception when others then
  raise warning '_zulu_say %: %', p_key, sqlerrm;
  return false;
end;
$$;
revoke all on function public._zulu_say(uuid, text, text, boolean) from public, anon, authenticated;

-- "Thu 22 Oct, 08:00 PM" in Nepal time, or '' when the event has no start
create or replace function public._zulu_when(p_slug text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(to_char(public.tournament_start_at(p_slug) at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM'), '')
$$;
revoke all on function public._zulu_when(text) from public, anon, authenticated;

-- the player's thread now says which staff messages are ZULU (ai)
drop function if exists public.jd_thread(bigint);
create or replace function public.jd_thread(p_before bigint default null)
returns table (id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz, ai boolean)
language sql stable security definer set search_path = public as $$
  select m.id, not m.from_staff, m.body, m.created_at, m.read_at, coalesce(m.staff_email like 'zulu%', false)
  from public.jd_messages m
  where m.player_id = auth.uid() and (p_before is null or m.id < p_before)
  order by m.id desc limit 60
$$;
revoke all on function public.jd_thread(bigint) from public, anon;
grant execute on function public.jd_thread(bigint) to authenticated;

-- push only staff messages marked push (dm-push, kind 'jd')
create or replace function public.jd_messages_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids bigint[]; v_q bigint[];
begin
  select array_agg(id) into v_ids from new_rows where from_staff and push;
  select array_agg(id) into v_q from new_rows where not from_staff;
  begin
    if v_ids is not null then
      perform net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/dm-push',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
        body := jsonb_build_object('ids', to_jsonb(v_ids), 'kind', 'jd'));
    end if;
    -- a player wrote: ZULU answers (zulu-auto)
    if v_q is not null then
      perform net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/zulu-auto',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
        body := jsonb_build_object('ids', to_jsonb(v_q)));
    end if;
  exception when others then
    raise warning 'jd_messages_push: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.jd_messages_push() from public, anon, authenticated;

-- ── welcome ──
create or replace function public.zulu_on_player() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public._zulu_say(new.id, 'welcome',
    'Hey @' || new.username || '! 👋 I''m ZULU, the JD Esports assistant. This is your official chat with the JD team.' || chr(10) || chr(10) ||
    'How to start:' || chr(10) ||
    '1. Load points in Wallet (eSewa QR + screenshot). 1 point = Rs 1.' || chr(10) ||
    '2. Join an event on Events, then confirm your slot on your ticket.' || chr(10) ||
    '3. Add your squad in Messages and get the JD app for match alerts.' || chr(10) || chr(10) ||
    'Ask me anything here, any time. A JD moderator reads this chat too.', false);
  return null;
exception when others then
  raise warning 'zulu_on_player: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists zulu_on_player on public.players;
create trigger zulu_on_player after insert on public.players for each row execute function public.zulu_on_player();

-- ── registrations ──
create or replace function public.zulu_on_registration() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sq text := coalesce(nullif(trim(new.squad_name), ''), 'Your squad');
        v_when text := public._zulu_when(new.tournament_slug);
        v_ev text := new.tournament_slug || case when public._zulu_when(new.tournament_slug) <> '' then ' (' || public._zulu_when(new.tournament_slug) || ')' else '' end;
        v_wa text := case when coalesce(trim(new.whatsapp), '') = '' then chr(10) || chr(10) ||
          '⚠️ Your registration has no WhatsApp number. Add one on your ticket so the JD team can reach your squad on match day.' else '' end;
begin
  if tg_op = 'INSERT' then
    if new.status in ('confirmed', 'approved') then
      perform public._zulu_say(new.player_id, 'reg:' || new.tournament_slug,
        '✅ ' || v_sq || ' is in ' || v_ev || '.' || chr(10) || chr(10) ||
        'Before the match, open your ticket and tap "Confirm you''re playing". Squads that don''t confirm can lose the slot to the waitlist. ' ||
        'The Room ID and password come about 5 minutes before the start. Rules: jdesport.co.uk/rules/' || v_wa, false);
    elsif new.status = 'pending' then
      perform public._zulu_say(new.player_id, 'reg:' || new.tournament_slug,
        '🕒 Got ' || v_sq || '''s registration for ' || v_ev || '. The admin is checking it. I''ll tell you here as soon as it''s approved.' || v_wa, false);
    elsif new.status = 'waitlisted' then
      perform public._zulu_say(new.player_id, 'reg:' || new.tournament_slug,
        '⏳ ' || new.tournament_slug || ' is full, so ' || v_sq || ' is on the waitlist. If a squad drops out you move up automatically, and I''ll message you here.' || v_wa, false);
    end if;
  elsif new.status is distinct from old.status then
    if old.status = 'waitlisted' and new.status in ('confirmed', 'approved') then
      perform public._zulu_say(new.player_id, 'promoted:' || new.tournament_slug,
        '🎉 A slot opened: ' || v_sq || ' is now in ' || v_ev || '! Open your ticket and tap "Confirm you''re playing" so you keep it.', false);
    elsif old.status = 'pending' and new.status = 'approved' then
      perform public._zulu_say(new.player_id, 'approved:' || new.tournament_slug,
        '✅ Approved! ' || v_sq || ' is in ' || v_ev || '. Confirm you''re playing on your ticket before the match.' || v_wa, false);
    elsif new.status = 'rejected' then
      perform public._zulu_say(new.player_id, 'rejected:' || new.tournament_slug,
        '❌ ' || v_sq || '''s registration for ' || new.tournament_slug || ' wasn''t approved. Reply here if you think it''s a mistake and a moderator will check it.', false);
    end if;
  end if;
  return null;
exception when others then
  raise warning 'zulu_on_registration: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists zulu_on_registration on public.registrations;
create trigger zulu_on_registration after insert or update of status on public.registrations
  for each row execute function public.zulu_on_registration();

-- ── points ──
create or replace function public.zulu_on_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_next text;
begin
  if new.reason = 'load' and new.delta > 0 then
    select t->>'name' into v_next
      from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
     where s.key = 'tournaments' and lower(coalesce(t->>'status', 'upcoming')) in ('upcoming', 'live', 'open')
       and coalesce(trim(t->>'winner'), '') = '' and public.tournament_start_at(t->>'name') > now()
     order by public.tournament_start_at(t->>'name') limit 1;
    perform public._zulu_say(new.player_id, 'load:' || new.id,
      '🪙 +' || new.delta || ' points loaded. Your balance is ' || new.balance_after || ' points.' ||
      coalesce(chr(10) || chr(10) || 'Next event: ' || v_next || ' (' || public._zulu_when(v_next) || '). Join it on Events.', ''), false);
  elsif new.reason = 'refund' and new.delta > 0 then
    perform public._zulu_say(new.player_id, 'refund:' || new.id,
      '↩️ ' || new.delta || ' points were refunded to your wallet. Balance: ' || new.balance_after || ' points.', false);
  end if;
  return null;
exception when others then
  raise warning 'zulu_on_ledger: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists zulu_on_ledger on public.wallet_ledger;
create trigger zulu_on_ledger after insert on public.wallet_ledger for each row execute function public.zulu_on_ledger();

-- ── every 10 minutes ──
create or replace function public.zulu_auto_sweep() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  -- 1. squads in a slot that haven't confirmed, 30 min – 3 h before the start
  for r in
    select g.player_id, g.tournament_slug, coalesce(nullif(trim(g.squad_name), ''), 'Your squad') as sq,
           coalesce(trim(g.whatsapp), '') = '' as no_wa
      from public.registrations g
     where g.status in ('confirmed', 'approved') and g.checked_in_at is null
       and public.tournament_start_at(g.tournament_slug) between now() + interval '30 minutes' and now() + interval '3 hours'
  loop
    if public._zulu_say(r.player_id, 'confirm:' || r.tournament_slug,
      '⏰ ' || r.tournament_slug || ' starts at ' || public._zulu_when(r.tournament_slug) || ' and ' || r.sq || ' hasn''t confirmed yet.' || chr(10) || chr(10) ||
      'Open your ticket and tap "Confirm you''re playing", or reply here and a moderator will mark you. Unconfirmed squads can lose the slot to the waitlist.' ||
      case when r.no_wa then chr(10) || chr(10) || '⚠️ Also add a WhatsApp number on your ticket so we can reach you.' else '' end, true) then n := n + 1; end if;
  end loop;

  -- 2. regular paid players without enough points for a paid event in the next 24 h
  for r in
    select p.id as player_id, t.name, t.entry, coalesce(w.balance, 0) as bal
      from (select t->>'name' as name, public.tournament_entry_npr(t->>'name') as entry
              from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
             where s.key = 'tournaments' and coalesce(trim(t->>'winner'), '') = ''
               and public.tournament_start_at(t->>'name') between now() + interval '1 hour' and now() + interval '24 hours') t
      join public.players p on exists (select 1 from public.registrations x where x.player_id = p.id and x.paid_points > 0
                                         and x.created_at > now() - interval '30 days')
      left join public.wallets w on w.player_id = p.id
     where t.entry > 0 and coalesce(w.balance, 0) < t.entry
       and not exists (select 1 from public.registrations x where x.player_id = p.id and x.tournament_slug = t.name)
  loop
    if public._zulu_say(r.player_id, 'lowpts:' || r.name,
      '🔥 ' || r.name || ' starts ' || public._zulu_when(r.name) || '. Entry is ' || r.entry || ' points and you have ' || r.bal || '.' || chr(10) || chr(10) ||
      'Load ' || (r.entry - r.bal) || ' more in Wallet (eSewa QR + screenshot) to join before the slots fill up.', true) then n := n + 1; end if;
  end loop;
  return n;
end;
$$;
revoke all on function public.zulu_auto_sweep() from public, anon, authenticated;

select cron.unschedule('zulu-auto-sweep') where exists (select 1 from cron.job where jobname = 'zulu-auto-sweep');
select cron.schedule('zulu-auto-sweep', '*/10 * * * *', 'select public.zulu_auto_sweep()');

commit;
