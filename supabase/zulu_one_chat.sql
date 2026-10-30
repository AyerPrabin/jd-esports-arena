-- ── One chat: JD Esports + ZULU (2026-10-30) ──
-- Player messages in the JD Esports chat go to ZULU (zulu-auto) instead of straight to the moderators.
-- ZULU answers; only when it flags a big issue ([FLAG]) does zulu-auto push the moderators (dm-push kind 'staff')
-- and leave the messages unread in /mod/. Replaces the push trigger from jd_chat_mod_push.sql.
-- jd_thread now tells the app which replies are ZULU's (ai = true) so they show with ZULU's avatar.
begin;

create or replace function public.jd_messages_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids bigint[]; v_q bigint[];
begin
  select array_agg(id) into v_ids from new_rows where from_staff and push;
  select array_agg(id) into v_q from new_rows where not from_staff and channel = 'jd';
  if v_ids is null and v_q is null then return null; end if;
  begin
    if v_ids is not null then
      perform net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/dm-push',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
        body := jsonb_build_object('ids', to_jsonb(v_ids), 'kind', 'jd'));
    end if;
    if v_q is not null then   -- a player wrote: ZULU answers (zulu-auto), and flags the team when needed
      perform net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/zulu-auto',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
        body := jsonb_build_object('ids', to_jsonb(v_q)));
    end if;
  exception when others then
    raise warning 'jd_messages_push: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.jd_messages_push() from public, anon, authenticated;

create or replace function public.jd_thread(p_before bigint default null, p_after bigint default null)
returns table(id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz, ai boolean)
language sql stable security definer set search_path = public as $$
  select m.id, not m.from_staff, m.body, m.created_at, m.read_at, coalesce(m.from_staff and m.staff_email like 'zulu%', false)
  from public.jd_messages m
  where m.player_id = auth.uid() and m.channel = 'jd'
    and (p_before is null or m.id < p_before)
    and (p_after is null or m.id > p_after)
  order by m.id desc limit 60
$$;

commit;
