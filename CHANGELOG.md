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

## 117 — Context-menu sections support nested submenus

`OpenContextMenu` now handles a third item shape alongside buttons
and dividers: a `submenu` flyout. Pass `{ label = "X", submenu = {...
items ...} }` and the parent button opens a child menu on hover when
the user mouses over it. Submenus nest arbitrarily because the item
renderer recurses, so an addon can group a long list under a single
top-level entry (BazBags now puts its 8 categories under "Category"
instead of taking up 8 rows on every shift+right-click).

## 116 — Shared context-menu sections

Two new primitives that let any addon contribute entries to a context
menu owned by a different addon. Each addon keeps owning its own
trigger (BazBags catches shift+right-click on bag slots, BazBars on
bar slots, etc.); BazCore just provides the registry + assembly so
extensions can show up automatically.

```lua
-- Contribute a section. getItems is called at menu-open time with
-- whatever context the owning addon passes — return nil to skip the
-- section, or an array of {label, onClick, disabled?} / {divider=true}.
BazCore:RegisterContextMenuSection("bag-item", "MyAddon", function(ctx)
    if not ctx.itemID then return end
    return { { label = "Do thing", onClick = function() ... end } }
end)

-- Build + show the menu. Owning addon calls this from its trigger.
BazCore:OpenContextMenu("bag-item", anchor, ctx, {
    title = ctx.itemLink,  -- optional top-level title above sections
})
```

Scopes are strings; current vocabulary is `"bag-item"` (BazBags). More
will land as other addons migrate (BazBars `bar-slot` is a candidate).

## 115 — `BazCore:GetAddonFromStack` for caller attribution

New helper that walks the Lua stack and returns the name of the addon
whose code is currently executing — useful for any addon that hooks a
shared method (a tooltip API, an event dispatcher, etc.) and wants to
attribute the call back to the third-party addon that triggered it.
Skips frames in a configurable set of "noise" addons so `Foo > BazCore
> target` resolves to `Foo` rather than your own hook plumbing.

```lua
local skip = { BazCore = true, BazTooltipEditor = true }
local culprit = BazCore:GetAddonFromStack(3, skip) or "Blizzard"
```

## 114 — Scrollbar visibility tracks scroll-child size changes

`O.AutoHideScrollbar` only watched the scroll frame's `OnSizeChanged`,
which never fires when the *child* re-renders (User Manual pages,
dynamic option pages). That left the scrollbar stuck on whichever
state it was in when the panel was first opened — long pages would
show no scrollbar if a short page had been visible first. The hook
now re-attaches to every scroll child as it's assigned, so visibility
recomputes whenever content height changes.

## 113 — `imageRow` accepts fractional widths

`imageWidth` and `imageHeight` on the `imageRow` block now accept a
value between 0 and 1, interpreted as a fraction of the surrounding
content width. So `imageWidth = 0.5` gives a half-width image column
without the caller needing to know what pixel width the panel is
currently showing. Values >= 1 still mean absolute pixels as before.

## 112 — `imageRow` aspect ratio + caption position fix

The image inside an `imageRow` was using `SetAllPoints` on its
container, so when the column grew to fit the caption the texture
stretched vertically (squished the image) and dragged the caption
anchor below the row's bounds — putting the caption on top of the
next block. Texture is now pinned to a fixed `imageWidth × imageHeight`
at the top of the column, leaving the caption to sit cleanly inside
the row and the row's reported height to actually contain everything.

## 111 — Image caption wrap measurement fix

The line-count fallback added in 110 still didn't catch wrapped
captions because `FontString:GetStringWidth()` on a width-constrained
FontString returns the longest *wrapped* line, not the full string —
so the math always reported one line. Now measured via a hidden,
unconstrained sibling FontString instead. Bottom padding bumped to
16 px while we're here.

## 110 — Image caption padding fix

Wrapped image captions in `image` and `imageRow` blocks no longer
collide with the next content block. Caption height now uses the
larger of the engine-reported height and a line-count estimate
(string width ÷ frame width × line height), and the bottom padding
under each captioned image was bumped from 6 px to 12 px so the
following block always has a visible gap underneath.

## 109 — New `imageRow` content block

Adds `imageRow` to the User Manual / options-page content block
library. Places an image on one side of the row and arbitrary
content blocks alongside it — useful for User Manual pages that
want a "screenshot + short explanation" pairing without each shot
hogging a full-width row.

```lua
{ type = "imageRow",
  texture = "Interface\\AddOns\\YourAddon\\Media\\foo.png",
  imageWidth = 280,        -- image column width; height defaults
                           -- to 16:9 of imageWidth
  imageSide = "left",      -- or "right"
  caption = "...",         -- optional, rendered below the image
  blocks = {
      { type = "h3", text = "..." },
      { type = "paragraph", text = "..." },
      { type = "list", items = { ... } },
  },
}
```

Total row height is whichever column is taller. The text-column
content goes through the same RenderBlockList that drives normal
page content, so anything nests freely (lists, notes, code blocks,
even another imageRow).

No user-visible change in BazCore itself; this is for addon authors
building User Manual pages on top of BazCore.

## 108 — Confirm popups now sit above Edit Mode panels

When the Delete-bar confirm popup (or any other BazCore confirm /
alert) opened while a BazBars Edit Mode settings panel was already
showing, the popup's backdrop landed BEHIND the settings panel while
its buttons and text floated in front — a half-and-half visual that
looked broken. Both frames lived at the same `DIALOG` strata and
frame level, so render order between them was undefined.

The popup is now at `FULLSCREEN_DIALOG` strata, which puts it cleanly
above any DIALOG-level UI. The whole popup — backdrop and content —
renders together on top, the way a confirm dialog should.

## 107 — New BazCore:SafeBool helper for Midnight tainted booleans

Adds a shared `BazCore:SafeBool(b)` helper alongside the existing
`SafeString` and `SafeNumber`. Midnight extended secret-taint to
booleans on some API surfaces (notably `LuaDurationObject:IsZero()`
on cooldown duration objects when the spell data flows through
tainted events) — boolean tests like `if x then` or `not x` throw
`ADDON_ACTION_BLOCKED` on those values. SafeBool round-trips the
value through `string.format("%s", b)` to strip the taint and
returns a clean true/false.

No user-visible change; this is for addon developers building on
BazCore. Existing addons keep working as-is.

## 106 - CPU Monitor widget: explicit source + Start/Stop button
- Widget now declares `source = "BazCore"` so BazWidgetDrawers' Widgets list groups it under BazCore (was falling through to "Other" since the `bazcore_` ID prefix wasn't in BWD's known-prefix list).
- Added a Start/Stop button to the widget's title bar that toggles the `scriptProfile` CVar via the existing `EnableCPUProfiling` / `DisableCPUProfiling` helpers. Tooltip warns the click triggers `/reload`. The button label switches between "Start" (when profiling is off) and "Stop" (when on) and refreshes on every tick.

## 105 - Welcome message: drop redundant "BazCore:" brand prefix
- The header line read "BazCore: BazCore vXXX loaded:" because `BazCore:Print` already prepends the suite-blue "BazCore:" brand prefix and the message itself also led with "BazCore". Switched the header to a raw `print()` so the colored "BazCore" appears once at the start of the line.

## 104 - Welcome message: format as a list
- v102/103's welcome line crammed every Baz addon into a single comma-separated chat line, which wrapped awkwardly. Now prints a header line ("BazCore vXXX loaded:") followed by one indented line per addon. Easier to scan and lines up with how `/whoami`-style addon listings render.

## 103 - Welcome message: defer one tick so BazChat sees it
- v102's welcome `print()` ran inside the BazCoreSelfPages `QueueForLogin` handler, which fires before BazChat's `Replica:Start` handler in the same login queue. At print time `DEFAULT_CHAT_FRAME` was still Blizzard's hidden `ChatFrame1` (BazChat hadn't reassigned it yet), so the message landed on a hidden frame and the user saw nothing.
- Wrapped the welcome print in `C_Timer.After(0, ...)` so it runs after every other PLAYER_LOGIN-queued handler completes, including BazChat's `DEFAULT_CHAT_FRAME = replicaWindow1`. The print now lands on the visible chat window.

## 102 - Suite-wide welcome message
- Login now prints a single "BazCore vXXX, BazBars vYYY, BazBags vZZZ, ..." line listing every registered Baz addon and its version, sorted alphabetically. BazCore itself in suite-blue, individual addons in gold.
- Replaces the per-addon "loaded" prints that some addons (BazChat) were doing on their own. Suppressed when the existing **Show Welcome Messages** toggle (Settings > BazCore > General Settings) is off; that setting now actually does something.

## 101 - Secure Action Popup primitive + CPU Mini Monitor
- New `SecureActionPopup.lua` — generic factory `BazCore:CreateSecureActionPopup(opts)` for popup grids of secure action buttons. Backdrop chrome, 9-slice layout, direction-aware anchoring (UP/DOWN/LEFT/RIGHT), per-popup hidden `SecureHandlerClickTemplate` proxy that toggles via SAB's `type="click"` so right-click on the trigger opens the popup without conflicting with its existing OnClick dispatcher. Combat-safe. Sticky mode (`popup:SetSticky(true)`) suppresses click-outside dismissal so the popup can act as a live preview while another dialog is open. Click-outside dismissal uses `GLOBAL_MOUSE_UP` (not _DOWN) so drag pickups from spellbook / mount journal don't trip it. Used by BazBars flyouts; reusable for any future Baz addon that needs a popup of secure cells.
- New `CPUMiniMonitor.lua` — small floating top-N CPU window for diagnosing in-game spikes without taking over the screen. Subscribes to the same shared sampler the full CPU page uses (no extra ticker overhead). Draggable, position + visibility persisted via `BazCoreDB.cpuMini`. "Baz / All" mode toggle: Baz scope tracks just the suite, All scope iterates every loaded addon (own delta sampler) so third-party hitches show up too. Color-coded share (orange ≥40%, gold ≥20%). Registered with LibBazWidget so widget hosts (BazWidgetDrawers) can dock it.
- `CPUPage.lua` exposes `BazCore:SubscribeCPU`, `GetCPUStateRef`, `CPUGetTrackedAddons`, `CPUFormatRate`, `CPUGetAddonDisplayName` so sibling modules can ride the existing sampler. New `cpuMiniToggle` page block sits below the summary with a Show/Hide button.
- `CPULog.lua` adds `/bazcpu mini` to toggle the floating monitor; help line updated.
- `Popup.lua` `MakeFieldOpt` now forwards `field.live` to range widgets, supporting live-preview consumers.
- `Options/WidgetFactories.lua` range slider's `OnValueChanged` fires `opt.set` mid-drag when `opt.live` is true (default behavior unchanged for callers that don't opt in).

## 026 - DockableWidget API, Modules Page, Minimap Icon Mask
- New `DockableWidget.lua` module exposing the cross-addon dockable widget registry used by BazWidgetDrawers
  - `BazCore:RegisterDockableWidget(widget)` — registers a widget to appear in BazWidgetDrawers's slot stack
  - `BazCore:UnregisterDockableWidget(id)` — removes a widget from the registry
  - `BazCore:GetDockableWidgets()` / `GetDockableWidget(id)` — read the registry
  - `BazCore:RegisterDockableWidgetCallback(fn)` — subscribe to registry changes
  - Widget contract: `id`, `label`, `designWidth`, `designHeight`, `frame`, and optional `GetDesiredHeight`, `GetStatusText`, `GetOptionsArgs`, `OnDock`, `OnUndock`
- New `BazCore:CreateModulesPage(addonName, config)` helper — builds a standard "Modules" subcategory with a flat list of enable/disable toggles, used by BNC for notification modules and by BazWidgetDrawers for dockable widgets
- Minimap button icon now uses a circular alpha mask (`Interface\CHARACTERFRAME\TempPortraitAlphaMask`) so it blends into the tracking border instead of showing as a square inside a ring; icon size bumped 18→20 to fill the new circular frame

## 025 - Addon List Button, Toggle Padding
- Added an "Addon Options" button to Blizzard's AddOn List window that opens directly to the BazCore options category
- Fixed the toggle widget in two-column options panels so multi-line descriptions no longer overflow their card's bottom padding
  - Checkbox now anchors to the top of the widget frame instead of the vertical center

## 024 - Notification Bridge
- Added `BazCore:RegisterNotificationModule(id, info)` for Baz Suite addons to register with BazNotificationCenter
- Added `BazCore:PushNotification(data)` that routes through BNC (no-op if BNC isn't installed)
- Lazy-registers modules on first push so addons don't have to think about load order
- Profile switches now fire a "Profile Changed" toast via the internal `_bazcore` module

## 023 - SetScaleFromCenter, EditMode fixes
- Added BazCore:SetScaleFromCenter() utility for scaling frames from their visual center
- Fixed EditMode position save/restore to use addon object instead of removed Settings module
- Removed references to non-loaded Settings.lua _settingsProxy

## 022 - Unified Profile System
- Profiles now live in BazCoreDB and control all Baz Suite addons at once
- One profile switch changes every addon's configuration together
- Profiles page moved from individual addons into BazCore settings
- Automatic migration of existing per-addon profiles into unified system
- Per-character, per-class, and per-spec profile assignment

## 021 - Global Options Page Builder
- Added BazCore:CreateGlobalOptionsPage() standard page type for global override settings
- Added disabled property support to toggle and range widget factories
- Widgets with disabled=true (or function) gray out and block interaction
- Disabled state re-evaluates on every OnShow for dynamic conditions

## 018 - Audit Fixes
- Auto-wired addon.db profile proxy via CreateDBProxy() in RegisterAddon
- Addons no longer need manual profileProxy boilerplate
- Category changed to "Baz Suite" for addon panel grouping

## 017
- Two-column panel layout now works for flat options pages (no groups required)

## 016 - Options Panel Overhaul
- Two-column bordered panel layout for settings (auto when panel > 500px wide)
- Modern MinimalScrollBar replaces old UIPanelScrollFrameTemplate scroll bars
- Headers use gold/yellow text for visual consistency
- Groups can set `columns = 1` to force single column
- Minimap button menu respects per-addon onClick handler

## 014 - Two-Column Options Panel
- Options panel now auto-uses two-column layout when wide enough (>500px)
- Headers and descriptions span full width across both columns
- Toggles, sliders, inputs, and selects flow into two columns
- Groups can override with `columns = 1` to force single column
- Reduces scrolling on settings pages with many options

## 013 - ObjectPool, DND, Notification Bridge
- Added `BazCore:CreateObjectPool(createFunc, resetFunc)` — reusable object pool for UI recycling
- Added `BazCore:IsDND()` — returns true if in combat or encounter active
- Added `BazCore:PushNotification(data)` — routes to BazNotificationCenter if installed

## 012
- Minimap button now respects hide setting on login/reload

## 011
- SafeString now uses string.format to strip Midnight secret string taint
- tostring() alone does not desecretize strings in Midnight

## 010
- Version now reads from TOC dynamically (no more hardcoded version)
- Minimap tooltip shows BazCore version
- Right-click minimap button opens BazCore settings

## 009
- Settings panel: added Baz Suite version info display
- Settings panel: added welcome message toggle
- Settings panel: added per-addon memory usage with refresh button

## 008
- Added `BazCore:SafeMatch()`, `BazCore:SafeFind()`, `BazCore:SafeString()` for Midnight secret string taint handling

## 007
- Added `BazCore:MakeResizable()` — reusable drag-to-resize handle for any frame
- Supports min/max scale, screen capping, custom get/set callbacks

## 006
- Fixed grid snapping using wrong scale (GetEffectiveScale vs GetScale)
- Snap preview lines and snap-on-drop now align correctly for scaled frames

## 005
- Full Edit Mode framework for all Baz Suite addons
- Blizzard-native nine-slice overlays (cyan highlight, yellow selected)
- Grid snapping with red preview lines during drag
- Selection sync with Blizzard Edit Mode frames
- Configurable settings popup with collapsible sections
- Widget types: slider, checkbox, dropdown, input, nudge, color picker
- Built-in revert and reset position actions
- ESC key closes settings popup
- Smart popup positioning (flips side when near screen edge)
- Dynamic label update API
- Position persistence with effectiveScale compensation

## 004
- Added BazCore settings page (minimap toggle, registered addons list)
- Fixed minimap dropdown not opening addon settings
- Minimap button visibility is now controlled from BazCore settings, not per-addon
