-- Owner request 2026-10-27 (evening): undo the #10/#11 reset (reset_10_11_ads.sql) and make the ad rule start
-- from JD Free Fire Open #12. The removed rows are gone, so they are rebuilt from the "join again" notices the
-- reset sent (player + event) and each squad's original "Registered" ticket notice (original join time).
-- Status is re-derived the way register_for_tournament does it: the first 12 by join time are confirmed, the
-- rest waitlisted - this matches the line-up before the reset (12 + Fox Esport waiting in #10, 12 + 6 in #11).
-- Squads that already joined again are left as they are. One transaction.
begin;

-- 1. Ads only from Open #12 on: older Open events never ask for ads (other free events still do).
alter table public.ad_config add column if not exists from_open int not null default 12;

create or replace function public._ad_event_free_of_ads(p_slug text)
returns boolean language sql stable set search_path = public as $$
  select coalesce((substring(p_slug from '^JD Free Fire Open #(\d+)$'))::int
                  < (select from_open from public.ad_config where id), false);
$$;

create or replace function public._ad_gate()
returns trigger language plpgsql security definer set search_path = public as $$
declare c public.ad_config; v_have int;
begin
  select * into c from public.ad_config where id;
  if not coalesce(c.enabled, false) or c.ad_unit is null then return new; end if;   -- off: nothing else runs
  if auth.uid() is null or new.player_id is distinct from auth.uid() then return new; end if;
  if coalesce(public.tournament_entry_npr(new.tournament_slug), 0) > 0 or public._ad_exempt(new.player_id)
     or public._ad_event_free_of_ads(new.tournament_slug) then
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

-- 2. Put the removed squads back.
create temporary table _back on commit drop as
  select distinct on (j.player_id, j.tournament_slug) j.player_id, j.tournament_slug, p.squad_name,
         coalesce((select min(n.created_at) from public.notifications n
                    where n.player_id = j.player_id and n.tournament_slug = j.tournament_slug
                      and n.title like '%Registered: %' and n.created_at < j.created_at), j.created_at) as joined_at,
         (select r.whatsapp from public.registrations r where r.player_id = j.player_id and coalesce(r.whatsapp, '') <> ''
           order by r.created_at desc limit 1) as whatsapp
    from public.notifications j join public.players p on p.id = j.player_id
   where j.title like '🔄 %: join again'
     and j.tournament_slug in ('JD Free Fire Open #10', 'JD Free Fire Open #11')
     and not exists (select 1 from public.registrations r where r.player_id = j.player_id and r.tournament_slug = j.tournament_slug);

create temporary table _ranked on commit drop as
  select b.*, row_number() over (partition by b.tournament_slug order by b.joined_at) as pos
    from (select player_id, tournament_slug, squad_name, joined_at, whatsapp from _back
          union all   -- squads that rejoined keep their slot and count toward the 12, at their original join time
          select r.player_id, r.tournament_slug, r.squad_name,
                 coalesce((select min(n.created_at) from public.notifications n where n.player_id = r.player_id
                            and n.tournament_slug = r.tournament_slug and n.title like '%Registered: %'), r.created_at), null
            from public.registrations r
           where r.tournament_slug in ('JD Free Fire Open #10', 'JD Free Fire Open #11')
             and r.status in ('confirmed', 'approved')) b;

insert into public.registrations (tournament_slug, player_id, squad_name, status, device_type, whatsapp, created_at)
select k.tournament_slug, k.player_id, k.squad_name,
       case when k.pos <= coalesce(c.slots, 12) then 'confirmed' else 'waitlisted' end,
       'mobile', k.whatsapp, k.joined_at
  from _ranked k join _back b using (player_id, tournament_slug)
  left join public.tournament_capacity c on c.tournament_slug = k.tournament_slug
 order by k.tournament_slug, k.pos;

-- 3. Tell them, and clear the "join again" notices so nobody re-watches ads for a slot they already have.
delete from public.notifications n using _back b
 where n.player_id = b.player_id and n.tournament_slug = b.tournament_slug and n.title like '🔄 %: join again';

insert into public.notifications (player_id, tournament_slug, title, body, push)
select r.player_id, r.tournament_slug, '✅ ' || r.tournament_slug || ': your slot is back',
       'Sorry about last night - ' || r.squad_name || ' is back in ' || r.tournament_slug
       || case when r.status = 'waitlisted' then ' on the waitlist (same place as before)' else '' end
       || '. No ads needed for this event - ads only start from JD Free Fire Open #12.', true
  from public.registrations r join _back b using (player_id, tournament_slug);

select tournament_slug, status, count(*) from public.registrations
 where tournament_slug in ('JD Free Fire Open #10', 'JD Free Fire Open #11') group by 1, 2 order by 1, 2;
commit;
