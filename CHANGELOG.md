# BazCore Changelog

## 121 — Flyouts close instantly after casting, even in combat

**Casting from a flyout now closes it right away in combat.** Version 120
stopped the combat error but left the flyout open until you dropped
combat. The close now happens inside Blizzard's secure environment, so
it is immediate whether or not you're fighting.

Clicking away from an open flyout during combat still waits for combat
to end. Blizzard offers no protected way to detect that click, so that
part is unchanged.
