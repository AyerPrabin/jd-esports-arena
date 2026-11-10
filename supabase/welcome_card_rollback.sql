-- Undo welcome_card.sql. Cards already given stay valid until they expire.
begin;
drop trigger if exists welcome_card on public.players;
drop function if exists public._welcome_card();
-- keep public.welcome_cards so the same UID can't get a second card if the offer comes back
commit;
