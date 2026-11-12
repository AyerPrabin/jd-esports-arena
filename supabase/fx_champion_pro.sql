-- fx_champion_pro.sql (12 Nov 2026, owner): Champion (effect 'gold') is a Pro effect, no longer in the Rs 2
-- single-match set. Passes already holding it keep it until they end (8 active today). Site: home.js SQUAD_FX.
-- Run: npx supabase db query --remote --yes -f supabase/fx_champion_pro.sql
-- Undo: put 'gold' back in the 'game' list.
create or replace function public.fx_tier_ok(p_tier text, p_effect text)
returns boolean language sql immutable as $function$
  select case p_tier
    when 'lite' then p_effect in ('glow','steel')
    when 'game' then p_effect in ('fire','ice','neon','rainbow')
    when 'pro'  then p_effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend','bullets','blade',
      'skeuo','soft','glass','clay','brutal','mono','maximal','liquid','bento','spatial')
    else false end;
$function$;
