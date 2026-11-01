-- ── Verify once (owner, 1 Nov 2026) ──
-- A squad verifies its line-up once: verify_my_squad() also saves it on the captain's account
-- (players.squad_lineup), and every later registration under the same squad name gets it copied in
-- automatically, so the ticket shows "Squad verified" with an Edit link instead of asking again.
-- Not copied when a UID in it is already in another squad's line-up for that event (then the ticket
-- asks as before). Safe to run again. Run after squad_verify.sql.
begin;

alter table public.players add column if not exists squad_lineup jsonb;   -- {"squad": "...", "members": [{name, uid}]}

-- new registration: copy the captain's saved line-up when it belongs to this squad
create or replace function public._reg_saved_lineup()
returns trigger language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if new.lineup is not null then return new; end if;
  select squad_lineup into v from public.players where id = new.player_id;
  if v is null or jsonb_typeof(v->'members') <> 'array'
     or lower(btrim(coalesce(v->>'squad', ''))) <> lower(btrim(coalesce(new.squad_name, ''))) then return new; end if;
  if exists(select 1 from public.registrations o, jsonb_array_elements(o.lineup) x, jsonb_array_elements(v->'members') y
              where o.tournament_slug = new.tournament_slug and o.player_id <> new.player_id
                and o.status in ('confirmed', 'approved', 'pending', 'waitlisted')
                and x->>'uid' = y->>'uid') then return new; end if;
  new.lineup := v->'members';
  new.lineup_at := now();
  return new;
end $$;
revoke all on function public._reg_saved_lineup() from public, anon, authenticated;
drop trigger if exists reg_saved_lineup on public.registrations;
create trigger reg_saved_lineup before insert on public.registrations
  for each row execute function public._reg_saved_lineup();

-- verifying (or editing) also saves the line-up on the account for next time
create or replace function public._save_lineup_on_player()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.lineup is not null and new.lineup_at is distinct from old.lineup_at then
    update public.players set squad_lineup = jsonb_build_object('squad', new.squad_name, 'members', new.lineup)
      where id = new.player_id;
  end if;
  return new;
end $$;
revoke all on function public._save_lineup_on_player() from public, anon, authenticated;
drop trigger if exists save_lineup_on_player on public.registrations;
create trigger save_lineup_on_player after update of lineup, lineup_at on public.registrations
  for each row execute function public._save_lineup_on_player();

-- squads that verified before this: keep their newest line-up on the account...
update public.players p set squad_lineup = jsonb_build_object('squad', r.squad_name, 'members', r.lineup)
from (select distinct on (player_id) player_id, squad_name, lineup from public.registrations
      where lineup is not null order by player_id, lineup_at desc) r
where p.id = r.player_id and p.squad_lineup is null;

-- ...and fill it into their other upcoming tickets for the same squad (no UID clash in that event)
update public.registrations g set lineup = p.squad_lineup->'members', lineup_at = now()
from public.players p
where g.player_id = p.id and g.lineup is null and p.squad_lineup is not null
  and g.status in ('confirmed', 'approved', 'pending', 'waitlisted')
  and lower(btrim(coalesce(g.squad_name, ''))) = lower(btrim(coalesce(p.squad_lineup->>'squad', '')))
  and not exists(select 1 from public.registrations o, jsonb_array_elements(o.lineup) x, jsonb_array_elements(p.squad_lineup->'members') y
                   where o.tournament_slug = g.tournament_slug and o.player_id <> g.player_id
                     and o.status in ('confirmed', 'approved', 'pending', 'waitlisted') and x->>'uid' = y->>'uid');

commit;
