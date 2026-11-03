-- 2026-11-03 Faster point loads. The owner's Android phone forwards each eSewa / Khalti "money received"
-- notification (MacroDroid -> payment-in edge function) into payments_in, and JD staff mods get a push.
-- A staff mod can approve a player's load ONLY by matching it to one forwarded payment: same amount, received
-- between 3 hours before and 30 minutes after the request. Each payment pays one load, ever. Anything that
-- doesn't match stays with the admin as before. Server only (service role). Safe to run again.
begin;
create table if not exists public.payments_in (
  id bigserial primary key,
  provider text not null default 'esewa',
  amount int not null check (amount between 1 and 100000),
  sender text,
  raw text not null check (length(raw) <= 600),
  received_at timestamptz not null default now(),
  load_id uuid unique references public.wallet_load_requests(id) on delete set null,
  matched_by text,
  matched_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists payments_in_open on public.payments_in (received_at desc) where load_id is null;
alter table public.payments_in enable row level security;   -- no policies: service role only

-- approve a load by matching it to a forwarded payment, atomically
create or replace function public.match_load_payment(p_load uuid, p_payment bigint, p_by text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.wallet_load_requests; pay public.payments_in; v jsonb;
begin
  select * into r from public.wallet_load_requests where id = p_load for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This request is not waiting any more.'; end if;
  select * into pay from public.payments_in where id = p_payment for update;
  if pay.id is null then raise exception 'Payment not found.'; end if;
  if pay.load_id is not null then raise exception 'That payment already paid another load.'; end if;
  if pay.amount <> r.amount then raise exception 'Amounts differ: payment Rs %, request Rs %. Leave it for the admin.', pay.amount, r.amount; end if;
  if pay.received_at < r.created_at - interval '3 hours' or pay.received_at > r.created_at + interval '30 minutes' then
    raise exception 'The payment time does not match this request. Leave it for the admin.';
  end if;
  update public.payments_in set load_id = r.id, matched_by = left(p_by, 120), matched_at = now() where id = pay.id;
  v := public.admin_resolve_load(r.id, true, r.amount,
         'Matched ' || pay.provider || ' Rs ' || pay.amount || ' received ' || to_char(pay.received_at at time zone 'Asia/Kathmandu', 'DD Mon HH24:MI') || ' (by ' || left(p_by, 60) || ')');
  return v;
end $$;
revoke all on function public.match_load_payment(uuid, bigint, text) from public, anon, authenticated;
grant execute on function public.match_load_payment(uuid, bigint, text) to service_role;
commit;
