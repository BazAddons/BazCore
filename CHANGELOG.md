# BazCore Changelog

## 120 — No more combat errors from flyout popups

**Fixed ADDON_ACTION_BLOCKED when a flyout closes in combat.** Clicking
away from an open BazBars flyout, or casting from one of its cells, while
in combat tripped Blizzard's protected-frame guard and produced an error.
Those dismissals now wait until you leave combat, and the flyout closes on
its own at that point. Right-clicking the flyout's button still closes it
instantly mid-combat, as before.
