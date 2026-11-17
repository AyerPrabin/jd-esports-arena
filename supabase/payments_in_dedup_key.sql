-- 2026-11-17 payment-in race fix. Two identical alerts arriving at the same moment could both pass the
-- select-then-insert check in functions/payment-in. One row per (alert text, time received): the second insert now
-- fails with 23505 and payment-in answers "duplicate". The 90 s select check in payment-in stays for re-sends.
-- Read-only check 17 Nov: 31 rows, 0 duplicate (raw, received_at) pairs, longest raw 109 bytes.
-- Run this BEFORE deploying payment-in. Undo: payments_in_dedup_key_rollback.sql
create unique index if not exists payments_in_raw_received_key on public.payments_in (raw, received_at);
