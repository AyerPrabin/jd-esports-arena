-- Undo event_modes_groups.sql. Squads already moved into a stage stay there: finish those events first.
drop trigger if exists reg_no_group_join on public.registrations;
drop function if exists public._reg_no_group_join();
select cron.unschedule('groups-auto');
drop function if exists public.event_draw_apply(jsonb, text[]);
drop function if exists public.event_end_waitlist(text);

create or replace function public._reg_saved_lineup() returns trigger
language plpgsql security definer set search_path = public as $$
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

create or replace function public._save_lineup_on_player() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lineup is not null and new.lineup_at is distinct from old.lineup_at then
    update public.players set squad_lineup = jsonb_build_object('squad', new.squad_name, 'members', new.lineup)
      where id = new.player_id;
  end if;
  return new;
end $$;

-- verify_my_squad: re-run the function from supabase/squad_verify.sql, then:
-- drop function if exists public._event_mode(text);
