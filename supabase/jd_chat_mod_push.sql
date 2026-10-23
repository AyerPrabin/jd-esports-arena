-- ── Moderators get a phone push when a player writes in the JD Esports chat (2026-10-23) ──
-- Same trigger as zulu_channel.sql (staff messages marked push -> the player, dm-push kind 'jd'),
-- plus: player messages in channel 'jd' -> every moderator's JD account (dm-push kind 'staff').
-- Still no AI auto-reply inside JD Esports (people only).
begin;

create or replace function public.jd_messages_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids bigint[]; v_in bigint[];
begin
  select array_agg(id) into v_ids from new_rows where from_staff and push;
  select array_agg(id) into v_in from new_rows where not from_staff and channel = 'jd';
  if v_ids is null and v_in is null then return null; end if;
  begin
    if v_ids is not null then
      perform net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/dm-push',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
        body := jsonb_build_object('ids', to_jsonb(v_ids), 'kind', 'jd'));
    end if;
    if v_in is not null then
      perform net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/dm-push',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
        body := jsonb_build_object('ids', to_jsonb(v_in), 'kind', 'staff'));
    end if;
  exception when others then
    raise warning 'jd_messages_push: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.jd_messages_push() from public, anon, authenticated;

commit;
