-- 2026-11-03 payments_in hardening: a used payment stays used for good (matched_at), and a mod can't match a
-- payment that fits more than one waiting request (same amount + time window): that one goes to the admin.
begin;
alter table public.payments_in drop constraint if exists payments_in_load_id_fkey;
alter table public.payments_in add constraint payments_in_load_id_fkey foreign key (load_id) references public.wallet_load_requests(id) on delete restrict;
create or replace function public.match_load_payment(p_load uuid, p_payment bigint, p_by text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.wallet_load_requests; pay public.payments_in; v jsonb; n int;
begin
  select * into r from public.wallet_load_requests where id = p_load for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This request is not waiting any more.'; end if;
  select * into pay from public.payments_in where id = p_payment for update;
  if pay.id is null then raise exception 'Payment not found.'; end if;
  if pay.load_id is not null or pay.matched_at is not null then raise exception 'That payment was already used.'; end if;
  if pay.amount <> r.amount then raise exception 'Amounts differ: payment Rs %, request Rs %. Leave it for the admin.', pay.amount, r.amount; end if;
  if pay.received_at < r.created_at - interval '3 hours' or pay.received_at > r.created_at + interval '30 minutes' then
    raise exception 'The payment time does not match this request. Leave it for the admin.';
  end if;
  select count(*) into n from public.wallet_load_requests q where q.status = 'pending' and q.amount = pay.amount
    and pay.received_at between q.created_at - interval '3 hours' and q.created_at + interval '30 minutes';
  if n > 1 then raise exception 'This payment fits % waiting requests for Rs %, so only the admin can decide who paid.', n, pay.amount; end if;
  update public.payments_in set load_id = r.id, matched_by = left(p_by, 120), matched_at = now() where id = pay.id;
  v := public.admin_resolve_load(r.id, true, r.amount,
         'Matched ' || pay.provider || ' Rs ' || pay.amount || ' received ' || to_char(pay.received_at at time zone 'Asia/Kathmandu', 'DD Mon HH24:MI') || ' (by ' || left(p_by, 60) || ')');
  return v;
end $$;
revoke all on function public.match_load_payment(uuid, bigint, text) from public, anon, authenticated;
grant execute on function public.match_load_payment(uuid, bigint, text) to service_role;
commit;
