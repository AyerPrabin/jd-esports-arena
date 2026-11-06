begin;
drop function public.wallet_pin_reset_finish(text);
drop function public.wallet_pin_reset_start();
create or replace function public.wallet_pin_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('has_pin', exists(select 1 from public.wallet_pins where player_id = auth.uid()));
$$;
drop function public._wallet_pin_fresh_proof(timestamptz);
alter table public.wallet_pins drop column reset_started;
notify pgrst, 'reload schema';
commit;
