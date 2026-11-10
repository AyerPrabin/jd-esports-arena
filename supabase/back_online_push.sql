-- One-time "we're back" alert to every player (owner OK'd 8 Nov 2026). Run ONCE: each run sends it again.
-- One notification row per player; the notifications_push trigger pushes them as one batch (app + browser).
insert into public.notifications (player_id, title, body)
select id, 'JD Arena is back', 'The app is working again. Open JD Arena to see today''s tournaments.'
from public.players;
