-- Rewarded-ad gate for FREE tournaments (owner request 2026-10-27). OFF until an ad account exists:
-- turn on with  update public.ad_config set enabled = true, ad_unit = '/<network code>/<rewarded unit>';
-- Rule: a player without a Weekly Pass (or Optimizer Max) watches 3 rewarded ads to join a free tournament,
-- at most 1 ad per hour. Each finished ad = 1 credit; joining a free event uses 3. Paid events never need ads.
-- Only Google rewarded formats (Ad Manager / GPT rewarded) may be used: gating on normal display ads breaks
-- AdSense policy. The hour limit and the credit check live here, so the page can't skip them.

create table if not exists public.ad_config (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  ads_needed int not null default 3 check (ads_needed between 1 and 10),
  cooldown_minutes int not null default 60 check (cooldown_minutes >= 0),
  ad_unit text                                  -- GPT rewarded ad unit path, e.g. /1234567/jd_rewarded
);
insert into public.ad_config (id) values (true) on conflict do nothing;
alter table public.ad_config enable row level security;

create table if not exists public.ad_views (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  used_for text,                                -- tournament slug the credit was spent on
  used_at timestamptz
);
create index if not exists ad_views_player on public.ad_views (player_id, viewed_at desc);
alter table public.ad_views enable row level security;

create or replace function public._ad_exempt(p_player uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.weekly_pass_tier(p_player, now()) is not null or public._optimizer_is_max(p_player);
$$;
revoke all on function public._ad_exempt(uuid) from public, anon, authenticated;

-- what the join button needs to know: is the gate on, how many credits, when the next ad is allowed
create or replace function public.ad_status()
returns json language plpgsql stable security definer set search_path = public as $$
declare c public.ad_config; v_have int; v_last timestamptz;
begin
  select * into c from public.ad_config where id;
  if auth.uid() is null or not c.enabled or c.ad_unit is null then   -- no ad unit = gate off
    return json_build_object('enabled', false);
  end if;
  select count(*) filter (where used_for is null), max(viewed_at) into v_have, v_last
    from public.ad_views where player_id = auth.uid();
  return json_build_object('enabled', true, 'unit', c.ad_unit, 'needed', c.ads_needed, 'have', v_have,
    'exempt', public._ad_exempt(auth.uid()),
    'next_at', case when v_last is not null and v_last + make_interval(mins => c.cooldown_minutes) > now()
                    then v_last + make_interval(mins => c.cooldown_minutes) end);
end $$;
grant execute on function public.ad_status() to authenticated;

-- called after Google reports the reward was granted (rewardedSlotGranted); one credit per hour at most
create or replace function public.ad_reward_claim()
returns json language plpgsql security definer set search_path = public as $$
declare c public.ad_config; v_last timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into c from public.ad_config where id;
  if not c.enabled or c.ad_unit is null then raise exception 'Ads are switched off.'; end if;
  perform pg_advisory_xact_lock(hashtext('ad:' || auth.uid()::text));
  select max(viewed_at) into v_last from public.ad_views where player_id = auth.uid();
  if v_last is not null and v_last + make_interval(mins => c.cooldown_minutes) > now() then
    raise exception 'AD_COOLDOWN: next ad at %', to_char(v_last + make_interval(mins => c.cooldown_minutes), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;
  insert into public.ad_views (player_id) values (auth.uid());
  return public.ad_status();
end $$;
grant execute on function public.ad_reward_claim() to authenticated;

-- the gate itself: runs on every new registration the player makes for themselves (admin/host inserts and
-- re-registrations that update an existing row are not touched)
create or replace function public._ad_gate()
returns trigger language plpgsql security definer set search_path = public as $$
declare c public.ad_config; v_have int;
begin
  select * into c from public.ad_config where id;
  if not coalesce(c.enabled, false) or c.ad_unit is null then return new; end if;   -- off: nothing else runs
  if auth.uid() is null or new.player_id is distinct from auth.uid() then return new; end if;
  if coalesce(public.tournament_entry_npr(new.tournament_slug), 0) > 0 or public._ad_exempt(new.player_id) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext('ad:' || new.player_id::text));
  select count(*) into v_have from public.ad_views where player_id = new.player_id and used_for is null;
  if v_have < c.ads_needed then
    raise exception 'ADS_NEEDED: Watch % short ads to join free tournaments (% of % watched). Weekly Pass holders skip the ads.',
      c.ads_needed, v_have, c.ads_needed;
  end if;
  update public.ad_views set used_for = new.tournament_slug, used_at = now()
    where id in (select id from public.ad_views where player_id = new.player_id and used_for is null
                 order by viewed_at limit c.ads_needed);
  return new;
end $$;
drop trigger if exists registrations_ad_gate on public.registrations;
create trigger registrations_ad_gate before insert on public.registrations
  for each row execute function public._ad_gate();
