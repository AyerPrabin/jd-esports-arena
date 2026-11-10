-- 2026-11-10 Best of 3: every open Best-of-3 event always has 3 different maps.
-- Runs on every save of site_content 'tournaments' (admin, mod-panel, hosts, ZULU commands).
-- A map the event already has is kept; 'random', empty, out-of-pool (Alpine) or repeated maps are rolled
-- from the maps not used yet. If a stale page re-saves 'random', the map stored before is kept, so
-- announced maps never change by themselves.
-- Rollback: drop trigger if exists site_content_bo3_maps on public.site_content; drop function if exists public._bo3_fill_maps();
begin;
create or replace function public._bo3_fill_maps() returns trigger
language plpgsql set search_path = public as $$
declare
  pool constant text[] := array['bermuda','purgatory','kalahari','nexterra','solara'];
  v_out jsonb := '[]'::jsonb; t jsonb; o jsonb; m text[]; prev text[]; used text[]; k text; i int;
begin
  if new.key <> 'tournaments' or jsonb_typeof(new.content->'tournaments') is distinct from 'array' then return new; end if;
  for t in select x from jsonb_array_elements(new.content->'tournaments') with ordinality a(x, n) order by n loop
    if coalesce(t->>'format', '') ilike '%best of 3%' and coalesce(t->>'image', '') = ''
       and lower(coalesce(t->>'status', 'upcoming')) not in ('completed', 'cancelled') and coalesce(trim(t->>'winner'), '') = '' then
      m := array[lower(coalesce(t->>'map', '')), lower(coalesce(t->>'map2', '')), lower(coalesce(t->>'map3', ''))];
      prev := array['', '', ''];
      if tg_op = 'UPDATE' then
        select x into o from jsonb_array_elements(old.content->'tournaments') x where x->>'name' = t->>'name' limit 1;
        if o is not null then
          prev := array[lower(coalesce(o->>'map', '')), lower(coalesce(o->>'map2', '')), lower(coalesce(o->>'map3', ''))];
        end if;
      end if;
      used := '{}';
      for i in 1..3 loop
        k := m[i];
        if not (k = any(pool)) or k = any(used) then
          k := case when prev[i] = any(pool) and not prev[i] = any(used) and not prev[i] = any(m[i + 1:3]) then prev[i] end;
        end if;
        if k is null or not (k = any(pool)) or k = any(used) then
          select p into k from unnest(pool) p where not p = any(used) and not p = any(m[i + 1:3]) order by random() limit 1;
          if k is null then select p into k from unnest(pool) p where not p = any(used) order by random() limit 1; end if;
        end if;
        m[i] := k; used := used || k;
      end loop;
      t := t || jsonb_build_object('map', m[1], 'map2', m[2], 'map3', m[3]);
    end if;
    v_out := v_out || jsonb_build_array(t);
  end loop;
  new.content := jsonb_set(new.content, '{tournaments}', v_out);
  return new;
end $$;

drop trigger if exists site_content_bo3_maps on public.site_content;
create trigger site_content_bo3_maps before insert or update of content on public.site_content
  for each row execute function public._bo3_fill_maps();

-- roll the events that are open now
update public.site_content set content = content where key = 'tournaments';
commit;

select x->>'name' n, x->>'map' m1, x->>'map2' m2, x->>'map3' m3
  from public.site_content, jsonb_array_elements(content->'tournaments') x
 where key = 'tournaments' and x->>'format' ilike '%best of 3%' and coalesce(x->>'status', 'upcoming') not in ('completed', 'cancelled');
