-- Owner request 2026-10-27: tell every player about app 2.0 (push + Alerts; the notifications trigger sends the push).
insert into public.notifications (player_id, title, body, push)
select id, '📲 JD Arena 2.0 is here',
       'Android: JD Arena is now a real app - no Chrome or Brave inside, so nothing gets blocked, and alerts are faster. '
       || 'Open JD Arena and tap Update, or get it at jdesport.co.uk/download. Sign in once after updating.',
       true
  from public.players;
select count(*) as sent from public.notifications where title = '📲 JD Arena 2.0 is here';
