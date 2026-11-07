-- Undo host_chat.sql. This also deletes every host chat message.
drop function if exists public.host_send(text, text);
drop function if exists public.host_mark_read(text);
drop function if exists public.host_thread(text, bigint, bigint);
drop function if exists public.host_chat_list();
drop function if exists public._host_of_event(text);
drop table if exists public.host_messages;
drop function if exists public._host_chat_filter();
