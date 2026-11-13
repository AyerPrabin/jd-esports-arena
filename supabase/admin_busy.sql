-- Admin busy times (13 Nov 2026): the JD Admin app (owner's phone) reads the phone calendar every ~15 min and sends
-- ONLY start/end times of the next 36 h (no titles, places or notes) to the admin-busy function, which stores them here.
-- Mods see "Admin is busy right now, back after HH:MM" in the mod panel. Rollback at the bottom.
begin;

create table if not exists public.admin_busy (
  id int primary key default 1 check (id = 1),
  blocks jsonb not null default '[]'::jsonb,      -- [{"s": "<iso start>", "e": "<iso end>"}], max 40
  updated_at timestamptz not null default now()
);
alter table public.admin_busy enable row level security;
revoke all on public.admin_busy from anon, authenticated;   -- written by the service role only, read via admin_busy_now()

-- staff only: is the admin busy now, until when (blocks that touch are merged), and when the next block starts
create or replace function public.admin_busy_now()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_blocks jsonb; v_at timestamptz; v_until timestamptz; v_next timestamptz; r record;
begin
  if not public.is_moderator() then raise exception 'not a moderator'; end if;
  select blocks, updated_at into v_blocks, v_at from public.admin_busy where id = 1;
  if v_blocks is null then return jsonb_build_object('known', false); end if;
  for r in select (b->>'s')::timestamptz s, (b->>'e')::timestamptz e
           from jsonb_array_elements(v_blocks) b order by 1 loop
    if r.e <= now() then continue; end if;
    if v_until is null and v_next is null and r.s <= now() then v_until := r.e;
    elsif v_until is not null and v_next is null and r.s <= v_until + interval '15 minutes' then v_until := greatest(v_until, r.e);
    elsif v_next is null and r.s > now() then v_next := r.s;
    end if;
  end loop;
  return jsonb_build_object('known', v_at > now() - interval '2 hours', 'busy', v_until is not null,
                            'until', v_until, 'next', v_next, 'updated_at', v_at);
end $$;
revoke all on function public.admin_busy_now() from public, anon;
grant execute on function public.admin_busy_now() to authenticated;

commit;

-- Rollback:
-- drop function if exists public.admin_busy_now(); drop table if exists public.admin_busy;
