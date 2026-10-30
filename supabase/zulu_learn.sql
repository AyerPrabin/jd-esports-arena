-- ── ZULU learns from the JD team (2026-10-30) ──
-- zulu_team_answers(question): how a JD moderator answered the most similar questions in the official JD Esports
-- chat (channel 'jd', last 180 days), so ZULU answers the next player the same way. Each moderator reply is paired
-- with the player's messages just before it; ranked by word overlap with the new question ('simple' config, so
-- romanized Nepali works). Never reads players' private chats (DMs, squad or match chats). Server only.
create or replace function public.zulu_team_answers(p_q text, p_exclude uuid default null)
returns table(q text, a text)
language sql stable security definer set search_path = public as $$
  with words as (
    select distinct w from regexp_split_to_table(lower(coalesce(p_q, '')), '[^[:alnum:]]+') w
    where length(w) >= 3 and w not in ('the','and','for','not','but','did','didnt','dont','after','before','about','mero','tapai','timi','hajur','kina','kasari','kati','sir','yes','okay','zulu','you','are','can','how','what','when','why','with','this','that','have','from','please','bro','dai','hai','cha','chha','garne','garnu','ho','ma','ko','lai')
    limit 20
  ), tq as (
    select to_tsquery('simple', string_agg(w || ':*', ' | ')) t from words having count(*) > 0
  ), staff as (
    select m.id, m.player_id, m.body as a from public.jd_messages m
    where m.channel = 'jd' and m.from_staff and coalesce(m.staff_email, '') not like 'zulu%'
      and length(m.body) >= 15 and m.created_at > now() - interval '180 days' and (p_exclude is null or m.player_id <> p_exclude)
    order by m.id desc limit 500
  ), paired as (
    select s.a, (
      select string_agg(x.body, ' / ' order by x.id) from (
        select p.id, p.body from public.jd_messages p
        where p.player_id = s.player_id and p.channel = 'jd' and not p.from_staff and p.id < s.id
          and p.id > coalesce((select max(b.id) from public.jd_messages b where b.player_id = s.player_id and b.channel = 'jd'
                                and b.from_staff and coalesce(b.staff_email, '') not like 'zulu%' and b.id < s.id), 0)
        order by p.id desc limit 3) x
    ) as q from staff s
  )
  select left(paired.q, 300), left(paired.a, 500) from paired, tq
  where paired.q is not null and to_tsvector('simple', paired.q) @@ tq.t
  order by ts_rank(to_tsvector('simple', paired.q), tq.t) desc limit 4
$$;
revoke all on function public.zulu_team_answers(text, uuid) from public, anon, authenticated;
