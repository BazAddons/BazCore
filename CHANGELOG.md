# BazCore Changelog

## 118 — Profiles list refreshes after Create / Delete / Reset

Creating, deleting, resetting, or copying a profile from the
Profiles tab now refreshes the visible list immediately. Previously
you had to close and reopen the Options window to see the change.

The internal `RefreshProfilesPanel` helper was poking at an
`optionsTables[name].canvas` field that was never assigned, so it
silently no-op'd. Replaced with a call to the public
`BazCore:RefreshOptions("BazCore-Profiles")` API, which is the
canonical re-render path.
