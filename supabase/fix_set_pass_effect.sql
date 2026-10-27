-- ── set_pass_effect: "query returned more than one row" when a player has 2+ active effect passes (28 Oct 2026) ──
-- UPDATE ... RETURNING INTO a single row failed; now every active pass that allows the effect switches to it and the
-- longest-running one is returned.
create or replace function public.set_pass_effect(p_effect text)
 returns public.effect_passes language plpgsql security definer set search_path to 'public'
as $function$
declare v_pass public.effect_passes;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  with u as (
    update public.effect_passes set effect = p_effect
      where player_id = auth.uid() and starts_at <= now() and expires_at > now() and public.fx_tier_ok(tier, p_effect)
      returning *)
  select * into v_pass from u order by expires_at desc limit 1;
  if v_pass.id is null then
    raise exception 'Your current pass does not include that effect.';
  end if;
  return v_pass;
end;
$function$;
