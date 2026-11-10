-- 2026-11-10 Every refund tells the player WHY they got that amount (ZULU chat message), so they don't
-- need to ask a mod. Same trigger as before (zulu_on_ledger on wallet_ledger); only the refund text changes.
-- Rollback: re-run the zulu_on_ledger definition from zulu_auto.sql.
create or replace function public.zulu_on_ledger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_next text; v_k text; v_ev text; v_paid int; v_why text;
begin
  if new.reason = 'load' and new.delta > 0 then
    select t->>'name' into v_next
      from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
     where s.key = 'tournaments' and lower(coalesce(t->>'status', 'upcoming')) in ('upcoming', 'live', 'open')
       and coalesce(trim(t->>'winner'), '') = '' and public.tournament_start_at(t->>'name') > now()
     order by public.tournament_start_at(t->>'name') limit 1;
    perform public._zulu_say(new.player_id, 'load:' || new.id,
      '🪙 +' || new.delta || ' points loaded. Your balance is ' || new.balance_after || ' points.' ||
      coalesce(chr(10) || chr(10) || 'Next event: ' || v_next || ' (' || public._zulu_when(v_next) || '). Join it on Events.', ''), false);
  elsif new.reason = 'refund' and new.delta > 0 then
    v_k := split_part(coalesce(new.ref, ''), ':', 1);
    v_ev := coalesce(nullif(trim(new.note), ''), 'your event');
    if v_k = 'host_refund' then
      v_why := '100% back: the host cancelled "' || v_ev || '" (or it never finished). You lose nothing.' || chr(10) ||
               'Host le event cancel garyo, tesaile pura point firta.';
    elsif v_k = 'host_cancel_topup' then
      v_why := 'The rest of your entry for "' || v_ev || '": the host cancelled it, so the JD team made it 100% back.' || chr(10) ||
               'Host le cancel garyo, baki point pani firta.';
    elsif v_k = 'wl_refund' then
      v_why := '100% back: you were on the waitlist for "' || v_ev || '" and no seat opened for you. A waitlist deposit always comes back in full.' || chr(10) ||
               'Waitlist ma thiyo, slot khulena, tesaile pura firta.';
    elsif v_k = 'noshow_refund' then
      v_why := '100% back, but your squad was removed because nobody tapped "Confirm you''re playing" 24 hours before the start. Next time confirm on your ticket early.' || chr(10) ||
               'Confirm nagareko le slot hatyo, point pura firta.';
    elsif v_k = 'modrm' then
      v_why := '100% back: a JD mod removed your squad from "' || v_ev || '" before it started.' || chr(10) ||
               'Mod le squad hatayo, pura point firta.';
    elsif v_k = 'adminrefund' then
      v_why := 'Refund from the JD team: ' || v_ev || '.';
    elsif new.ref ~ '^[0-9a-f-]{36}$' then
      -- withdraw or lost place: the ref is the registration id, the same ref as its entry charge
      select -sum(delta)::int into v_paid from public.wallet_ledger
       where player_id = new.player_id and reason = 'entry' and ref = new.ref;
      if v_paid is not null and new.delta < v_paid then
        v_why := 'You paid ' || v_paid || ' and got ' || new.delta || ' back because you left "' || v_ev ||
                 '" less than 24 hours before the start. The rule: leave 24+ hours before = 100% back; leave in the last 24 hours = only 10% back, ' ||
                 'because your seat stayed blocked and no other squad could take it in time.' || chr(10) ||
                 'Match suru hunu bhanda 24 ghanta bhitra withdraw garda 10% matra firta hunchha. 24 ghanta agadi withdraw = 100% firta.';
      elsif v_paid is not null then
        v_why := '100% back from "' || v_ev || '": you left more than 24 hours before the start, or a waitlist squad took your place.' || chr(10) ||
                 'Pura point firta.';
      end if;
    end if;
    perform public._zulu_say(new.player_id, 'refund:' || new.id,
      '↩️ ' || new.delta || ' points refunded. Balance: ' || new.balance_after || ' points.' ||
      coalesce(chr(10) || chr(10) || v_why, ''), false);
  end if;
  return null;
exception when others then
  raise warning 'zulu_on_ledger: %', sqlerrm;
  return null;
end;
$$;
