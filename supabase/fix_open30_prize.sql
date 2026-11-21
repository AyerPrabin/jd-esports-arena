-- fix_open30_prize.sql (21 Nov 2026)
-- 1) JD Free Fire Open #30 (prize 175): award_prizes paid ALL 175 to the winner PARAGON E-SPORTS (PE_ROCKY) at 11:07 UTC,
--    because the event had a winner but no per-squad prizes (old "winner takes all" fallback). Correct split 50/30/20:
--    PARAGON 88 (take back 87), WeNvrDie 52, leghey Esp 35. Ranks from the board: 83 / 56 / 40 points.
-- 2) award_prizes fallback now pays the winner only the 1st-place share (50%), never the whole pool.
-- 3) admin_wallet_remove(): Admin > Wallet "Remove points" (never below 0, always notifies the player).
-- Safe to re-run: every step checks its ledger ref first.
-- Run: npx supabase db query --remote --yes -f supabase/fix_open30_prize.sql
begin;
select pg_advisory_xact_lock(hashtext('prize:JD Free Fire Open #30'));

-- 1) Open #30 ------------------------------------------------------------------------------------------------------
do $$
declare v_rocky uuid; v_slug text := 'JD Free Fire Open #30'; v_ref text := 'undo:prize:JD Free Fire Open #30:paragon e-sports:extra';
begin
  select player_id into v_rocky from public.wallet_ledger where reason = 'prize' and ref = 'prize:' || v_slug || ':paragon e-sports' and delta = 175;
  if v_rocky is not null and not exists (select 1 from public.wallet_ledger where ref = v_ref) then
    perform public._wallet_apply(v_rocky, -87, 'adjust', v_ref, v_slug || ': prize fixed to 88 (1st of 50/30/20), 175 was paid by mistake');
    insert into public.notifications (player_id, tournament_slug, title, body) values (v_rocky, v_slug, 'Prize corrected: 88 points',
      'Open #30''s prize is split 88 / 52 / 35 for 1st, 2nd and 3rd. Our system paid PARAGON E-SPORTS the full 175 by mistake, so 87 points were taken back. You keep 88 for 1st place. Congratulations and sorry for the mix-up!');
  end if;
  perform public._award_one(v_slug, 'WeNvrDie', 52);     -- 2nd: pays once, notifies the captain
  perform public._award_one(v_slug, 'leghey Esp', 35);   -- 3rd
end $$;

insert into public.tournament_results (tournament_slug, squad_name, placement, kills, points, prize_won) values
  ('JD Free Fire Open #30', 'PARAGON E-SPORTS', 1, 51, 83, 88),
  ('JD Free Fire Open #30', 'WeNvrDie',         2, 35, 56, 52),
  ('JD Free Fire Open #30', 'leghey Esp',       3, 23, 40, 35)
on conflict (tournament_slug, squad_name) do update
  set placement = excluded.placement, kills = excluded.kills, points = excluded.points, prize_won = excluded.prize_won;

-- prize boxes on the live board, if #30 is still on it
update public.site_content set content = jsonb_set(content, '{bo3,teams}',
  (select jsonb_agg(case x->>'team' when 'PARAGON E-SPORTS' then x || '{"prize_won":"88"}'
                                    when 'WeNvrDie' then x || '{"prize_won":"52"}'
                                    when 'leghey Esp' then x || '{"prize_won":"35"}' else x end order by o)
     from jsonb_array_elements(content->'bo3'->'teams') with ordinality e(x, o)))
 where key = 'tournaments' and content->'bo3'->>'tournament' = 'JD Free Fire Open #30';

-- 2) award_prizes: no more winner-takes-all -----------------------------------------------------------------------
create or replace function public.award_prizes(p_slug text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
      -- only a winner is known: pay the 1st-place share of 50/30/20 (2nd/3rd come from Mod > Finish & pay prizes)
      v_amt := nullif(replace(substring(coalesce(t->>'prize', '') from '[0-9][0-9,]*'), ',', ''), '')::int;
      if v_amt is not null and v_amt > 0 then
        v_amt := v_amt - floor(v_amt * 0.3)::int - round(v_amt * 0.2)::int;
        v_out := v_out || jsonb_build_array(public._award_one(v_slug, trim(t->>'winner'), v_amt) || jsonb_build_object('tournament', v_slug));
      end if;
    end if;
  end loop;
  return v_out;
end;
$$;

-- 3) Admin > Wallet "Remove points" ---------------------------------------------------------------------------------
create or replace function public.admin_wallet_remove(p_player uuid, p_amount int, p_note text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_bal int; v_note text := nullif(left(trim(coalesce(p_note, '')), 200), '');
begin
  if p_amount is null or p_amount < 1 or p_amount > 100000 then raise exception 'Enter how many points to remove.'; end if;
  if v_note is null then raise exception 'Write why the points are removed: the player sees it.'; end if;
  if (select balance from public.wallets where player_id = p_player) < p_amount then
    raise exception 'The player has only % points. Remove at most that.', (select balance from public.wallets where player_id = p_player);
  end if;
  v_bal := public._wallet_apply(p_player, -p_amount, 'adjust', 'remove:' || replace(gen_random_uuid()::text, '-', ''), v_note);
  insert into public.notifications (player_id, title, body) values (p_player, '-' || p_amount || ' JD points',
    p_amount || ' points were removed from your wallet by the JD admin. Reason: ' || v_note || '. Balance: ' || v_bal || ' points. Questions? Message JD in chat.');
  return v_bal;
end;
$$;
revoke all on function public.admin_wallet_remove(uuid, int, text) from public, anon, authenticated;

select l.ref, l.delta, l.balance_after from public.wallet_ledger l
 where l.ref like 'prize:JD Free Fire Open #30:%' or l.ref like 'undo:prize:JD Free Fire Open #30:%' order by l.created_at;
commit;
