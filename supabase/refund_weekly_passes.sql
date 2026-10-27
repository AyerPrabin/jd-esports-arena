-- ── Refund + cancel every Weekly Pass (owner, 27 Oct 2026) ──
-- Each pass gets back what was actually charged for it (wallet 'pass' rows), minus anything already refunded for it
-- (TEAM TIGER's 50 was refunded earlier as passprizefix:...). The pass and its squad effect end now (rows kept for
-- history: expires_at = starts_at, the same way upgrades end a pass). Idempotent: ref passrefund:<id>.
begin;
do $$
declare
  r record;
  v_charged int;
  v_already int;
  v_amt int;
begin
  for r in select wp.*, p.squad_name from public.weekly_passes wp join public.players p on p.id = wp.player_id
           where wp.expires_at > wp.starts_at order by wp.id loop
    if exists (select 1 from public.wallet_ledger where ref = 'passrefund:' || r.id) then continue; end if;
    select coalesce(sum(-delta), 0) into v_charged from public.wallet_ledger
      where player_id = r.player_id and reason = 'pass' and (ref = r.ref or ref like r.ref || ':%');
    if v_charged = 0 then v_charged := r.price; end if;
    select coalesce(sum(delta), 0) into v_already from public.wallet_ledger
      where player_id = r.player_id and reason = 'refund' and ref like 'passprizefix:%'
        and r.ref like 'passprize:%' and ref like 'passprizefix:' || substr(r.ref, 11) || '%';
    v_amt := greatest(v_charged - v_already, 0);
    if v_amt > 0 then
      perform public._wallet_apply(r.player_id, v_amt, 'refund', 'passrefund:' || r.id,
        case r.tier when 'pro' then 'Weekly Pro refunded' else 'Weekly Pass refunded' end);
    end if;
    update public.weekly_passes set expires_at = starts_at where id = r.id;
    if r.ref is not null then
      update public.effect_passes set expires_at = least(expires_at, greatest(starts_at, now())) where code = r.ref;
    end if;
    insert into public.notifications (player_id, title, body) values (r.player_id,
      '💸 Weekly Pass refunded',
      case when v_amt > 0 then v_amt || ' points are back in your wallet. ' else 'Your points were already returned. ' end
      || 'Weekly Passes are cancelled - free JD tournaments stay free to join.');
  end loop;
end $$;

-- stacked passes that had not started yet: end them now too (otherwise expires_at = starts_at is still in the future)
update public.weekly_passes wp set starts_at = least(wp.starts_at, now()), expires_at = least(wp.starts_at, now())
 where exists (select 1 from public.wallet_ledger l where l.ref = 'passrefund:' || wp.id) or wp.ref like 'passprize:%';
update public.effect_passes e set starts_at = least(e.starts_at, now()), expires_at = least(e.starts_at, now())
 where e.code in (select ref from public.weekly_passes where ref is not null) and e.expires_at > now();
commit;
