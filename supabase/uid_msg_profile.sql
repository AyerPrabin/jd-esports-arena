-- uid_msg_profile.sql (11 Nov 2026): the challenge errors pointed players to "tap your name > Game UID & name",
-- which players could not find. The Free Fire ID card is now at the top of the Profile page.
-- Rewrites only that text inside the live functions (same code otherwise).
-- Run: npx supabase db query --remote --yes -f supabase/uid_msg_profile.sql
do $$
declare f record; d text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and pg_get_functiondef(p.oid) like '%(tap your name > Game UID & name)%' loop
    d := replace(pg_get_functiondef(f.oid), '(tap your name > Game UID & name)', '(Profile > Free Fire ID card at the top)');
    execute d;
  end loop;
end $$;
select count(*) as still_old from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and pg_get_functiondef(p.oid) like '%Game UID & name%';
