-- load_first_name.sql (21 Nov 2026): faster point loads.
-- eSewa's alert often shows only the sender's first name ("Ram") while the player types the full name ("Ram Bahadur Thapa").
-- load_name_fit.sql needs 2+ words on the shorter side, so 8 of 20 real loads since 11 Nov waited for the admin (median
-- 12 min, up to 10 h). Now a one-word name (3+ letters) also fits when it is the first word of the other name, but only
-- for a payment within 30 minutes of the request (full-name fits keep -3 h / +30 min). Amount, "only one payment fits"
-- and the other-request check stay. The other-request check now compares against the PAYMENT's name, so an alert
-- "Ram" with two waiting "Ram X" requests of the same amount always goes to the admin.
-- Tested read-only on every load since 11 Nov: 8 more auto, 0 wrong pairs (different names stay manual).
-- Run: npx supabase db query --remote --yes -f supabase/load_first_name.sql
-- Undo: npx supabase db query --remote --yes -f supabase/load_name_fit.sql

create or replace function public._pay_first_fit(a text, b text)
returns boolean
language sql
immutable
set search_path = public
as $$
  with n as (select public._pay_name(a) x, public._pay_name(b) y)
  select coalesce(
       (position(' ' in x) = 0 and length(x) >= 3 and starts_with(y, x || ' '))
    or (position(' ' in y) = 0 and length(y) >= 3 and starts_with(x, y || ' ')), false)
  from n where x is not null and y is not null
    and x ~ '^[[:alpha:][:space:].''-]+$' and y ~ '^[[:alpha:][:space:].''-]+$';   -- letters only: no wildcards or symbols
$$;

-- does payment p fit load request r? full name in -3 h / +30 min, first name only in -30 / +30 min
create or replace function public._pay_fits_load(p_sender text, p_at timestamptz, p_amount int,
                                                 r_name text, r_at timestamptz, r_amount int)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_amount = r_amount and (
       (public._pay_name_fit(p_sender, r_name) and p_at between r_at - interval '3 hours' and r_at + interval '30 minutes')
    or (public._pay_first_fit(p_sender, r_name) and p_at between r_at - interval '30 minutes' and r_at + interval '30 minutes'));
$$;
revoke all on function public._pay_first_fit(text, text) from public, anon, authenticated;
revoke all on function public._pay_fits_load(text, timestamptz, int, text, timestamptz, int) from public, anon, authenticated;

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
   where p.load_id is null and p.matched_at is null
     and public._pay_fits_load(p.sender, p.received_at, p.amount, r.sender_name, r.created_at, r.amount);
  if n <> 1 then return false; end if;
  select * into pay from public.payments_in p
   where p.load_id is null and p.matched_at is null
     and public._pay_fits_load(p.sender, p.received_at, p.amount, r.sender_name, r.created_at, r.amount)
   for update;
  if pay.id is null then return false; end if;
  -- another waiting request that this payment also fits could be its real owner: admin decides
  if exists (select 1 from public.wallet_load_requests q where q.id <> r.id and q.status = 'pending'
               and public._pay_fits_load(pay.sender, pay.received_at, pay.amount, q.sender_name, q.created_at, q.amount)) then
    return false;
  end if;
  update public.payments_in set load_id = r.id, matched_by = 'auto: amount + eSewa name', matched_at = now()
   where id = pay.id and load_id is null and matched_at is null;
  if not found then return false; end if;
  perform public.admin_resolve_load(r.id, true, r.amount,
    'Auto: eSewa Rs ' || pay.amount || ' from ' || coalesce(public._pay_name(pay.sender), '?') || ' at '
    || to_char(pay.received_at at time zone 'Asia/Kathmandu', 'DD Mon HH24:MI') || ', code ' || coalesce(r.esewa_code, '-'));
  return true;
exception when others then
  return false;   -- never break a request or a payment alert: it just waits for the admin
end;
$$;
revoke all on function public._load_try_auto(uuid) from public, anon, authenticated;

create or replace function public._load_auto_on_payment()
returns trigger language plpgsql security definer set search_path = public as $$
declare q record;
begin
  for q in select id from public.wallet_load_requests
            where status = 'pending'
              and public._pay_fits_load(new.sender, new.received_at, new.amount, sender_name, created_at, amount)
            order by created_at limit 1 loop
    perform public._load_try_auto(q.id);
  end loop;
  return null;
end $$;
revoke all on function public._load_auto_on_payment() from public, anon, authenticated;
-- triggers load_auto_on_request / load_auto_on_payment already exist (load_name_fit.sql) and call these functions by name
