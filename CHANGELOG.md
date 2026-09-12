# BazCore Changelog

## 119 — Timer leak fix and Midnight API updates

**Fixed a slow memory leak.** One-shot timers created by Baz addons were
never removed from BazCore's tracking list after they fired, so the list
grew for as long as you stayed logged in.

**Midnight API updates.** Talent specialization lookups (used by
spec-based profiles) and item quality colours now use the current
`C_` APIs, so they keep working when Blizzard removes the old
compatibility functions. The icon picker's spell search dropped its
pre-Midnight fallback.

**Marked compatible with patch 12.1.0.** The addon no longer shows as out of date in the AddOns list.
