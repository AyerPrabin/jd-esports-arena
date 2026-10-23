-- Host mods' events (tournaments.json "host" field, mod_roles.sql) are run by the invited host: JD never pays
-- their prizes. award_prizes() skips them; everything else is the live definition unchanged.
create or replace function public.award_prizes(p_slug text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_doc jsonb;
  t jsonb;
  v_slug text;
  v_out jsonb := '[]'::jsonb;
  r record;
  v_amt int;
begin
  select content into v_doc from public.site_content where key = 'tournaments';
  if v_doc is null then
    return v_out;
  end if;
  for t in select value from jsonb_array_elements(coalesce(v_doc->'tournaments', '[]'::jsonb)) loop
    v_slug := t->>'name';
    continue when v_slug is null or (p_slug is not null and v_slug <> p_slug);
    continue when coalesce(trim(t->>'host'), '') <> '';   -- a host mod's event: not JD's prize money
    perform pg_advisory_xact_lock(hashtext('prize:' || v_slug));
    if exists(select 1 from public.tournament_results where tournament_slug = v_slug and prize_won > 0) then
      for r in select squad_name, floor(prize_won)::int amt from public.tournament_results
               where tournament_slug = v_slug and prize_won > 0 loop
        v_out := v_out || jsonb_build_array(public._award_one(v_slug, r.squad_name, r.amt) || jsonb_build_object('tournament', v_slug));
      end loop;
    elsif v_doc->'bo3'->>'tournament' = v_slug and coalesce((v_doc->'bo3'->>'published')::boolean, false)
          and exists(select 1 from jsonb_array_elements(coalesce(v_doc->'bo3'->'teams','[]'::jsonb)) x
                     where coalesce(nullif(regexp_replace(x->>'prize_won','[^0-9.]','','g'),''),'0')::numeric > 0) then
      for r in select x->>'team' squad, floor(nullif(regexp_replace(x->>'prize_won','[^0-9.]','','g'),'')::numeric)::int amt
               from jsonb_array_elements(v_doc->'bo3'->'teams') x
               where coalesce(nullif(regexp_replace(x->>'prize_won','[^0-9.]','','g'),''),'0')::numeric > 0 loop
        v_out := v_out || jsonb_build_array(public._award_one(v_slug, r.squad, r.amt) || jsonb_build_object('tournament', v_slug));
      end loop;
    elsif coalesce(trim(t->>'winner'), '') <> '' then
      v_amt := nullif(replace(substring(coalesce(t->>'prize', '') from '[0-9][0-9,]*'), ',', ''), '')::int;
      if v_amt is not null and v_amt > 0 then
        v_out := v_out || jsonb_build_array(public._award_one(v_slug, trim(t->>'winner'), v_amt) || jsonb_build_object('tournament', v_slug));
      end if;
    end if;
  end loop;
  return v_out;
end;
$function$;
revoke all on function public.award_prizes(text) from public, anon, authenticated;
grant execute on function public.award_prizes(text) to service_role;
