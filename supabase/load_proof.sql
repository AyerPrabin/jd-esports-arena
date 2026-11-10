-- load_proof.sql (10 Nov 2026): owner: "ask for the reference number of the eSewa and from which id the money was
-- sent ... make load very automatic, fast, effective" and "screenshot duplication prevention ... same reference".
-- Found the same day: one player was credited 80 points for 2 x Rs 15 (one payment sent twice as a photo of the
-- screen, one sent as Rs 50). Fixes:
--   * Every load now needs the eSewa Transaction Code (e.g. 1VDLJI9) and the sender's eSewa name.
--   * A transaction code can be used ONCE (unique, pending or approved), so a photo / crop / re-save of the same
--     payment is refused even when the image bytes differ.
--   * AUTO-APPROVE: when the JD phone's "You have received NPR X from NAME" alert (payments_in) has the same amount and
--     the same sender name as the request, within the usual window (paid up to 3 h before, or 30 min after), and it
--     is the only fit, the points are added at once. Works in both orders (alert first or request first).
--     Anything else waits for the admin as before.
-- Run: npx supabase db query --remote --yes -f supabase/load_proof.sql   (then merge the load-proof branch at once:
--      the old page doesn't send the code, so loads from it are refused until the new page is live)
-- Undo: drop trigger load_auto_on_payment on public.payments_in; drop trigger load_auto_on_request on public.wallet_load_requests;
--       drop function public.request_wallet_load(integer, text, text, text, text); then re-create the old 3-argument one.

alter table public.wallet_load_requests add column if not exists esewa_code text, add column if not exists sender_name text;
create unique index if not exists wallet_load_requests_code on public.wallet_load_requests (upper(esewa_code))
  where esewa_code is not null and status <> 'rejected';

-- "Jilani in your eSewa account" / " jilani " -> "jilani"
create or replace function public._pay_name(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select nullif(lower(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '\s+in your e-?sewa account.*$', '', 'i'), '\s+', ' ', 'g'))), '');
$$;

create or replace function public._load_try_auto(p_load uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare r public.wallet_load_requests; pay public.payments_in; n int;
begin
  select * into r from public.wallet_load_requests where id = p_load for update;
  if r.id is null or r.status <> 'pending' or public._pay_name(r.sender_name) is null then return false; end if;
  select count(*) into n from public.payments_in p
   where p.load_id is null and p.matched_at is null and p.amount = r.amount
     and p.received_at between r.created_at - interval '3 hours' and r.created_at + interval '30 minutes'
     and public._pay_name(p.sender) = public._pay_name(r.sender_name);
  if n <> 1 then return false; end if;
  -- another waiting request with the same amount and name could be the real owner of this payment: admin decides
  if exists (select 1 from public.wallet_load_requests q where q.id <> r.id and q.status = 'pending' and q.amount = r.amount
               and public._pay_name(q.sender_name) = public._pay_name(r.sender_name)) then return false; end if;
  select * into pay from public.payments_in p
   where p.load_id is null and p.matched_at is null and p.amount = r.amount
     and p.received_at between r.created_at - interval '3 hours' and r.created_at + interval '30 minutes'
     and public._pay_name(p.sender) = public._pay_name(r.sender_name)
   for update;
  update public.payments_in set load_id = r.id, matched_by = 'auto: amount + eSewa name', matched_at = now() where id = pay.id;
  perform public.admin_resolve_load(r.id, true, r.amount,
    'Auto: eSewa Rs ' || pay.amount || ' from ' || coalesce(public._pay_name(pay.sender), '?') || ' at '
    || to_char(pay.received_at at time zone 'Asia/Kathmandu', 'DD Mon HH24:MI') || ', code ' || coalesce(r.esewa_code, '-'));
  return true;
exception when others then
  return false;   -- never break a request or a payment alert: it just waits for the admin
end;
$$;
revoke all on function public._load_try_auto(uuid) from public, anon, authenticated;

create or replace function public._load_auto_on_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public._load_try_auto(new.id); return null; end $$;
drop trigger if exists load_auto_on_request on public.wallet_load_requests;
create trigger load_auto_on_request after insert on public.wallet_load_requests
  for each row execute function public._load_auto_on_request();

create or replace function public._load_auto_on_payment()
returns trigger language plpgsql security definer set search_path = public as $$
declare q record;
begin
  for q in select id from public.wallet_load_requests
            where status = 'pending' and amount = new.amount
              and new.received_at between created_at - interval '3 hours' and created_at + interval '30 minutes'
              and public._pay_name(sender_name) = public._pay_name(new.sender)
            order by created_at limit 1 loop
    perform public._load_try_auto(q.id);
  end loop;
  return null;
end $$;
drop trigger if exists load_auto_on_payment on public.payments_in;
create trigger load_auto_on_payment after insert on public.payments_in
  for each row execute function public._load_auto_on_payment();
revoke all on function public._load_auto_on_request() from public, anon, authenticated;
revoke all on function public._load_auto_on_payment() from public, anon, authenticated;

drop function if exists public.request_wallet_load(integer, text, text);
create or replace function public.request_wallet_load(p_amount integer, p_screenshot text, p_pin_token text default null,
                                                      p_code text default null, p_sender text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id uuid; v_admin uuid; v_who text; v_st text;
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_sender text := left(btrim(regexp_replace(coalesce(p_sender, ''), '\s+', ' ', 'g')), 60);
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  perform public._assert_open();
  perform public._wallet_pin_consume(p_pin_token);
  if p_amount is null or p_amount < 1 or p_amount > 100000 then
    raise exception 'Enter the amount you paid (1 to 100000).';
  end if;
  if v_code !~ '^[A-Z0-9]{6,15}$' then
    raise exception 'Type the eSewa Transaction Code from your payment screen (letters and numbers, like 1VDLJI9).';
  end if;
  if length(v_sender) < 2 then
    raise exception 'Type the name on the eSewa account you paid from.';
  end if;
  if p_screenshot is null or p_screenshot !~ '^data:image/(png|jpe?g|webp);base64,[A-Za-z0-9+/=]+$' then
    raise exception 'Please attach your eSewa payment screenshot.';
  end if;
  if length(p_screenshot) > 600000 then
    raise exception 'The screenshot is too large. Please upload a smaller image.';
  end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned.';
  end if;
  if (select count(*) from public.wallet_load_requests where player_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'You already have 3 payments waiting to be checked. Please wait for them first.';
  end if;
  perform pg_advisory_xact_lock(hashtext('load-code:' || v_code));
  if exists(select 1 from public.wallet_load_requests where upper(esewa_code) = v_code and status <> 'rejected') then
    raise exception 'This eSewa payment (code %) was already sent. Each payment can be used once.', v_code;
  end if;
  insert into public.wallet_load_requests (player_id, amount, screenshot, esewa_code, sender_name)
  values (auth.uid(), p_amount, p_screenshot, v_code, v_sender)
  returning id into v_id;
  select status into v_st from public.wallet_load_requests where id = v_id;   -- the insert trigger may have auto-approved it

  if v_st = 'pending' then
    select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com';
    if v_admin is not null then
      select coalesce('@' || username, player_tag, 'A player') into v_who from public.players where id = auth.uid();
      insert into public.notifications (player_id, title, body)
      values (v_admin, '🧾 Payment screenshot to check',
              coalesce(v_who, 'A player') || ' sent a Rs ' || p_amount || ' eSewa screenshot (code ' || v_code || ', from ' || v_sender
              || '). No matching phone alert yet. Open Admin → Points to approve or reject it.');
    end if;
  end if;
  return jsonb_build_object('id', v_id, 'status', v_st);
end;
$function$;
revoke all on function public.request_wallet_load(integer, text, text, text, text) from public, anon;
grant execute on function public.request_wallet_load(integer, text, text, text, text) to authenticated;
