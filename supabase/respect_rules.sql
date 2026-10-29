-- ── Rule 9 (respect: no rude language) + rule 10 (the owner plays for fun) — 2026-10-29. Safe to run again. ──
-- Rule 9: rude words in player chat (DMs, group chats, Clash Squad match chats, JD Support) are replaced with *** by the
-- database itself (a filter in the browser could be bypassed). Each hit is a strike in chat_strikes. The player
-- gets one reminder a day; at 3 strikes in 7 days the owner is notified. Nobody is banned automatically - the admin
-- decides. Words live in chat_bad_words: add or remove them there (lower case; stem = also words that start with it).
-- Rule 10: the owner plays for fun and is never paid a prize: _award_one() skips the owner's squad (status
-- owner_plays_for_fun) and the admin gives that prize to the next squad.
begin;

create table if not exists public.chat_bad_words (
  word text primary key check (word = lower(word) and length(word) between 2 and 40),
  stem boolean not null default false
);
alter table public.chat_bad_words enable row level security;   -- no policies: only the filter (security definer) reads it
insert into public.chat_bad_words (word, stem) values
  ('fuck', true),
  ('motherfuck', true),
  ('shit', true),
  ('bitch', true),
  ('bastard', false),
  ('asshole', false),
  ('cunt', false),
  ('dick', false),
  ('pussy', false),
  ('slut', false),
  ('whore', false),
  ('retard', false),
  ('nigger', false),
  ('nigga', false),
  ('faggot', false),
  ('fag', false),
  ('wanker', false),
  ('twat', false),
  ('muji', false),
  ('machikne', false),
  ('chikne', false),
  ('randi', false),
  ('lado', false),
  ('puti', false),
  ('bhalu', false),
  ('gandu', false),
  ('chutiya', true),
  ('madarchod', false),
  ('maderchod', false),
  ('mc', false),
  ('bc', false),
  ('bhenchod', false),
  ('behenchod', false),
  ('bhosdi', true),
  ('lund', false),
  ('lawde', false),
  ('laude', false),
  ('harami', false)
on conflict (word) do nothing;

create table if not exists public.chat_strikes (
  id bigserial primary key,
  player_id uuid references public.players(id) on delete cascade,
  source text not null,
  words text[] not null,
  created_at timestamptz not null default now()
);
create index if not exists chat_strikes_player_idx on public.chat_strikes (player_id, created_at desc);
alter table public.chat_strikes enable row level security;     -- no policies: service role / admin tools only

-- one letter of a bad word: any case (flag i), common look-alikes (@ for a, 0 for o ...) and stretched (fuuuck)
create or replace function public._rude_letter(c text) returns text language sql immutable as $$
  select case c when 'a' then '[a@4]' when 'e' then '[e3]' when 'i' then '[i1!]' when 'o' then '[o0]'
                when 's' then '[s$5]' else c end || '+'
$$;

-- masked = p with every bad word replaced by ***; hits = the words found. Whole words only (class, assassin and
-- Scunthorpe stay as they are); letters may be split by . _ * - (f.u.c.k).
create or replace function public.jd_mask_rude(p text, out masked text, out hits text[])
language plpgsql stable security definer set search_path = public as $$
declare w record; core text; nxt text;
begin
  masked := p; hits := '{}';
  if p is null then return; end if;
  for w in select word, stem from public.chat_bad_words order by length(word) desc loop
    select string_agg(public._rude_letter(c), '[._*-]*' order by n) into core
      from regexp_split_to_table(w.word, '') with ordinality t(c, n);
    nxt := regexp_replace(masked, '(^|[^[:alnum:]])' || core || case when w.stem then '[[:alpha:]]*' else '' end
                                  || '(?![[:alnum:]])', '\1***', 'gi');
    if nxt <> masked then hits := hits || w.word; masked := nxt; end if;
  end loop;
end;
$$;
revoke all on function public.jd_mask_rude(text) from public, anon, authenticated;

create or replace function public._chat_respect() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_admin uuid; v_n int; v_sender uuid; j jsonb := to_jsonb(new);
begin
  -- dm / group / challenge messages have a sender; the JD Support chat (jd_messages) has player_id + from_staff
  v_sender := case when j ? 'from_staff' then case when (j->>'from_staff')::boolean then null else (j->>'player_id')::uuid end
                   else (j->>'sender')::uuid end;
  if coalesce(j->>'kind', 'text') <> 'text' or v_sender is null then return new; end if;
  select * into r from public.jd_mask_rude(new.body);
  if r.masked is not distinct from new.body then return new; end if;
  new.body := r.masked;
  -- reminder to the sender at most once a day (checked before this strike is logged)
  if not exists(select 1 from public.chat_strikes where player_id = v_sender and created_at > now() - interval '1 day') then
    insert into public.notifications (player_id, title, body)
    values (v_sender, '🤝 Rule 9: respect everyone',
            'Rude words in your message were hidden (***). JD Arena chat is for friendly play - repeated rude language can get your account banned by the admin.');
  end if;
  insert into public.chat_strikes (player_id, source, words) values (v_sender, tg_table_name, r.hits);
  select count(*) into v_n from public.chat_strikes where player_id = v_sender and created_at > now() - interval '7 days';
  if v_n = 3 then
    select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com' limit 1;
    if v_admin is not null then
      insert into public.notifications (player_id, title, body)
      select v_admin, '⚠️ Rude language: 3 strikes in 7 days',
             coalesce('@' || p.username, 'A player') || ' used rude words 3 times this week (rule 9). You decide: warn or ban. '
             || 'Words: ' || array_to_string(r.hits, ', ')
        from public.players p where p.id = v_sender;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists chat_respect on public.dm_messages;
create trigger chat_respect before insert on public.dm_messages for each row execute function public._chat_respect();
drop trigger if exists chat_respect on public.group_messages;
create trigger chat_respect before insert on public.group_messages for each row execute function public._chat_respect();
drop trigger if exists chat_respect on public.challenge_messages;
create trigger chat_respect before insert on public.challenge_messages for each row execute function public._chat_respect();
drop trigger if exists chat_respect on public.jd_messages;
create trigger chat_respect before insert on public.jd_messages for each row execute function public._chat_respect();

-- rule 10: the live _award_one (read from the database on 2026-10-29) + the owner check
CREATE OR REPLACE FUNCTION public._award_one(p_slug text, p_squad text, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player uuid;
  v_ref text := 'prize:' || p_slug || ':' || lower(trim(p_squad));
  v_bal int;
  v_cut int := 0;
  v_referrer uuid;
  v_note text := '';
begin
  if p_amount is null or p_amount < 1 then
    return jsonb_build_object('squad', p_squad, 'status', 'no_amount');
  end if;
  if exists(select 1 from public.wallet_ledger where reason = 'prize' and ref = v_ref) then
    return jsonb_build_object('squad', p_squad, 'status', 'already_paid');
  end if;
  select player_id into v_player from public.registrations
    where tournament_slug = p_slug and lower(trim(squad_name)) = lower(trim(p_squad))
      and status in ('confirmed','approved')
    order by created_at asc limit 1;
  if v_player is null then
    return jsonb_build_object('squad', p_squad, 'status', 'unmatched', 'amount', p_amount);
  end if;
  -- rule 10: the owner plays for fun and is never paid; the admin gives this prize to the next squad
  if exists(select 1 from public.players where id = v_player and lower(email) = 'ayerprabin95@gmail.com') then
    return jsonb_build_object('squad', p_squad, 'status', 'owner_plays_for_fun', 'amount', p_amount);
  end if;
  v_bal := public._wallet_apply(v_player, p_amount, 'prize', v_ref, p_slug);
  -- referral: the invited player's first prize -> +40 for them and +40 for the friend who invited them
  update public.referrals set bonus_paid_at = now() where referred_id = v_player and bonus_paid_at is null
    returning referrer_id into v_referrer;
  if v_referrer is not null then
    v_bal := public._wallet_apply(v_player, 40, 'referral', 'ref:' || v_player::text, 'Invite bonus - first win');
    perform public._wallet_apply(v_referrer, 40, 'referral', 'ref:' || v_player::text || ':by', 'Your invited friend won');
    insert into public.notifications (player_id, title, body) values (v_referrer, '🤝 +40 points: your friend won',
      coalesce((select coalesce(username, player_tag) from public.players where id = v_player), 'Your invited friend') ||
      ' won their first prize, so you both got +40 points. Invite more friends from your profile.');
    v_note := v_note || ' +40 invite bonus for your first win.';
  end if;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (v_player, p_slug, '🏆 Prize: +' || p_amount || ' JD points',
          'Congratulations! ' || p_squad || '''s prize for ' || p_slug || ' (' || p_amount || ' points) is in your wallet.' ||
          v_note || ' Balance: ' || v_bal || ' points. You can use it for entries or withdraw it to eSewa.');
  return jsonb_build_object('squad', p_squad, 'status', 'paid', 'amount', p_amount, 'player_id', v_player,
                            'pass_cut', v_cut, 'referral', v_referrer is not null);
end;
$function$;

commit;
