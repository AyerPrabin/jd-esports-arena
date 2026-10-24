-- MEGA events (2026-10-24, owner's plan): one huge paid event (e.g. 1,500 squads, 200 points entry, Rs 3 lakh)
-- with months of sign-ups. The event itself is a normal tournaments.json entry (same Join / pay / ticket / withdraw
-- flow); this file adds what's special:
--  * mega_events: the owner's settings (min / max squads, entry, prize pool, registration close, host + refer reward).
--  * Refund guarantee: when registration closes with fewer than min_squads paid squads, mega_settle() gives every
--    squad its entry back and the event is called off. Otherwise it's confirmed and invite rewards are paid.
--  * Invites: each paid squad can be credited to ONE inviter - a host mod (by @handle) or any player (JD tag /
--    username). Rewards are paid only when the event is confirmed, never for refunded squads, never to yourself.
--  * Format (qualifier groups of 12 -> semi-finals -> 12-squad final) is drawn when registration closes (later).
begin;

create table if not exists public.mega_events (
  slug text primary key,                     -- = the tournaments.json name
  headline text,                             -- e.g. 'MEGA coming in the next 4-6 months'
  min_squads int not null check (min_squads > 0),
  max_squads int not null check (max_squads >= min_squads),
  entry int not null check (entry >= 0),
  prize_pool int not null check (prize_pool >= 0),
  reg_closes_at timestamptz not null,
  host_reward int not null default 10 check (host_reward between 0 and 200),
  refer_reward int not null default 5 check (refer_reward between 0 and 200),
  status text not null default 'open' check (status in ('open', 'confirmed', 'refunded')),
  settled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.mega_events enable row level security;
drop policy if exists mega_events_read on public.mega_events;
create policy mega_events_read on public.mega_events for select using (true);   -- settings are public

create table if not exists public.mega_refs (
  registration_id uuid primary key references public.registrations(id) on delete cascade,
  slug text not null,
  referrer_id uuid not null references public.players(id) on delete cascade,
  kind text not null check (kind in ('host', 'player')),
  host_handle text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
alter table public.mega_refs enable row level security;   -- through the functions below only
create index if not exists mega_refs_slug_idx on public.mega_refs (slug, referrer_id);

-- paid squads in (the number on the progress bar and the one the refund rule uses)
create or replace function public._mega_paid_count(p_slug text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.registrations
  where tournament_slug = p_slug and status in ('confirmed', 'approved') and coalesce(paid_points, 0) > 0;
$$;
revoke all on function public._mega_paid_count(text) from public, anon, authenticated;

-- public: settings + progress + top promoters (hosts by @handle, players by name) for the /mega/ page
create or replace function public.mega_info(p_slug text default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object(
      'slug', m.slug, 'headline', m.headline, 'min', m.min_squads, 'max', m.max_squads, 'entry', m.entry,
      'prize_pool', m.prize_pool, 'reg_closes_at', m.reg_closes_at, 'host_reward', m.host_reward,
      'refer_reward', m.refer_reward, 'status', m.status, 'squads', public._mega_paid_count(m.slug),
      'top', coalesce((select jsonb_agg(x order by x->>'n' desc) from (
          select jsonb_build_object('name', case when r.kind = 'host' then '@' || max(r.host_handle)
                                                  else coalesce(max(p.username), max(p.player_tag)) end,
                                    'host', r.kind = 'host', 'n', count(*)) x
          from public.mega_refs r join public.registrations g on g.id = r.registration_id
          left join public.players p on p.id = r.referrer_id
          where r.slug = m.slug and g.status in ('confirmed', 'approved') and coalesce(g.paid_points, 0) > 0
          group by r.referrer_id, r.kind order by count(*) desc limit 10) t), '[]'::jsonb))
    from public.mega_events m
    where (p_slug is null and m.status = 'open') or m.slug = p_slug
    order by m.created_at desc limit 1), '{}'::jsonb);
$$;
grant execute on function public.mega_info(text) to anon, authenticated;

-- credit my squad's mega registration to an inviter (called by the site right after joining with an invite link)
create or replace function public.mega_set_ref(p_slug text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code text := lower(regexp_replace(trim(coalesce(p_code, '')), '^@', ''));
  v_reg public.registrations; v_ref uuid; v_kind text; v_handle text;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if not exists (select 1 from public.mega_events where slug = p_slug and status = 'open') then return jsonb_build_object('ok', false); end if;
  select * into v_reg from public.registrations where tournament_slug = p_slug and player_id = auth.uid();
  if v_reg.id is null then return jsonb_build_object('ok', false, 'reason', 'not registered'); end if;
  if exists (select 1 from public.mega_refs where registration_id = v_reg.id) then return jsonb_build_object('ok', false, 'reason', 'already credited'); end if;
  if v_reg.created_at < now() - interval '2 hours' then return jsonb_build_object('ok', false, 'reason', 'too late'); end if;
  if v_code = '' then return jsonb_build_object('ok', false); end if;
  -- a host mod's handle first, then a player's JD tag / username
  select pl.id, m.handle into v_ref, v_handle from public.moderators m join public.players pl on lower(pl.email) = lower(m.email)
   where m.role = 'host' and lower(m.handle) = v_code limit 1;
  if v_ref is not null then v_kind := 'host';
  else
    select id into v_ref from public.players
     where lower(player_tag) = v_code or lower(player_tag) = 'jd-' || v_code or lower(username) = v_code limit 1;
    v_kind := 'player';
  end if;
  if v_ref is null or v_ref = auth.uid() then return jsonb_build_object('ok', false, 'reason', 'unknown code'); end if;
  if exists (select 1 from public.banned_players where player_id = v_ref) then return jsonb_build_object('ok', false); end if;
  insert into public.mega_refs (registration_id, slug, referrer_id, kind, host_handle) values (v_reg.id, p_slug, v_ref, v_kind, v_handle);
  return jsonb_build_object('ok', true, 'kind', v_kind);
end $$;
revoke all on function public.mega_set_ref(text, text) from public, anon;
grant execute on function public.mega_set_ref(text, text) to authenticated;

-- my invite link + how many paid squads it brought
create or replace function public.my_mega(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'code', coalesce((select '@' || m.handle from public.moderators m join public.players pl on lower(pl.email) = lower(m.email)
                       where pl.id = auth.uid() and m.role = 'host' and m.handle is not null limit 1),
                     (select player_tag from public.players where id = auth.uid())),
    'host', exists (select 1 from public.moderators m join public.players pl on lower(pl.email) = lower(m.email)
                    where pl.id = auth.uid() and m.role = 'host'),
    'brought', (select count(*) from public.mega_refs r join public.registrations g on g.id = r.registration_id
                where r.slug = p_slug and r.referrer_id = auth.uid() and g.status in ('confirmed', 'approved') and coalesce(g.paid_points, 0) > 0),
    'joined', exists (select 1 from public.registrations where tournament_slug = p_slug and player_id = auth.uid()
                      and status in ('confirmed', 'approved') and coalesce(paid_points, 0) > 0)) end;
$$;
grant execute on function public.my_mega(text) to authenticated;

-- run by cron: settles every open mega whose registration has closed (refund all, or confirm + pay invite rewards)
create or replace function public.mega_settle() returns jsonb
language plpgsql security definer set search_path = public as $$
declare m public.mega_events; r record; v_n int; v_out jsonb := '[]'::jsonb;
begin
  for m in select * from public.mega_events where status = 'open' and reg_closes_at <= now() for update loop
    v_n := public._mega_paid_count(m.slug);
    if v_n < m.min_squads then
      for r in select * from public.registrations where tournament_slug = m.slug and coalesce(paid_points, 0) > 0 loop
        perform public._wallet_apply(r.player_id, r.paid_points, 'refund', 'mega_refund:' || r.id::text,
                                     'MEGA called off: ' || m.slug || ' did not reach ' || m.min_squads || ' squads');
        update public.registrations set status = 'rejected', paid_points = 0 where id = r.id;
        insert into public.notifications (player_id, tournament_slug, title, body, push)
        values (r.player_id, m.slug, '↩️ ' || m.slug || ' called off - entry refunded',
                m.slug || ' got ' || v_n || ' of the ' || m.min_squads || ' squads it needed, so it won''t run. Your ' ||
                r.paid_points || ' points are back in your wallet.', true);
      end loop;
      update public.mega_events set status = 'refunded', settled_at = now(), updated_at = now() where slug = m.slug;
    else
      for r in select f.*, m.host_reward hr, m.refer_reward pr from public.mega_refs f
               join public.registrations g on g.id = f.registration_id
               where f.slug = m.slug and f.paid_at is null and g.status in ('confirmed', 'approved') and coalesce(g.paid_points, 0) > 0 loop
        if (case when r.kind = 'host' then r.hr else r.pr end) > 0 then
          perform public._wallet_apply(r.referrer_id, case when r.kind = 'host' then r.hr else r.pr end, 'referral',
                                       'mega_ref:' || r.registration_id::text, 'MEGA invite reward: ' || m.slug);
        end if;
        update public.mega_refs set paid_at = now() where registration_id = r.registration_id;
      end loop;
      update public.mega_events set status = 'confirmed', settled_at = now(), updated_at = now() where slug = m.slug;
      insert into public.notifications (player_id, tournament_slug, title, body, push)
      select distinct g.player_id, m.slug, '✅ ' || m.slug || ' is ON!',
             v_n || ' squads are in - ' || m.slug || ' is confirmed. Qualifier groups and dates come next, here in Alerts.', true
      from public.registrations g where g.tournament_slug = m.slug and g.status in ('confirmed', 'approved') and coalesce(g.paid_points, 0) > 0;
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('slug', m.slug, 'squads', v_n,
                                                           'result', case when v_n < m.min_squads then 'refunded' else 'confirmed' end));
  end loop;
  return v_out;
end $$;
revoke all on function public.mega_settle() from public, anon, authenticated;

-- the homepage roster carries squad logos; a 1,500-squad event would make it megabytes, so mega squads come without
-- (the /mega/ page shows counts, not 1,500 logos)
create or replace function public.get_public_roster()
returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz, effect text, pass_tier text)
language sql stable security definer set search_path = public as $function$
  select r.tournament_slug, r.squad_name,
    case when exists (select 1 from public.mega_events m where m.slug = r.tournament_slug) then null else coalesce(r.squad_logo, p.squad_logo) end,
    r.created_at,
    coalesce(r.effect, (
      select ep.effect from public.effect_passes ep
      where ep.player_id = r.player_id and ep.starts_at <= now() and ep.expires_at > now()
      order by ep.expires_at asc limit 1
    )),
    public.weekly_pass_tier(r.player_id)
  from public.registrations r left join public.players p on p.id = r.player_id
  where r.status in ('confirmed', 'approved')
  order by r.created_at asc;
$function$;

commit;

-- settle daily (a closed registration is handled within a day); idempotent: settled events are skipped
select cron.unschedule(jobid) from cron.job where jobname = 'mega-settle';
select cron.schedule('mega-settle', '40 * * * *', 'select public.mega_settle()');

-- ── daily MEGA progress push (2026-10-24): players can switch it off like other alert types ('mega') ──
create or replace function public.set_push_pref(p_type text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_type not in ('dm','squad','match','friends','challenges','lobby','wallet','mega') then raise exception 'Unknown alert type.'; end if;
  insert into public.push_prefs (player_id, off) values (auth.uid(), '{}') on conflict (player_id) do nothing;
  update public.push_prefs set
    off = case when coalesce(p_on, true) then array_remove(off, p_type)
               else array_append(array_remove(off, p_type), p_type) end,
    updated_at = now()
  where player_id = auth.uid();
  return public.get_push_prefs();
end;
$$;

create table if not exists public.mega_daily_log (slug text not null, day date not null, sent_at timestamptz not null default now(),
  primary key (slug, day));
alter table public.mega_daily_log enable row level security;

-- once a day at 7 PM Nepal (13:15 UTC) the mega-daily function pushes the progress to players not in it yet
select cron.unschedule(jobid) from cron.job where jobname = 'mega-daily';
select cron.schedule('mega-daily', '15 13 * * *', $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/mega-daily',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$cron$);
