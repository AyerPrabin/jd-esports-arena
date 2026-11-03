-- Squad names, hardening (2026-11-03, from the automated security review of squad_names_reserved.sql):
--  * Look-alike names: reservation and the one-name-per-event rule compare a canonical key - NFKC (full-width
--    letters become normal ones), lower case, all spaces and invisible characters (zero-width, Hangul filler
--    U+3164, no-break space, ...) removed. "Youtz Esp", "ＹＯＵＴＺ　ＥＳＰ" and "Youtz\u200bEsp" are one name.
--  * Ownership of a result counts only a confirmed / approved entry made before that event's results were saved,
--    so an entry added afterwards can never claim someone's results, logo or name.
-- Safe to run again.
begin;

create or replace function public._squad_key(p text)
returns text language sql immutable set search_path = public as $$
  select regexp_replace(lower(normalize(coalesce(p, ''), NFKC)),
    '[[:space:]\u00a0\u00ad\u034f\u115f\u1160\u180e\u200b-\u200f\u2028-\u202f\u205f-\u206f\u3000\u3164\ufeff\uffa0]+', '', 'g')
$$;

create or replace function public._result_owner(p_slug text, p_name text)
returns uuid language sql stable security definer set search_path = public as $$
  select r.player_id from public.registrations r
  where r.tournament_slug = p_slug and lower(trim(r.squad_name)) = lower(trim(p_name))
    and r.status in ('confirmed', 'approved')
    and r.created_at <= coalesce((select min(tr.archived_at) from public.tournament_results tr where tr.tournament_slug = p_slug), now())
  order by r.created_at
  limit 1
$$;
revoke all on function public._result_owner(text, text) from public, anon, authenticated;

create or replace function public._has_season_results(p_player uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.registrations r
                join public.tournament_results tr on tr.tournament_slug = r.tournament_slug
                 and lower(trim(tr.squad_name)) = lower(trim(r.squad_name))
                where r.player_id = p_player and r.status in ('confirmed', 'approved') and r.created_at <= tr.archived_at)
$$;
revoke all on function public._has_season_results(uuid) from public, anon, authenticated;

create or replace function public._squad_name_reserved(p_name text, p_me uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.players p
                where p.id <> p_me and public._squad_key(p.squad_name) = public._squad_key(p_name)
                  and public._has_season_results(p.id))
$$;
revoke all on function public._squad_name_reserved(text, uuid) from public, anon, authenticated;

create or replace function public._reg_unique_squad()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.squad_name is null or new.status in ('rejected', 'no_show') then return new; end if;
  if public._squad_key(new.squad_name) = '' then raise exception 'Enter a squad name with real letters.'; end if;
  if tg_op = 'INSERT' or new.squad_name is distinct from old.squad_name then
    if public._squad_name_reserved(new.squad_name, new.player_id) then
      raise exception '"%" is another team''s name on the JD leaderboard. Ask that team''s captain to register, or pick another name.', trim(new.squad_name);
    end if;
  end if;
  if exists(select 1 from public.registrations r
            where r.tournament_slug = new.tournament_slug and r.id <> new.id and r.player_id <> new.player_id
              and r.status not in ('rejected', 'no_show')
              and public._squad_key(r.squad_name) = public._squad_key(new.squad_name)) then
    raise exception 'A squad called "%" is already in this event. Pick another name, or ask your captain to register the squad.', trim(new.squad_name);
  end if;
  return new;
end $$;

commit;
