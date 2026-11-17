-- Undo payments_in_dedup_key.sql (payment-in still works without it: the 23505 branch just never fires)
drop index if exists public.payments_in_raw_received_key;
