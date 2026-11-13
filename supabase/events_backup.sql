-- Automatic backup of the event list (13 Nov 2026, after an empty admin publish wiped every event).
-- Before every change to site_content 'tournaments', the old copy is saved in site_content_history.
-- Restore the newest good copy:
--   update site_content set content = (select content from site_content_history where key='tournaments'
--     and jsonb_array_length(content->'tournaments') > 5 order by saved_at desc limit 1), updated_at = now()
--   where key = 'tournaments';
create table if not exists public.site_content_history (
  id bigserial primary key,
  key text not null,
  content jsonb not null,
  events int,
  saved_at timestamptz not null default now()
);
alter table public.site_content_history enable row level security;   -- no policies: service role / SQL only
revoke all on public.site_content_history from anon, authenticated;

create or replace function public.site_content_keep_history() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.key = 'tournaments' and old.content is distinct from new.content then
    insert into site_content_history(key, content, events)
    values (old.key, old.content, jsonb_array_length(coalesce(old.content->'tournaments', '[]'::jsonb)));
    -- keep the last 200 copies (~145 KB each)
    delete from site_content_history where key = 'tournaments' and id <= (
      select id from site_content_history where key = 'tournaments' order by id desc offset 200 limit 1);
  end if;
  return new;
end $$;

drop trigger if exists site_content_history_trg on public.site_content;
create trigger site_content_history_trg before update on public.site_content
  for each row execute function public.site_content_keep_history();

-- first backup: the current, restored list
insert into site_content_history(key, content, events)
select key, content, jsonb_array_length(content->'tournaments') from site_content where key = 'tournaments';

select id, events, saved_at::text from site_content_history order by id desc limit 3;
