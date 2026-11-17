# Post-mortem: Supabase data-transfer block, 7–8 Nov 2026

**Severity:** high. Pages that read from the database stopped working for every player.
**Duration of the outage:** about 22:40 on 7 Nov to the morning of 8 Nov (UK time).
**Author:** Prabin Ayer. Blameless format: the cause was the design, not a person.

## Summary

On 7 Nov 2026 at about 22:40, Supabase began answering with HTTP 402 `exceed_egress_quota`. The project had used its
monthly data-transfer allowance on the free plan. No data was lost and no points moved wrongly; the site simply could
not read. The root cause was my own client code downloading the same large data again and again. It was not an
attack and not a traffic spike.

## Impact

- Home, events, leaderboard and wallet pages could not load data from about 22:40.
- The Android app update file (served from Supabase Storage) could not be downloaded.
- Wallet integrity was not affected: no failed half-writes, and balances still matched the ledger afterwards.

## Timeline (UK time, from the commit history)

| Time | What happened |
| --- | --- |
| 7 Nov ~22:40 | First 402 `exceed_egress_quota` responses. |
| 7 Nov 22:53 | `14357c5`: leaderboard (every 15 s) and events (every 30 s) stopped re-downloading a 145 KB events copy; pages read only an `updated_at` stamp and keep the last copy on the device. |
| 8 Nov | Plan upgraded to Pro for one month to restore service while the fixes landed. |
| 8 Nov 08:57 | `7c6cd3b`: polling cut across pages (for example home 5 s to 20 s, chat 5 s to 15 s, wallet 15 s to 45 s). |
| 8 Nov 09:07 | `997c2c7`: APK download moved off Supabase Storage to GitHub. |
| 8 Nov 09:10 | `91f2581`: the main drain fixed. `get_public_roster()` sent all 65 squad logos as base64, **937 KB on every home or events open**. Replaced with `get_public_roster_lite()` (md5 key per logo) plus `get_logos(keys)` for only the logos a phone does not have, cached on the device. |
| 8 Nov 10:10 | `92c8c7f`: the admin dashboard stopped loading every logo just to count squads (about 540 KB less per load). |

## Root cause

Three design choices multiplied each other:

1. **Images inside list responses.** Squad logos were stored and sent as base64 inside the roster call, so every page
   open downloaded every logo again.
2. **Short polling intervals.** Many pages polled every 5–30 s, re-fetching full payloads even when nothing changed.
3. **No data budget.** Nothing estimated "size × open phones × polls per hour" before a feature shipped.

**Contributing factor:** a 23 Oct fix added a "has it changed?" fingerprint when the roster payload was about 370 KB
(`supabase/roster_version.sql`). It helped, but the payload kept growing as squads joined, and every real change still
sent the full 937 KB to every phone.

## What went well

- The cause was found the same night from the request pattern and payload sizes.
- Every fix shipped with a fallback, so phones on an old cached page kept working.
- Money logic was isolated in database functions, so the read outage could not corrupt balances.

## What went badly

- There was no alert on data-transfer usage. The first signal was the outage itself.
- Payload sizes were never measured before release.
- The new roster call's size after the fix was not measured either; a fair estimate for 65 squads is 10–15 KB.

## Action items

| Action | Status |
| --- | --- |
| Poll every 20 s or slower; read a small version stamp first | Done (rule for every change) |
| Never `select *` on tables with large columns; name the columns | Done (rule) |
| Never send base64 images in lists; send a key and cache on the device | Done |
| Estimate size × phones × polls per hour before shipping a new read | Done (rule) |
| Alert on data-transfer usage well below the plan limit | Open |
| Measure real payload sizes of the main calls and record them here | Open |

Full system context: [ARCHITECTURE.md](ARCHITECTURE.md), section 6.
