-- load_name_fit.sql (11 Nov 2026): auto-approve missed a real payment because the player typed their full name
-- ("Suhana begam khan") and eSewa's alert shows a shorter one ("Suhana Begam"). Names now fit when they are equal, or
-- one is the other plus more words, and the shorter one has at least 2 words. Amount, time window and "only one fit"
-- checks are unchanged. Run: npx supabase db query --remote --yes -f supabase/load_name_fit.sql
create or replace function public._pay_name_fit(a text, b text)
returns boolean
language sql
immutable
set search_path = public
as $$
  with n as (select public._pay_name(a) x, public._pay_name(b) y)
  select coalesce(x = y
    or (array_length(regexp_split_to_array(x, ' '), 1) >= 2 and y like x || ' %')
    or (array_length(regexp_split_to_array(y, ' '), 1) >= 2 and x like y || ' %'), false)
  from n where x is not null and y is not null;
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
     and public._pay_name_fit(p.sender, r.sender_name);
  if n <> 1 then return false; end if;
  -- another waiting request with the same amount and name could be the real owner of this payment: admin decides
  if exists (select 1 from public.wallet_load_requests q where q.id <> r.id and q.status = 'pending' and q.amount = r.amount
               and public._pay_name_fit(q.sender_name, r.sender_name)) then return false; end if;
  select * into pay from public.payments_in p
   where p.load_id is null and p.matched_at is null and p.amount = r.amount
     and p.received_at between r.created_at - interval '3 hours' and r.created_at + interval '30 minutes'
     and public._pay_name_fit(p.sender, r.sender_name)
   for update;
  if pay.id is null then return false; end if;
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
              and public._pay_name_fit(new.sender, sender_name)
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

