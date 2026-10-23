-- JD-Optimiers v5.7 server side (2026-10-24).
--  * One linked PC = one machine: the app sends a hash of the PC's machine id with every check. The first one
--    binds the device; a copied device token on another PC gets status 'moved'. Once bound, a check without
--    the hash (an older or patched app) gets 'update'. Older apps on not-yet-bound devices keep working, so the
--    v5.7 update (forced by latest.json) never locks anyone out.
--  * Anonymous stats: at most 30 summaries a day per linked PC (the per-anon_id limit alone could be dodged by
--    sending a new random id each time). The counter table holds no anon_id, so rows stay unlinkable.
--  * optimizer_my_sessions(): the player's own session history (optimizer_pc_history) for the profile page.
--  * optimizer_peer_tips(): what works best on the same graphics card, from every player's private PC reports,
--    only as medians and only once 2+ players / 6+ sessions exist for that card.
begin;

alter table public.optimizer_devices add column if not exists machine_hash text;

drop function if exists public.optimizer_check(text);
create or replace function public.optimizer_check(p_token text, p_machine text default null)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  d public.optimizer_devices;
  p public.optimizer_plans;
  v_user text;
  v_plan_end timestamptz;
  v_pass_end timestamptz;
  v_end timestamptz;
  v_reason text;
begin
  select * into d from public.optimizer_devices where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
  if not found then return jsonb_build_object('status', 'revoked'); end if;
  if p_machine is not null and p_machine !~ '^[0-9a-f]{64}$' then return jsonb_build_object('status', 'revoked'); end if;
  if d.machine_hash is not null and p_machine is null then
    return jsonb_build_object('status', 'update', 'reason', 'This JD-Optimiers is too old - update it from jdesport.co.uk/optimizer.');
  end if;
  if d.machine_hash is not null and d.machine_hash <> p_machine then
    return jsonb_build_object('status', 'moved', 'reason', 'This sign-in belongs to another PC. Sign in again on this PC.');
  end if;
  update public.optimizer_devices set last_seen = now(), machine_hash = coalesce(machine_hash, p_machine) where id = d.id;
  select coalesce(username, player_tag) into v_user from public.players where id = d.player_id;
  if exists(select 1 from public.banned_players where player_id = d.player_id) then
    return jsonb_build_object('status', 'no_plan', 'username', v_user, 'reason', 'banned', 'server_time', now());
  end if;
  select * into p from public.optimizer_plans where player_id = d.player_id and expires_at > now();
  if found and public._optimizer_pass_ok(d.player_id) then
    return jsonb_build_object('status', 'ok', 'tier', p.tier, 'expires_at', p.expires_at, 'username', v_user,
                              'server_time', now(), 'fps_cap', p.fps_cap);
  end if;

  select max(expires_at) into v_plan_end from public.optimizer_plans where player_id = d.player_id;
  if p.player_id is null then
    v_reason := 'no_plan';
    v_end := v_plan_end;                                  -- null: never had a plan -> nothing to remove
  else
    v_reason := 'no_pass';
    select greatest(max(expires_at), timestamptz '2026-10-27 00:00:00+05:45') into v_pass_end
      from public.weekly_passes where player_id = d.player_id and expires_at <= now();
    v_end := coalesce(v_pass_end, timestamptz '2026-10-27 00:00:00+05:45');
  end if;
  return jsonb_build_object('status', 'no_plan', 'reason', v_reason, 'username', v_user, 'server_time', now(),
                            'ended_at', v_end,
                            -- never earlier than 3 days after v5.6 went out, so every player sees the warning first
                            'grace_ends', case when v_end is null then null   -- greatest() would skip the null
                                         else greatest(v_end, timestamptz '2026-10-24 00:00:00+00') + interval '3 days' end);
end;
$function$;
revoke all on function public.optimizer_check(text, text) from public;
grant execute on function public.optimizer_check(text, text) to anon, authenticated, service_role;

-- anonymous stats: a per-PC daily counter (no anon_id in it)
create table if not exists public.optimizer_share_rate (
  device_id uuid not null references public.optimizer_devices(id) on delete cascade,
  day date not null,
  n int not null default 0,
  primary key (device_id, day)
);
alter table public.optimizer_share_rate enable row level security;

create or replace function public.optimizer_share_session(p_token text, p_anon text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare v_dev uuid; v_n int;
begin
  select id into v_dev from public.optimizer_devices where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
  if v_dev is null then raise exception 'This PC is not linked.'; end if;
  if p_anon !~ '^[0-9a-f]{32}$' or jsonb_typeof(p_data) <> 'object' or length(p_data::text) > 4000 then raise exception 'Bad stats.'; end if;
  insert into public.optimizer_share_rate as r (device_id, day, n) values (v_dev, current_date, 1)
  on conflict (device_id, day) do update set n = r.n + 1 returning n into v_n;
  if v_n > 30 or (select count(*) from public.optimizer_sessions where anon_id = p_anon and created_at > now() - interval '1 day') >= 30 then
    return jsonb_build_object('saved', false, 'reason', 'daily limit');
  end if;
  delete from public.optimizer_share_rate where day < current_date - 2;
  insert into public.optimizer_sessions (anon_id, data) values (p_anon, p_data);
  return jsonb_build_object('saved', true);
end;
$function$;

-- the player's own sessions, newest first (profile page)
create or replace function public.optimizer_my_sessions(p_limit int default 30)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'pc', (select r.pc from public.optimizer_pc_reports r where r.player_id = auth.uid() order by r.updated_at desc limit 1),
    'sessions', coalesce((select jsonb_agg(jsonb_build_object('at', h.created_at, 's', h.data) order by h.created_at desc)
       from (select * from public.optimizer_pc_history where player_id = auth.uid() order by created_at desc
             limit least(greatest(coalesce(p_limit, 30), 1), 100)) h), '[]'::jsonb)) end;
$$;
revoke all on function public.optimizer_my_sessions(int) from public, anon;
grant execute on function public.optimizer_my_sessions(int) to authenticated;

-- what works on the same graphics card (medians only, never a single player's numbers)
create or replace function public.optimizer_peer_tips(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $function$
declare v_player uuid; v_gpu text; v_out jsonb;
begin
  select player_id into v_player from public.optimizer_devices where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
  if v_player is null then return null; end if;
  select r.last_session->>'hw_gpu' into v_gpu from public.optimizer_pc_reports r where r.player_id = v_player order by r.updated_at desc limit 1;
  if coalesce(v_gpu, '') = '' then return null; end if;
  with s as (
    select h.player_id, h.data->>'renderer' renderer, (h.data->>'cap')::int cap,
           (h.data->>'fps')::numeric fps, (h.data->>'low1')::numeric low1
    from public.optimizer_pc_history h
    where h.data->>'hw_gpu' = v_gpu and (h.data->>'fps') ~ '^[0-9.]+$' and (h.data->>'low1') ~ '^[0-9.]+$'
      and (h.data->>'cap') ~ '^[0-9]+$' and h.created_at > now() - interval '60 days'),
  g as (
    select renderer, cap, count(*) n, count(distinct player_id) players,
           percentile_cont(0.5) within group (order by fps) fps, percentile_cont(0.5) within group (order by low1) low1
    from s group by renderer, cap having count(*) >= 3)
  select jsonb_build_object('gpu', v_gpu,
           'players', (select count(distinct player_id) from s), 'sessions', (select count(*) from s),
           'best', (select jsonb_build_object('renderer', renderer, 'cap', cap, 'fps', round(fps::numeric, 1), 'low1', round(low1::numeric, 1), 'sessions', n)
                    from g order by low1 desc, fps desc limit 1))
    into v_out;
  if (v_out->>'players')::int < 2 or (v_out->>'sessions')::int < 6 or v_out->'best' is null then return null; end if;
  return v_out;
end;
$function$;
revoke all on function public.optimizer_peer_tips(text) from public;
grant execute on function public.optimizer_peer_tips(text) to anon, authenticated;

commit;
