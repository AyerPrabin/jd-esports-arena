-- Audit fixes 2026-10-29. NOT applied yet: run in the Supabase SQL editor (or `supabase db query --linked -f`).
-- Safe to run twice. Nothing here changes balances, registrations or existing rows.

-- 1. Same eSewa screenshot sent twice (or someone else's screenshot reused) -------------------------------------
-- request_wallet_load accepted any screenshot, so one real payment could be submitted again and, if the admin
-- missed it, credited twice. Each request now stores the SHA-256 of the image bytes, and a screenshot that is
-- already pending or approved is refused. (A re-saved/cropped copy has different bytes - see recommendation R3:
-- also ask for the eSewa transaction code and make that unique.)
alter table public.wallet_load_requests add column if not exists screenshot_sha text;

create or replace function public._load_screenshot_sha()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.screenshot is not null then
    new.screenshot_sha := encode(sha256(decode(split_part(new.screenshot, ',', 2), 'base64')), 'hex');
    perform pg_advisory_xact_lock(hashtext('load-shot:' || new.screenshot_sha));   -- two identical uploads at once
    if exists(select 1 from public.wallet_load_requests
              where screenshot_sha = new.screenshot_sha and status in ('pending', 'approved')
                and id is distinct from new.id) then
      raise exception 'This payment screenshot was already sent. Each eSewa payment can be used once.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists wallet_load_screenshot_sha on public.wallet_load_requests;
create trigger wallet_load_screenshot_sha before insert on public.wallet_load_requests
  for each row execute function public._load_screenshot_sha();

create index if not exists wallet_load_requests_sha on public.wallet_load_requests (screenshot_sha);

-- Back-fill old requests so the admin can spot past duplicates:
--   select screenshot_sha, count(*), array_agg(player_id), array_agg(status) from public.wallet_load_requests
--   group by 1 having count(*) > 1;
update public.wallet_load_requests
  set screenshot_sha = encode(sha256(decode(split_part(screenshot, ',', 2), 'base64')), 'hex')
  where screenshot_sha is null and screenshot like 'data:image/%;base64,%';

-- 2. Hygiene: trigger / event-trigger functions should not be callable through the API -------------------------
-- (Postgres already refuses to run them outside a trigger, so this closes no live hole - it shrinks the API.)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype) loop
    execute format('revoke execute on function %s from anon, authenticated, public', f.sig);
  end loop;
end $$;

-- Check afterwards (expect 0 rows):
--   select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
--     and has_function_privilege('anon', p.oid, 'EXECUTE');

-- 3. Double refund when "withdraw" is tapped twice at the same moment -------------------------------------------
-- withdraw_registration read the registration without a lock and refunded without checking that its DELETE
-- removed a row, so two parallel calls could both refund (points that can then be withdrawn to eSewa).
-- Not seen in the ledger so far (12 refunds, 12 distinct refs on 2026-10-29). Now: the row is locked, the refund
-- only follows a delete that really happened, and the database refuses a second refund with the same ref.
create or replace function public.withdraw_registration(p_tournament_slug text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_reg public.registrations;
  v_start timestamptz;
  v_late boolean := false;
  v_refund int := 0;
  v_deleted uuid;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  select * into v_reg from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid()
    for update;
  if v_reg.id is null then
    raise exception 'You are not registered for this tournament.';
  end if;
  v_start := public.tournament_start_at(p_tournament_slug);
  if v_start is not null and v_start <= now() then
    raise exception 'This match has already started, so squads can no longer withdraw.';
  end if;
  if exists(select 1 from public.tournament_room_codes where tournament_slug = p_tournament_slug and sent_at is not null) then
    raise exception 'The room details have been released, so squads can no longer withdraw.';
  end if;
  v_late := v_start is not null and v_start - now() < interval '24 hours';
  if v_reg.paid_points > 0 then
    v_refund := case when v_late then floor(v_reg.paid_points * 0.1)::int else v_reg.paid_points end;
  end if;
  delete from public.registrations where id = v_reg.id returning id into v_deleted;
  if v_deleted is null then
    raise exception 'You are not registered for this tournament.';
  end if;
  if v_refund > 0 then
    perform public._wallet_apply(auth.uid(), v_refund, 'refund', v_reg.id::text, p_tournament_slug);
  end if;
  return jsonb_build_object('refund', v_refund, 'late', v_late, 'paid_points', v_reg.paid_points);
end;
$function$;

create unique index if not exists wallet_ledger_refund_ref on public.wallet_ledger (ref) where reason = 'refund';
