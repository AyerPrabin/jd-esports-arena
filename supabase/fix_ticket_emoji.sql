-- 2026-10-27: the "Registered" notification title showed a mis-encoded 🎫 ("ðŸŽ«") and the squad-name error a
-- mis-encoded dash. Owner: remove it. Strips the junk from register_for_tournament and from saved notifications.
-- chr() codes so this file can't be mis-encoded again: ðŸŽ« = 240 376 381 171, â€” = 226 8364 8221.
begin;
do $$
declare d text := pg_get_functiondef('public.register_for_tournament'::regproc);
begin
  d := replace(d, chr(240)||chr(376)||chr(381)||chr(171)||' ', '');
  d := replace(d, chr(226)||chr(8364)||chr(8221), '-');
  execute d;
end $$;
update public.notifications
   set title = btrim(replace(replace(title, chr(240)||chr(376)||chr(381)||chr(171), ''), chr(226)||chr(8364)||chr(8221), '-')),
       body  = replace(replace(body, chr(240)||chr(376)||chr(381)||chr(171), ''), chr(226)||chr(8364)||chr(8221), '-')
 where title like '%'||chr(240)||chr(376)||'%' or body like '%'||chr(240)||chr(376)||'%'
    or title like '%'||chr(226)||chr(8364)||'%' or body like '%'||chr(226)||chr(8364)||'%';
select (select count(*) from public.notifications where title like '%'||chr(240)||chr(376)||'%' or title like '%'||chr(226)||chr(8364)||'%') left_bad,
       position(chr(240)||chr(376) in pg_get_functiondef('public.register_for_tournament'::regproc)) = 0 func_clean,
       (select title from public.notifications where title like 'Registered: %' order by created_at desc limit 1) sample;
commit;
