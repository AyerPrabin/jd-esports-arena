-- ── Saved squad contact (2026-10-21) ──
-- The WhatsApp number and device a player registers with are kept on their account, so the next
-- registration is one tap: confirm the saved squad, tick the rules, join. Own table, only the owner can
-- read it (and the admin through the service role); never in any public RPC. Removed with the account
-- (cascade) or any time from the registration form ("Remove saved number").
begin;

create table if not exists public.player_contacts (
  player_id uuid primary key references public.players(id) on delete cascade,
  whatsapp text check (whatsapp is null or whatsapp ~ '^\+?[0-9]{7,15}$'),
  device_type text check (device_type is null or device_type in ('mobile','emulator')),
  updated_at timestamptz not null default now()
);
alter table public.player_contacts enable row level security;
drop policy if exists "players read own contact" on public.player_contacts;
create policy "players read own contact" on public.player_contacts for select using (auth.uid() = player_id);

create or replace function public.my_contact()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('whatsapp', whatsapp, 'device_type', device_type)
                   from public.player_contacts where player_id = auth.uid()), '{}'::jsonb);
$$;
revoke all on function public.my_contact() from public, anon;
grant execute on function public.my_contact() to authenticated;

create or replace function public.forget_my_whatsapp()
returns void language sql security definer set search_path = public as $$
  update public.player_contacts set whatsapp = null, updated_at = now() where player_id = auth.uid();
$$;
revoke all on function public.forget_my_whatsapp() from public, anon;
grant execute on function public.forget_my_whatsapp() to authenticated;

-- same as before, plus: the number and the registration's device are saved to the account
create or replace function public.set_registration_whatsapp(p_reg_id uuid, p_whatsapp text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v text := regexp_replace(coalesce(p_whatsapp, ''), '[\s\-().]', '', 'g');
  v_dev text;
begin
  if v = '' then v := null;
  elsif v !~ '^\+?[0-9]{7,15}$' then
    raise exception 'Enter a valid WhatsApp number with country code, e.g. +977 98XXXXXXXX.';
  end if;
  update public.registrations set whatsapp = v where id = p_reg_id and player_id = auth.uid()
    returning device_type into v_dev;
  if not found then raise exception 'Registration not found.'; end if;
  if v is not null then
    insert into public.player_contacts (player_id, whatsapp, device_type) values (auth.uid(), v, v_dev)
    on conflict (player_id) do update set whatsapp = excluded.whatsapp,
      device_type = coalesce(excluded.device_type, player_contacts.device_type), updated_at = now();
  end if;
  return v;
end;
$$;
revoke all on function public.set_registration_whatsapp(uuid, text) from public, anon;
grant execute on function public.set_registration_whatsapp(uuid, text) to authenticated;

commit;
