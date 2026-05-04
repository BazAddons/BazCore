# Baz Suite — Developer Reference

| | |
|---|---|
| **Author** | Baz4k |
| **Last Updated** | May 2026 |
| **WoW Version** | Retail 12.0 (Midnight expansion) |
| **Interface Number** | 120005 |
| **License** | GPL v2 (every addon) |
| **Category** | Baz Suite (used as the WoW addon-list category for every addon in the suite) |

This document covers what you need to develop on the Baz Suite — architecture,
public APIs, file layouts, conventions, and per-addon implementation notes. It
is API-level documentation, not a tutorial.

## Table of Contents

1. [Overview](#1-overview)
2. [Addon Inventory](#2-addon-inventory)
3. [BazCore Framework](#3-bazcore-framework)
4. [Addon Registration Pattern](#4-addon-registration-pattern)
5. [Database and Profiles](#5-database-and-profiles)
6. [Options Panel System](#6-options-panel-system)
7. [Edit Mode Framework](#7-edit-mode-framework)
8. [Shared UI Primitives](#8-shared-ui-primitives)
9. [Event System](#9-event-system)
10. [Midnight Secret Taint](#10-midnight-secret-taint)
11. [BazChat](#11-bazchat)
12. [BazNotificationCenter](#12-baznotificationcenter)
13. [BazBars](#13-bazbars)
14. [BazBags](#14-bazbags)
15. [BazWidgetDrawers](#15-bazwidgetdrawers)
16. [BazWidgets](#16-bazwidgets)
17. [BazBrokerWidget](#17-bazbrokerwidget)
18. [BazLootNotifier (maintenance)](#18-bazlootnotifier-maintenance)
19. [BazFlightZoom](#19-bazflightzoom)
20. [BazMap](#20-bazmap)
21. [BazMapPortals](#21-bazmapportals)
22. [Build and Release](#22-build-and-release)
23. [Coding Conventions](#23-coding-conventions)
24. [Known Issues and Gotchas](#24-known-issues-and-gotchas)

---

## 1. Overview

The Baz Suite is a collection of WoW retail addons built on a shared framework
called BazCore.

### One framework

BazCore provides lifecycle management, profiles, the standalone Options window,
page builders, content blocks, list/detail panels, form widgets, the User
Manual host, Edit Mode integration, events, slash commands, the suite-wide
minimap button, shared popup + copy dialog primitives, and a notification
bridge. Individual addons stay thin and focused on their feature surface.

### Consistency

Every addon registers the same way, has the same options-panel structure
(landing page → settings → custom subcategories → profiles), and uses the
same widget types, color palette (gold headers + dark panels), and slash
command patterns.

### BazCore owns the look

All shared visual styling — options panels, Edit Mode overlays, the standalone
Options window chrome, the User Manual chrome, popups, copy dialogs — comes
from BazCore. Change it once in BazCore and every addon updates. Addons should
never build their own settings widgets or popup chrome.

### Modern APIs only

Dragonflight+ APIs throughout. No deprecated `UIDropDownMenu`,
`InterfaceOptionsCheckButtonTemplate`, `GetSpellInfo`, etc. Use `C_Spell`,
`C_Item`, `C_MountJournal`, `MenuUtil`, the Settings API, `MinimalScrollBar`,
`MinimalSliderWithSteppersTemplate`, `EventUtil.ContinueOnAddOnLoaded`,
`NineSliceUtil`, `ScrollUtil.InitScrollFrameWithScrollBar`.

### Profiles

Every addon with user-facing settings uses BazCore's profile system.
Per-character, per-class, per-spec profile assignment. The Profiles
subcategory is always last in an addon's settings tree.

### No globals

Addons access each other via `BazCore:GetAddon("name")`. The only intentional
globals are the `BazCore` table itself and a couple of public API tables
(`BazNotificationCenter` / `BNC`).

### Safe string and number handling

Midnight introduced *secret* tainted values that flow from hardware events.
All string/number ops on data from chat events, aura events, etc. must use
`pcall(string.format, "%s"|"%d", val)` to launder the taint. BazCore exposes
`SafeString` / `SafeMatch` helpers; BNC ships its own `Utils/SafeString` suite.
See [§10](#10-midnight-secret-taint) for details.

---

## 2. Addon Inventory

| Addon | Curse ID | Saved Variable | Repo (`bazsec/...`) |
|---|---|---|---|
| BazCore | 1503896 | `BazCoreDB` | `BazCore` |
| BazBars | 1501110 | `BazBarsDB` | `BazBars` |
| BazBags | 1525946 | `BazBagsDB` | `BazBags` |
| BazChat | 1530174 | `BazChatDB` | `BazChat` |
| BazWidgetDrawers | 1511379 | `BazWidgetDrawersDB` | `BazWidgetDrawers` |
| BazWidgets | 1513522 | `BazWidgetsDB` | `BazWidgets` |
| BazBrokerWidget | 1524619 | `BazBrokerWidgetDB` | `BazBrokerWidget` |
| BazNotificationCenter | 1498445 | `BazNotificationCenterDB` | `BazNotificationCenter` |
| BazLootNotifier | 1076876 | `BazLootNotifierDB` | `BazLootNotifier` |
| BazFlightZoom | 1503675 | `BazFlightZoomSV` | `BazFlightZoom` |
| BazMap | 1404160 | `BazMapDB` | `BazMap` |
| BazMapPortals | 1402800 | `BazMapPortalsDB` | `BazMapPortals` |

> Always check each repo's latest tag for the current version — releases
> happen often and any version numbers above will go stale within days.

### Dependency graph

All addons depend on BazCore. BazWidgetDrawers, BazWidgets, and
BazBrokerWidget additionally depend on each other in a stack:

```
BazCore  ←  BazWidgetDrawers  ←  BazWidgets / BazBrokerWidget
```

BazBars optionally supports Masque for skinning.

---

## 3. BazCore Framework

BazCore is a zero-dependency framework library.

### TOC load order

```
Libs/LibStub/LibStub.lua
Libs/LibBazWidget-1.0/LibBazWidget-1.0.lua
```

### Core modules

| File | Purpose |
|---|---|
| `Core.lua` | Addon registry, lifecycle, `RegisterAddon`, `AddonMixin` |
| `Events.lua` | Unified WoW event + custom event system |
| `Profiles.lua` | Named profile system, `CreateDBProxy`, profile management |
| `Commands.lua` | Declarative slash command framework |
| `UI.lua` | Colors, backdrops, fade helpers, `MakeResizable`, `CreatePortraitWindow`, `CreateItemButton` |
| `Timers.lua` | Managed timers, throttle, debounce |
| `ObjectPool.lua` | Reusable object pool factory |
| `Format.lua` | Money / time / number formatting, `SafeString`, `SafeMatch` |
| `Locale.lua` | Localization stub *(currently unused)* |
| `Menu.lua` | Context menu wrapper *(currently unused)* |
| `Animations.lua` | Animation presets *(currently unused)* |
| `MinimapButton.lua` | Single shared minimap button for all Baz addons |
| `ButtonGlow.lua` | Spell proc overlay glow (used by BazBars + BWD widgets) |
| `Compartment.lua` | Addon Compartment (Dragonflight minimap dropdown) |
| `Keybinds.lua` | Override keybinding framework *(currently unused)* |
| `EditMode.lua` | Edit Mode framework |
| `Serialization.lua` | Table serialization + Base64 (used by BazBars export) |

### Options subsystem

| File | Purpose |
|---|---|
| `Options/Constants.lua` | Shared layout/font/color constants, `O.BuildSelectionHighlight`, `O.ResolveListWidth`, `O.BuildTitleBar` |
| `Options/WidgetFactories.lua` | Form widgets: toggle, range, input, select, execute, header, description |
| `Options/LayoutEngine.lua` | `O.RenderWidgets` layout engine |
| `Options/ListDetail.lua` | Left-list / right-detail panel (`BuildListDetailPanel`) |
| `Options/PageBuilders.lua` | `CreateLandingPage`, `CreateModulesPage`, `CreateGlobalOptionsPage`, `CreateManagedListPage` |
| `Options/ContentFactories.lua` | Rich content blocks: h1–h4, paragraph, lead, caption, quote, list, image, note, code, divider, spacer, table, collapsible |
| `Options/SettingsSpec.lua` | Single-source-of-truth spec API that generates Options-page args + Edit Mode popup fields from one declaration |
| `Options/Registration.lua` | Standalone Options window itself, `RegisterOptionsTable`, `AddToSettings`, `OpenOptionsPanel`, `RefreshOptions` |
| `Options/UserGuide.lua` | User Manual host + `RegisterUserGuide` |

### Top-level utilities

| File | Purpose |
|---|---|
| `OptionsPanel.lua` | Loader stub (back-compat; real code lives in `Options/`) |
| `CopyDialog.lua` | Reusable scrollable copy/paste/import dialog |
| `Popup.lua` | Generic confirm / alert / form popup primitive |
| `MemoryLog.lua` | Per-addon memory tracking + dump dialog |
| `MemoryPage.lua` | Live per-addon memory graph (BazCore sub-page) |
| `AddonListButton.lua` | "Addon Options" button on Blizzard's AddOn list |
| `IconPicker.lua` | Reusable icon picker dialog |
| `DockableWidget.lua` | Public widget API on top of LibBazWidget-1.0 |

### Key globals

| Global | Purpose |
|---|---|
| `BazCore` | Framework table |
| `BazCore.VERSION` | Read from TOC at load |
| `BazCore.addons` | Registry of registered addons |
| `BazCore.AddonMixin` | Metatable for addon objects |
| `BazCore._Options` | Internal options namespace (`O.*` helpers) |

A few modules (`Locale`, `Menu`, `Animations`, `Keybinds`) are built but not
yet consumed by any shipped addon. They are framework-ready utilities and
part of the standard library — keep them, they are not dead code.

---

## 4. Addon Registration Pattern

Every addon registers with BazCore using:

```lua
local addon = BazCore:RegisterAddon("AddonName", {
    title         = "Display Name",
    savedVariable = "AddonNameDB",
    profiles      = true,
    defaults      = {
        setting1 = true,
        setting2 = 1.0,
    },
    slash         = { "/cmd", "/longcmd" },
    commands      = {
        subcmd = {
            desc    = "Description",
            handler = function(args) ... end,
        },
    },
    defaultHandler = function() ... end,    -- bare /cmd with no args
    minimap = {
        label   = "AddonName",
        icon    = 123456,                   -- optional, auto-read from TOC
        onClick = function()                -- defaults to OpenOptionsPanel
            ...
        end,
    },
    onLoad  = function(self) ... end,       -- after ADDON_LOADED, SV ready
    onReady = function(self) ... end,       -- after PLAYER_LOGIN
})
```

### Lifecycle order

1. TOC files load synchronously
2. `ADDON_LOADED` fires per addon
3. `EventUtil.ContinueOnAddOnLoaded` triggers:
   1. SavedVariables initialized
   2. Profiles initialized (when `profiles = true`)
   3. `addon.db` wired via `CreateDBProxy`
   4. `onLoad` fires
   5. Slash commands registered
   6. Minimap entry registered
4. `PLAYER_LOGIN` fires
5. `onReady` fires

### Addon object

Returned by `RegisterAddon`:

| Field / Method | Purpose |
|---|---|
| `addon.name` | Addon name string |
| `addon.config` | The config table passed in |
| `addon.loaded` | `true` after `onLoad` |
| `addon.db` | `{ profile = metatable }` proxy |
| `addon:GetSetting(key)` | Reads `addon.db.profile[key]` |
| `addon:SetSetting(key, value)` | Writes `addon.db.profile[key]` |
| `addon:On(event, handler)` | Register WoW event |
| `addon:Off(event)` | Unregister WoW event |
| `addon:Print(msg)` | Chat print with addon-name prefix |

Other files access the addon object via:

```lua
local addon = BazCore:GetAddon("AddonName")
```

> Never share the addon object via a global — always go through `GetAddon`.

---

## 5. Database and Profiles

When `profiles = true` is set, BazCore:

1. Calls `InitProfiles()` to create the profile structure in the SV
2. Creates a `"Default"` profile from the addon's defaults
3. Wires `addon.db = BazCore:CreateDBProxy(name)`

The DB proxy:

```lua
addon.db = {
    profile = setmetatable({}, {
        __index    = function(_, key)         -- reads sv.profiles[active][key]
        __newindex = function(_, key, value)  -- writes sv.profiles[active][key]
    })
}
```

Access settings via:

```lua
addon:GetSetting("key")    -- preferred, also handles default fallback
addon.db.profile.key       -- direct access
```

### Saved variable layout

```lua
AddonNameDB = {
    activeProfile = "Default",
    profiles = {
        Default     = { key1 = val1, ... },
        MyProfile   = { ... },
    },
    assignments = {
        ["CharName - Realm"] = "ProfileName",
        ["Warrior"]          = "TankProfile",
    },
}
```

### Special case — BazNotificationCenter

BNC flattens the proxy: `addon.db = bncAddon.db.profile`. All BNC code
reads/writes via `addon.db.key` rather than `addon.db.profile.key`. This is
for back-compat with BNC's pre-suite codebase. Other addons use the standard
`addon.db.profile.key` shape.

### Profile management API

```lua
BazCore:GetActiveProfile(addonName)
BazCore:SetActiveProfile(addonName, profileName)
BazCore:CreateProfile(addonName, profileName)
BazCore:CopyProfile(addonName, from, to)
BazCore:DeleteProfile(addonName, profileName)
BazCore:RenameProfile(addonName, oldName, newName)
BazCore:ResetProfile(addonName, profileName)
BazCore:ListProfiles(addonName)
BazCore:AssignProfile(addonName, scope, profileName)
BazCore:GetProfileOptionsTable(addonName)   -- for Profiles subcategory
```

---

## 6. Options Panel System

All addon settings render inside BazCore's **standalone Options window**, not
through Blizzard's Settings panel. The Settings panel still has a stub canvas
for BazCore (the "Addon Options" button injected into Blizzard's AddOn List
jumps to our window) but every other addon lives only inside the Baz Suite
window.

### Window structure

- Bottom tab strip: one tab per registered Baz addon, click to switch
- Left sidebar: sub-categories of the active addon (User Manual, General
  Settings, custom pages, Profiles)
- Right content panel: renders the selected sub-category
- Dark spec-background atlas backing, ESC closes, draggable, position
  persists across sessions

### Registration

```lua
BazCore:RegisterOptionsTable("AddonName", function()
    return { name = "...", type = "group", args = { ... } }
end)
BazCore:AddToSettings("AddonName", "Display Name")
BazCore:AddToSettings("AddonName-Settings", "General Settings", "AddonName")
```

The third argument to `AddToSettings` is the parent — pass an addon name to
make the entry a sub-category in that addon's tab.

### Page-builder helpers

From `Options/PageBuilders.lua`:

| API | Purpose |
|---|---|
| `BazCore:CreateLandingPage(addonName, content)` | Description / Features / Quick Guide / Slash Commands intro page. |
| `BazCore:CreateModulesPage(addonName, config)` | Flat list of enable/disable toggles per module. |
| `BazCore:CreateGlobalOptionsPage(addonName, config)` | Per-key override toggles cascading to all widgets/modules. |
| `BazCore:CreateManagedListPage(addonName, config)` | List-detail editing pages — categories, drawers, bars, profiles. Auto-h1 detail title, intro / introBlocks, optional Create / Reset buttons, source-based collapsible sections. Returns a function so `getItems` re-runs on each Refresh. |

### Widget types

From `Options/WidgetFactories.lua`:

| `type` | Purpose |
|---|---|
| `"header"` | Gold section header with divider line |
| `"description"` | Text block (default `GameFontNormal`, `fontSize = "small"` for smaller) |
| `"toggle"` | Checkbox with label + optional desc |
| `"range"` | Slider with click-anywhere-to-snap overlay, editable value box, `set` on release |
| `"input"` | Text input (Enter commits, Esc reverts) |
| `"select"` | Dropdown via `MenuUtil`, auto-sized to fit longest |
| `"execute"` | Button, optional confirm dialog, `width = "half"` for side-by-side layout |

### Content blocks

From `Options/ContentFactories.lua` — used by the User Manual and any
settings page that wants documentation-style content:

| Block | Purpose |
|---|---|
| `h1` / `h2` / `h3` / `h4` | Heading hierarchy with optional underline accent |
| `paragraph` | Body text, wrapped, normal color |
| `lead` | White, larger — for intros |
| `caption` | Small grey, centered — for image captions |
| `quote` | Indented + left vertical bar |
| `list` | Bulleted/numbered, three nesting levels |
| `image` | Texture / atlas / fileID with caption |
| `note` | Tip / info / warning / danger callouts |
| `code` | Monospace block (slash commands, macros) |
| `divider` | Thin rule |
| `spacer` | Blank vertical space |
| `table` | Header row + striped data rows |
| `collapsible` | Animated expand/collapse with persistent state |

Mix content blocks and form widgets in the same `args` table — paragraphs
between toggles, h3 section headers, notes for important caveats, etc. The
renderer (`Options/LayoutEngine.lua`'s `O.RenderWidgets`) handles both
seamlessly.

### Widget properties

Common fields on every widget:

| Property | Purpose |
|---|---|
| `order` | Sort order (use gaps: 1, 10, 20, 30, 90) |
| `name` | Display label |
| `desc` | Tooltip / sub-label (description widget uses `name`; content blocks use `text`) |
| `get` / `set` | Standard read/write callbacks |

Type-specific:

| Property | Applies to | Purpose |
|---|---|---|
| `min` / `max` / `step` | range | Slider bounds |
| `isPercent` | range | Display as percentage |
| `values` | select | Table or function returning `{ value = label }` |
| `func` | execute | Click handler |
| `fontSize` | description | `"small"` for smaller font |
| `width = "half"` | execute | Half-width side-by-side layout |

#### Confirm-on-execute properties

Set on an `execute` widget to pop a `BazCore:Confirm` before firing `func`:

| Property | Default | Purpose |
|---|---|---|
| `confirm` | `false` | Set `true` to enable the confirm |
| `confirmTitle` | `"Confirm"` | Gold dialog title |
| `confirmText` | `"Are you sure?"` | Body text |
| `confirmStyle` | `"primary"` | `"primary"` (gold) or `"destructive"` (red) |
| `confirmAcceptLabel` | `"Yes"` | Accept-button label |
| `confirmCancelLabel` | `"No"` | Cancel-button label |

Example:

```lua
deleteBar = {
    type = "execute",
    name = "|cffff4444Delete This Bar|r",
    confirm            = true,
    confirmTitle       = "Delete bar?",
    confirmText        = "Delete Bar 1? Can't be undone.",
    confirmStyle       = "destructive",
    confirmAcceptLabel = "Delete",
    confirmCancelLabel = "Cancel",
    func = function() addon:DeleteBar(1) end,
},
```

### SettingsSpec API

From `Options/SettingsSpec.lua`. A single-source-of-truth spec format that
generates **both** the Options page args **and** the Edit Mode popup field
list from one declaration. Addons that want their settings to appear in two
places (the full Options page and the in-place Edit Mode popup for a
draggable frame) declare a spec once and call:

```lua
BazCore:BuildOptionsArgsFromSpec(spec)        -- for Options page
BazCore:BuildEditModeFieldsFromSpec(spec)     -- for Edit Mode popup
```

Each spec entry can flag itself as Options-only or shared. Used by BazChat
for the chat window settings; reduces duplication when the same toggle/slider
needs to appear on both surfaces.

### List/detail panel

From `Options/ListDetail.lua`:

- `BuildListDetailPanel` renders a left list of clickable rows + right
  detail panel. The page's options table provides
  `args = { group = { type="group", args = { item1 = ..., item2 = ... } } }`
  and the children become the list rows.
- Source-based collapsible sections kick in automatically when any child
  has a `source` field.
- Selection persists across refreshes (stored on the container frame).
- Gold-gradient selection highlight, hover state, native scroll bars.

### User Manual

From `Options/UserGuide.lua`:

```lua
BazCore:RegisterUserGuide("AddonName", {
    title = "Display Name",
    intro = "Lead paragraph.",
    pages = {
        {
            title    = "Overview",
            blocks   = { ... },
            children = { ... },         -- one level of sub-pages
        },
        {
            title    = "Slash Commands",
            text     = "Plain-text page body (legacy)",
            sections = { { heading = "...", text = "..." }, ... },
        },
    },
})
```

A **User Manual** sub-category appears under that addon's tab. The right
panel renders content blocks; the left panel is a tree with one level of
nested children.

### Naming convention for subcategories

| Pattern | Use |
|---|---|
| `AddonName` | Main / landing page |
| `AddonName-Settings` | Settings subcategory (or `-General-Settings`) |
| `AddonName-Categories` | Custom subcategory |
| `AddonName-Profiles` | Profiles subcategory |

Use hyphens, not underscores. Use the full addon name, not abbreviations.

---

## 7. Edit Mode Framework

BazCore wraps Blizzard's Edit Mode for any addon with on-screen draggable
frames.

### Registration

```lua
BazCore:RegisterEditModeFrame(frame, {
    label           = "Frame Name",
    addonName       = "AddonName",
    positionKey     = "position",
    defaultPosition = { x = 0, y = 150 },
    settings = {
        { type = "slider",   key = "scale",   label = "Scale", ... },
        { type = "checkbox", key = "enabled", label = "Enabled" },
        { type = "dropdown", key = "mode",    label = "Mode", ... },
        { type = "nudge" },
    },
    actions  = { { label = "Reset Position", callback = ... } },
    sections = {
        { name = "Appearance", collapsed = false },
        { name = "Behavior",   collapsed = true },
    },
})
```

### Features

- Nine-slice overlays (cyan when Edit Mode active, yellow when selected)
- Grid snapping with red preview lines during drag
- Selection sync with Blizzard Edit Mode frames
- Configurable settings popup with collapsible sections
- Widget types: slider, checkbox, dropdown, input, nudge, color picker
- ESC closes the popup
- Smart popup positioning (flips side near screen edges)
- Dynamic label: `BazCore:UpdateEditModeLabel(frame, newLabel)`

> Use `GetScale()` for grid snapping, **not** `GetEffectiveScale()`. Grid
> coords are in `UIParent` coordinate space.

The settings list can be generated from a SettingsSpec via
`BazCore:BuildEditModeFieldsFromSpec(spec)` so the Options page and the Edit
Mode popup share a single declaration.

---

## 8. Shared UI Primitives

BazCore ships several reusable UI primitives so addons don't hand-roll chrome
that should look uniform across the suite.

### 8.1 Popup

From `Popup.lua`. A generic confirm / alert / form popup primitive that
replaces both `StaticPopupDialogs` and the hand-rolled `BackdropTemplate`
frames every addon would otherwise write.

```lua
BazCore:OpenPopup(opts)        -- full popup with optional fields + buttons
BazCore:Confirm(opts)          -- yes/no confirm with destructive style
BazCore:Alert(opts)            -- single OK button
BazCore:ClosePopup()           -- close the current popup
```

#### Common opts

| Field | Purpose |
|---|---|
| `title` | Required, gold header text |
| `body` | Optional, body paragraph (auto-wrapped) |
| `width` | Optional, defaults to a sensible width |
| `fields` | Optional, array of form fields built via `O.widgetFactories` (same shape as Options-page widgets — input, toggle, select, range) |
| `buttons` | Array of `{ label, style, onClick }` where `style` is `"default"` / `"primary"` (gold) / `"destructive"` (red) |

#### Confirm-specific opts

| Field | Default | Purpose |
|---|---|---|
| `acceptLabel` | `"OK"` | Accept-button label |
| `cancelLabel` | `"Cancel"` | Cancel-button label |
| `acceptStyle` | `"primary"` | `"primary"` (gold) or `"destructive"` (red) |
| `onAccept` | — | Fires on accept |
| `onCancel` | — | Fires on cancel |

The popup is a singleton frame, draggable, ESC-closes, auto-sized to content.
Uses `O.widgetFactories` for any form fields so input/toggle/select/range
controls match the rest of BazCore exactly.

### 8.2 Copy Dialog

From `CopyDialog.lua`. Reusable scrollable text-export / text-import popup.
WoW's sandbox can't read or write the OS clipboard, so the standard idiom is
*"show a frame with an EditBox the user can Ctrl+A / Ctrl+C / Ctrl+V on."*
This bundles that frame plus the niceties (Select All button, ESC close,
drag, char count) in one shared instance.

```lua
BazCore:OpenCopyDialog(opts)   -- show the dialog
BazCore:CloseCopyDialog()      -- hide it
```

| Field | Purpose |
|---|---|
| `title` | Required, gold header text |
| `subtitle` | Optional grey instruction line |
| `content` | Pre-fill text. For export, the data to copy. For import, pass `nil` / `""` to start with empty box. |
| `editable` | Defaults `true` |
| `width` / `height` | Optional, sensible defaults |
| `onAccept` | Callback for import flows; if set an Accept button appears next to Close |
| `acceptText` | Default `"Accept"` |
| `onClose` | Optional close callback |

Used by BazChat (copy-chat icon per chat window), BNC (memory log dump), and
any export/import flow in the suite.

### 8.3 Icon Picker

From `IconPicker.lua`. Reusable icon picker dialog. Search box, paged grid of
icons, returns the chosen FileID via callback.

```lua
BazCore:OpenIconPicker({
    title    = "Pick an icon",
    current  = currentFileID,
    onPick   = function(fileID) ... end,
})
```

### 8.4 Minimap Button

From `MinimapButton.lua`. A single shared minimap button hosts entries for
every Baz addon registered with `minimap = { ... }` in its addon config.
Click opens a menu of registered addons; clicking an entry runs that addon's
`onClick` (default: open its options page).

Addons get an entry automatically by including a `minimap` table in their
`RegisterAddon` config — no separate registration call needed.

### 8.5 Memory Log

From `MemoryLog.lua` and `MemoryPage.lua`. Per-addon memory tracking. Records
`UpdateAddOnMemoryUsage` snapshots, exposes them via:

```lua
BazCore:DumpMemoryLog()        -- open a CopyDialog with the log
```

The MemoryPage subcategory in BazCore's options shows a live memory graph
per registered Baz addon. Useful for catching leaks during development.

---

## 9. Event System

WoW events via the AddonMixin:

```lua
addon:On("EVENT_NAME", function(event, ...) end)
addon:On({"EVENT1", "EVENT2"}, function(event, ...) end)
addon:Off("EVENT_NAME")
```

BazCore-level events:

```lua
BazCore:On("EVENT", handler)
BazCore:Fire("CUSTOM_EVENT", ...)
```

Each addon's handlers are keyed by addon name, so multiple addons can listen
to the same WoW event without conflict.

### BNC internal events

BNC has its own `CallbackRegistry` (`addon.Events`) for BNC-only custom
events like `NOTIFICATION_ADDED`, `TOAST_REQUESTED`, `SETTING_CHANGED`. These
are **not** WoW events and do **not** go through BazCore. They wire BNC's
internal files (`Panel`, `Toast`, `ToggleButton`, etc.) together.

```lua
addon.Events:Register("EVENT_NAME", callback)
addon.Events:Trigger("EVENT_NAME", ...)
addon.Events:Unregister("EVENT_NAME", callback)
```

---

## 10. Midnight Secret Taint

WoW 12.0 (Midnight) added *secret* tainted values that flow from hardware
events (`CHAT_MSG_*`, aura data, spell info, etc.). They behave differently
from old-style protected-frame taint and require explicit laundering before
they can be safely compared, concatenated, or set as secure-frame attributes.

### Secret strings

- `tostring()` returns **another** secret string — does **not** strip taint
- `string.format("%s", str)` strips taint but can throw on protected strings
- Correct:
  ```lua
  local ok, clean = pcall(string.format, "%s", str)
  ```
- Helpers: `BazCore:SafeString(str)`, `BazCore:SafeMatch(str, pattern)`
- BNC has its own suite: `BNC.SafeMatch` / `SafeFind` / `SafeGsub` / etc.

### Secret numbers

- Auras and spellIDs from events come as secret numbers
- Direct `==` comparisons on secret numbers don't always work
- Correct:
  ```lua
  local ok, clean = pcall(function()
      return tonumber(string.format("%d", secretNum))
  end)
  ```
- Helper: `BazCore:SafeNumber(num)` — rounds-trips via `%d` first,
  falls back to `%f`, returns a clean Lua number or nil

### Secret booleans

- Some Midnight APIs return tainted booleans — notably
  `LuaDurationObject:IsZero()` on cooldown duration objects when the
  underlying spell data carries secrets
- Direct boolean tests (`if x then`, `not x`) on a tainted bool throw
  `ADDON_ACTION_BLOCKED`; even pcall around the test isn't enough
  because the throw happens inside the test, not at the assignment
- Two paths:
  1. **Prefer `:HasSecretValues()` as a gate** — that method is
     documented `ReturnsNeverSecret = true`, so its bool is always
     safe. When it returns false, the object's other booleans
     (`:IsZero()`, etc.) are also safe to test.
  2. **Use `BazCore:SafeBool(b)` to launder** when you have a value
     of unknown taint and need to test it directly. Round-trips
     through `string.format("%s", b)` and returns a clean true/false
     by string comparison.

### Typical offenders

- Chat event handlers (BLN, BNC modules, BazBags pin parsing, BazChat
  formatter)
- Aura iteration (BazFlightZoom mount detection)
- Spell info from `C_Spell.GetSpellInfo` (BazBars button names)
- Setting a tainted string as a button `SetAttribute` = **silent failure**;
  always launder before `SetAttribute`
- Filter callbacks for chat: Blizzard already wraps these in
  `securecallfunction`, so do channel-list maintenance and tainted string
  ops inside the filter rather than in `HookOnEvent`

---

## 11. BazChat

Modern chat replacement built on Blizzard's chat primitives:
`ScrollingMessageFrame`, `ChatFrameMixin`, `ChatFrameEditBoxTemplate`,
`TabSystemTemplate`. Hides Blizzard's default chat windows and creates its
own, owning the lifecycle, tabs, channel filtering, fade modes, persistence,
and timestamp rendering end-to-end while preserving the standard message
formatter, hyperlinks, edit-box history, BN whisper routing, and combat log.

### Key concepts

- **Path B replica**: Blizzard's default chat hidden via `HideDefault.lua`;
  BazChat owns the windows from scratch
- `ChatFrameMixin` layered onto our frames so the standard formatter works
  natively (color codes, hyperlinks, `/me`, etc.)
- `DEFAULT_CHAT_FRAME` repointed to BazChat's General tab so other addons
  writing to it land in our pipe
- Standard chat dispatch and filter pipeline preserved — the existing
  `ChatFrameUtil.AddMessageEventFilter` hooks continue to work
- Per-tab channel filtering with right-click popup (every chat category +
  every joined channel as individual toggles)
- Two-column timestamp gutter rendering with channel-colored vertical bar
  per message (green for guild, pink for whispers, custom-channel colors
  honored from `ChatTypeInfo`)
- Persistent history across `/reload` and relog (default 500 lines per tab,
  configurable 100–2000)
- Auto-show modes per tab: Always / In a city / In a party / In a raid /
  In combat / In a battleground / In a dungeon
- Hold-2s drag-to-reorder for tabs, persists across `/reload`
- Per-frame copy-chat icon at top-right (uses `BazCore:OpenCopyDialog`)
- Edit-box typed-message history with Up/Down arrow cycling
  (`SetAltArrowKeyMode(false)` so the editbox consumes arrow keys)

### Files

| File | Purpose |
|---|---|
| `Core/Init.lua`, `Core/Modules.lua`, `Core/Frames.lua` | Bootstrap, module registry, shared chat-frame helpers |
| `Replica/HideDefault.lua` | Hide Blizzard's default chat scaffolding (and `Restore()` for cleanup) |
| `Replica/BazChat.xml` | Frame templates (`BazChatFrameTemplate`, etc.) |
| `Replica/Chrome.lua` | NineSlice frame chrome |
| `Replica/Tabs.lua` | Shared TabSystem strip, chat-type binding, Trade detect |
| `Replica/AutoHide.lua` | Tri-state fade for scrollbar, tab strip, background |
| `Replica/Channels.lua` | Per-tab channel routing + right-click channel popup |
| `Replica/Persistence.lua` | Chat history saved across `/reload` and relog |
| `Replica/Timestamps.lua` + `Replica/TimestampOverlay.lua` | Two-column timestamp rendering with channel-colored gutter |
| `Replica/ChannelNames.lua` | Channel name shortening (`[Guild]` → `[g]`, strip numeric prefix and zone suffix from custom channels) |
| `Replica/SettingsSpec.lua` | Single source of truth for Options page + Edit Mode popup |
| `Replica/Window.lua` | SMF lifecycle, dock, `ApplySettings` (composes the modules above) |
| `Replica/History.lua` | Persistent typed-message arrow-key history |
| `Replica/TabDrag.lua` | Hold-2s drag-to-reorder |
| `Replica/CopyChat.lua` | Per-frame copy icon + `BazCore:OpenCopyDialog` wrapper |
| `Replica/Init.lua` | `PLAYER_LOGIN` bootstrap |

---

## 12. BazNotificationCenter

The most complex addon in the suite — a notification center with toasts plus
persistent history and 20 modules covering 17+ event categories.

### Globals

| Global | Purpose |
|---|---|
| `BazNotificationCenter` | Full name |
| `BNC` | Short alias for module authors |

### Public API

Used by modules:

```lua
BNC:RegisterModule({ id, name, icon })
BNC:RegisterModuleOptions(moduleId, optionsDefs)
BNC:CreateGetSetting(moduleId)              -- returns function(key)
BNC:Push(data)                              -- returns notification
BNC:NewNotification(moduleId)               -- returns builder chain
BNC:Listen(events, handler)                 -- returns control
BNC:OnChatMessage(event, pattern, handler)
BNC:DismissNotification(id)
BNC:DismissAll(moduleFilter)
BNC:GetNotifications(moduleFilter)
BNC:ToggleDND(state)        BNC:IsDND()
BNC:HasTomTom()             BNC:SetWaypoint(waypointData)
BNC:CreateDeduplicator(windowSeconds)
BNC:CreateAccumulator(flushDelay, onFlush)

-- Safe-string helpers
BNC.SafeMatch  BNC.SafeFind  BNC.SafeGsub
BNC.SafeLower  BNC.SafeSub   BNC.SafeLen
BNC.StripEscapes
```

### Lifecycle

1. BazCore handles `ADDON_LOADED`, SV init, profile wiring
2. `onLoad` migrates flat SV data, flattens db proxy, fires `CORE_LOADED`
3. `CORE_LOADED` → UI initializes (Panel, Toast, ToggleButton, Registry)
4. `PLAYER_ENTERING_WORLD` → fires `PLAYER_READY`
5. Modules call `BNC:RegisterModule` + `BNC:RegisterModuleOptions` on load

### Notification flow

```
Module: BNC:Push(data)
  → validate module exists + enabled
  → deduplication check (5-second window, same module + title)
  → create notification object (id, module, title, message,
     icon, priority, ...)
  → save to persistent history (addon.History_AppendEntries)
  → NOTIFICATION_ADDED → Panel + ToggleButton update
  → If toasts enabled and not DND: TOAST_REQUESTED
  → If sounds enabled and not DND: priority-based sound
```

### Module pattern

All 20 follow this pattern:

```lua
local MODULE_ID  = "mail"
local GetSetting = BNC:CreateGetSetting(MODULE_ID)

BNC:RegisterModule({ id = MODULE_ID, name = "Mail", icon = "..." })
BNC:RegisterModuleOptions(MODULE_ID, { ... })

BNC:Listen("UPDATE_PENDING_MAIL", function(event, ...)
    if GetSetting("showNewMail") == false then return end
    BNC:Push({ module = MODULE_ID, title = "New Mail", ... })
end)
```

### Shipped modules (20)

Achievements, Auction, Calendar, Collections, Group, Instance, Inventory,
Keystone, Loot, Mail, Professions, Quests, Rares, Reputation, Social, System,
TalkingHead, Vault, XP, Zones.

### History

Built in (no separate addon). Stored as:

```lua
BazNotificationCenterDB.history = {
    days     = { ["YYYY-MM-DD"] = { entries... }, ... },
    dayIndex = { "YYYY-MM-DD", ... },
}
```

Accessed via `addon.History_Search`, `History_AppendEntries`, etc. Global
wrappers: `BNC_History_Search` / `BNC_History_AppendEntries` / etc.

---

## 13. BazBars

Custom action bars independent of Blizzard's 1–120 action slots.

### Key concepts

- Buttons use `SecureActionButtonTemplate` (combat-safe casting)
- Each bar is a frame with a grid of buttons (up to 24×24, 576 buttons)
- Button payloads: spells, items, macros, mounts, battlepets, equipment
  sets, toys
- Macros stored by **name** (not index) so they survive macro reordering
- Mounts and battlepets use an internal floating-cursor move system

### Button move system

Shift-drag uses a dual system:

1. WoW cursor (`PickupSpell` / `PickupMacro` / etc.) — for default-bar drops
2. Internal `pendingMove` + floating cursor icon — for BazBar-to-BazBar

A `C_Timer.NewTicker` watches the WoW cursor; when it clears, internal state
is cleaned up. Swap chain: drop A on B, B goes to internal cursor, click C
to place B (C goes to cursor if occupied).

### Range indicator

`UpdateUsable()` checks `_outOfRange` first, then normal usability.
Out-of-range = icon red `(0.8, 0.1, 0.1)` + frame / hotkey / name.

### Keybinds

`SetOverrideBindingClick` with `priority = true` (overrides default WoW
bindings). Persisted in `addon.db.profile.keybinds[buttonName] = key`.

### Masque

Optional. Each bar creates a Masque group; buttons register `Icon`,
`Cooldown`, `Normal`, `Pushed`, `Highlight`, `Count`, `HotKey`, etc.

### Files

| File | Purpose |
|---|---|
| `Constants.lua` | Globals, defaults, accepted button types |
| `Core.lua` | `RegisterAddon`, event handlers, range ticker |
| `BazBars.xml` | Button template (`SecureActionButtonTemplate`) |
| `Button.lua` | Button creation, drag/drop, textures, cooldowns, range, tooltips (largest file, ~850 lines) |
| `Bar.lua` | Bar creation, layout, visibility, Edit Mode, Masque |
| `Dialogs.lua` | Macrotext editor, export / import dialogs |
| `Keybinds.lua` | Quick keybind mode UI |
| `Options.lua` | Landing, global options, bar options, profiles |

---

## 14. BazBags

Unified bag panel that replaces Blizzard's combined-bag UI. All bags plus
the reagent bag in one window.

### Key concepts

- Hooks Blizzard's bag-toggle entry points: `ToggleAllBags`, `OpenAllBags`,
  `OpenBackpack`, `CloseAllBags`. The B key + every other addon's bag toggle
  lands here.
- Slots use `ContainerFrameItemButtonTemplate` (Blizzard's secure bag-slot
  template). Cooldown sweep, quality border, drag/drop, click-to-use,
  shift-click-to-link all behave identically to default bags.
- Two display modes:
  - `"bags"` — per-bag-type sections (Bags + Reagents) with collapsible
    headers — Blizzard-style default
  - `"categories"` — auto-classify items into 6 default categories
    (Equipment / Consumables / Trade Goods / Quest Items / Junk / Other),
    separated by thin divider rows
- Bags-mode "Separate Each Bag" sub-option renders one thin-divider section
  per equipped bag using the same chrome categories mode uses

### Categories system

- Categories are persisted/editable: rename, reorder, hide, delete, create
  custom. Settings page is built on `BazCore:CreateManagedListPage`.
- Auto-classifier in `Categories.Classify` routes by item class + quality.
  Lookup by internal key (not display name) so renaming doesn't break the
  classifier.
- Per-item pins override the classifier. Three ways to pin:
  1. Shift+right-click on a bag item → MenuUtil context menu
  2. Categorize mode (middle-click portrait) → gold "+" drop slots at the
     end of each category's grid
  3. Settings page input box

### Categorize mode

Explicit toggle on middle-click of the portrait icon, or
`/bbg categorize`. State is in-memory only (resets on `/reload`). When on,
every category divider appears (incl. empty + hidden ones), each with a
gold "+" drop slot for click-to-pin / drag-to-pin.

### Three-button portrait

| Click | Action |
|---|---|
| Left-click | Sort (`C_Container.SortBags`) |
| Middle-click | Toggle Categorize mode |
| Right-click | Bag-change popup (4 equippable bag slots + reagent) |

### Layout

- Search box (`BagSearchBoxTemplate`) at top-left, filters every bag
- Money display (`ContainerMoneyFrameTemplate`) at top-right
- Tracked-currency strip at bottom (green border), removes Blizzard's
  Show-on-Backpack cap and packs into multiple rows
- `Refresh` re-anchors the frame to TOPLEFT before resizing so toggling
  Categorize mode grows the frame downward instead of from the centre

### Files

| File | Purpose |
|---|---|
| `Core.lua` | `RegisterAddon`, slash, Settings sub-page |
| `Categories.lua` | Persisted category data + auto-classifier |
| `Layouts.lua` | Categories-mode + per-bag-mode rendering; divider pool, drop-slot pool |
| `Bag.lua` | Panel chrome, slot management, `Refresh` |
| `CategoriesPage.lua` | Categories settings page (built on `CreateManagedListPage`) |
| `UserGuide.lua` | User Manual |

---

## 15. BazWidgetDrawers

Slide-out side drawer that hosts a vertical stack of dockable widgets.

### Key concepts

- Anchors flush to the left or right screen edge, full height
- Pull-tab handle (Blizzard atlas) slides the drawer open/closed
- Smart fade system fades all chrome together while keeping widget content
  full-opacity (so quest text, minimap, etc. stay readable)
- Lock mode hides all chrome, tightens spacing, disables collapse
- Multiple drawer presets with tab switching
- Per-widget collapse, drag-to-reorder, floating mode (Edit Mode detach)

### Widget registry

The widget registry is provided by LibBazWidget-1.0 (embedded in BazCore).
BWD acts as a host:

```lua
LibStub("LibBazWidget-1.0"):RegisterWidget(def)
LibStub("LibBazWidget-1.0"):RegisterDormantWidget(def, opts)
```

Or via BazCore's API shim:

```lua
BazCore:RegisterDockableWidget(id, def)
BazCore:UnregisterDockableWidget(id)
```

### Dormant widgets

A widget can register/unregister itself based on game state. When the
condition becomes false, the widget is fully unregistered — no slot, no
title bar, no drawer space wasted. Used heavily in BazWidgets
(`DungeonFinder`, `ActiveDelve`, `HearthstoneCD`, `PullTimer`, …).

### Widget contract

```lua
{
    id, label, frame, designWidth, designHeight,
    GetDesiredHeight = function() return h end,        -- optional
    GetStatusText    = function() return text, r, g, b end,
    GetOptionsArgs   = function() return optionsTable end,
    OnDock           = function(slot) end,
    OnUndock         = function() end,
}
```

### Built-in widgets

| Widget | Purpose |
|---|---|
| Quest Tracker | Read-only objective tracker replica |
| Zone Text | PVP-status-coloured zone label |
| Minimap | Reparented Blizzard minimap, full functionality |
| Minimap Buttons | Adopts LibDBIcon + named addon buttons |
| Micro Menu | Reparented Blizzard micro menu bar |
| Info Bar | Clock + calendar + tracking dropdown |

### Quest Tracker notes

- Pure read-only polling of `C_QuestLog`, `C_Scenario`, `C_ContentTracking`
- Never reparents protected frames → taint-safe
- M+ Challenge Mode block (keystone timer + affixes + death count)
- TomTom + Zygor waypoint integration for super-tracked quests
- Hide Default Tracker option (default on)

---

## 16. BazWidgets

A widget pack with 26 ready-to-dock widgets for BazWidgetDrawers, covering
activity, character, currency, navigation, weekly progress, and utilities.
Many are dormant (active only when relevant — queued, in combat, in a delve,
hearthstone on cooldown, …).

### Registration

Each widget file uses LibBazWidget-1.0 directly:

```lua
local LBW = LibStub("LibBazWidget-1.0")

LBW:RegisterWidget({ ... })            -- always-on

LBW:RegisterDormantWidget(def, {       -- context-active
    events    = { "...", "..." },
    condition = function() return ShouldBeActive() end,
})
```

### Widget categories

| Category | Widgets |
|---|---|
| Activity & Group | DungeonFinder, PullTimer, ActiveDelve, DelveTimer, Companion, BountifulTracker |
| Character & Gear | Repair, StatSummary, ItemLevel, TrinketTracker, FreeBagSlots, HearthstoneCD, CollectionCounter |
| Currency & Economy | GoldTracker, CurrencyBar, TrackedReputation |
| Navigation | Coordinates, SpeedMonitor |
| Weekly Progress | WeeklyChecklist, ResetTimers |
| Utilities | NotePad, Stopwatch, TodoList, Calculator, Performance, Tooltip |

The Tooltip widget hooks `GameTooltip_SetDefaultAnchor` and reroutes
default-anchored tooltips into the drawer slot. ~80% coverage; addons with
hardcoded `ANCHOR_RIGHT`-style anchors aren't redirected.

---

## 17. BazBrokerWidget

Bridges LibDataBroker (LDB) feeds into BazWidgetDrawers. Every LDB-publishing
addon (Bagnon, Recount, Skada, BugSack, almost any addon with a minimap data
button) shows up as its own dockable BWD widget.

### Key concepts

- One BWD widget per LDB feed
- Live updates via LDB attribute callbacks (text, value, icon, label)
- Late-registration aware: subscribes to `LibDataBroker_DataObjectCreated` so
  feeds registered after login appear without a `/reload`
- Click and tooltip forwarding: clicks invoke the feed's `OnClick`; hover
  shows the feed's `OnTooltipShow` / `OnEnter`
- Both LDB types supported: data source (text + value) and launcher
  (icon-only)

### Files

| File | Purpose |
|---|---|
| `Core.lua` | `RegisterAddon`, settings page, slash commands |
| `Widget.lua` | Per-feed widget construction, LDB subscriptions |
| `UserGuide.lua` | User Manual |

### Library dependencies

The `Libs/` folder is fetched at release time by `.pkgmeta` and is not
checked into the repo working tree. For development you need `LibStub`,
`CallbackHandler-1.0`, and `LibDataBroker-1.1` in `Libs/`. They can be
sourced from the BigWigs packager, the LibStub project page, or any
sibling Baz addon that ships them.

---

## 18. BazLootNotifier (maintenance)

> **Maintenance mode.** Its event coverage has been superseded by
> BazNotificationCenter, which provides a more comprehensive toast + history
> system covering loot, XP, reputation, currency, honor, achievements, rare
> spawns, professions, and more. New installs are encouraged to use BNC. BLN
> remains supported for existing users; install BNC alongside BLN and the
> smart handoff routes each event category to the right addon so users never
> see duplicate popups. BLN will continue to receive compatibility fixes for
> new WoW patches.

### Key concepts

- Animated popups for items, currency, gold, reputation, XP, honor,
  profession crafts
- Accumulator clumps rapid events (kill 4 mobs = 1 XP popup with the total)
- In-place popup updates: same event key updates an existing visible popup
- Object pooling for popup frames via `BazCore:CreateObjectPool`

### Desecret pattern

From `Events.lua`. Every chat event handler launders the inputs:

```lua
local function Desecret(val)
    if val == nil then return nil end
    local ok, clean = pcall(string.format, "%s", val)
    return ok and clean or nil
end
```

### Accumulator

`AccumulatePopup(key, label, desc, icon, quality, amount)` batches events
inside a configurable window. Timer extends for full display + fade so the
accumulator stays alive while the popup is visible.

### Smart handoff

On load, BLN checks `IsAddOnLoaded("BazNotificationCenter")`. For each
matching category, BLN silently disables that category and routes events
through `BazCore:PushNotification`. Users mix and match per category.

### Files

| File | Purpose |
|---|---|
| `Core.lua` | `RegisterAddon`, anchor frame, Edit Mode, settings, landing page |
| `Popup.lua` | Popup creation, animation, pooling, `activePopupsByKey` |
| `Events.lua` | Chat event handlers with `Desecret()` laundering |

---

## 19. BazFlightZoom

Auto camera + minimap zoom on flying mounts. Single-file addon (`Core.lua`).

### Behaviour

- `IsOnFlyingMount()` scans player buffs via
  `C_UnitAuras.GetBuffDataByIndex`, matches `spellId` against
  `C_MountJournal` mount spell IDs, checks mount type against
  `FLYING_MOUNT_TYPES`
- Camera zoom via `SetCVar("cameraDistanceMaxZoomFactor")` +
  `MoveViewOutStart` (or `ZoomCameraTo` helper)
- Smooth zoom transitions via `SmoothZoomTo`
- Minimap zoom uses a 0.2s delay (Blizzard overrides immediate `SetZoom`)
- Optional ground-mount support with separate distance setting
- Raw event frame for `PLAYER_MOUNT_DISPLAY_CHANGED` (not `BazCore:On`)
- Secret number taint on aura `spellId` is laundered via
  `pcall(string.format, "%d", ...)`

---

## 20. BazMap

Resizable World Map and Quest Log window with independent layouts per mode.
Single-file addon (`BazMap.lua`).

Frees the map from Blizzard's panel system via `SetAttribute`:

```lua
WorldMapFrame:SetAttribute("UIPanelLayout-enabled", false)
WorldMapFrame:SetAttribute("UIPanelLayout-area", nil)
WorldMapFrame:SetAttribute("UIPanelLayout-allowOtherPanels", true)
```

### Key details

- 0.1s delay on attribute setting (Blizzard overrides immediate calls)
- `lastKnownMode` tracks map vs quest mode (survives `QuestMapFrame:Hide`)
- `WorldMapFrame:OnFrameSizeChanged()` refreshes pin positions after a scale
  change
- Hooks `ToggleWorldMap` and `ToggleQuestLog` at file scope
- `BlackoutFrame` and `TiledBackground` hidden for a clean look
- Maximize hook forces `Minimize()` to prevent fullscreen

### Mode detection

`M` = map mode, `L` = quest log mode. Each mode saves its own scale +
position. Deferred mode detection via `C_Timer.After(0)` for reliable
`QuestMapFrame` state.

---

## 21. BazMapPortals

Mage-only addon: clickable portal/teleport pins on the world map.

### Key concepts

- Pins appear on every map where a mage teleport or portal lands
- Left-click casts the teleport (you alone)
- Right-click casts the portal (group members can step through)
- Pins only appear for spells you actually know
- Faction-restricted destinations only show on the appropriate faction
- Coordinate overrides for tricky maps (Silvermoon, Quel'Thalas, Midnight
  Eastern Kingdoms zones)

### Slash commands

| Command | Action |
|---|---|
| `/mp` | Open settings |
| `/mp set <city>` | Save a custom coord override at the cursor map position |
| `/mp clear <city\|all>` | Clear an override (or all) |
| `/mp dump` | Print current overrides |
| `/mp info` | Show diagnostic info about the current map |
| `/mapportals` | Alias |

---

## 22. Build and Release

### Development workflow

Each addon is a standard WoW addon and lives in
`<your-wow>/Interface/AddOns/<AddonName>/` for in-game testing. Edit in your
repo, deploy to the AddOns folder for testing (copy, symlink, or junction is
fine), commit + tag in the repo when ready to release.

### Repository layout

Each addon has its own GitHub repo under `bazsec/<AddonName>`. BazCore is
the framework dependency for every other addon. BazWidgets and
BazBrokerWidget additionally depend on BazWidgetDrawers (which in turn
depends on BazCore).

### Release process

A release is one commit + one tag:

1. Implement and test the change in-game
2. Bump the `.toc` Version (plain incrementing integer, zero-padded)
3. Update `CHANGELOG.md` if the change is user-visible (entry at the **top**
   of the file)
4. Stage the code change, the `.toc` bump, and the changelog entry
   **together** and commit them as a single commit
5. Tag with the new version (plain number, no prefix): `git tag 052`
6. Push commit and tag: `git push origin master && git push origin 052`
7. CI (`.github/workflows/release.yml`) packages and uploads to CurseForge

The version bump is **not** a separate commit — bundling it with the change
keeps `git log` aligned with `git tag` and makes bisecting work cleanly.

### CI workflow

- Triggered on tag push (any tag)
- Uses `BigWigsMods/packager@v2` with `-g retail`
- Requires a `CF_API_KEY` secret on the repo for CurseForge upload
- Also creates a GitHub Release with the packaged zip

### `.pkgmeta` format

```yaml
package-as: AddonName
ignore:
  - .git
  - .gitignore
  - .pkgmeta
  - LICENSE
```

### CurseForge changelog

The packager auto-generates the CurseForge changelog from git commits between
tags. Don't add `manual-changelog` to `.pkgmeta`. Avoid `Co-Authored-By:`
lines in commit messages — they show in the CF changelog.

### Version format

Plain incrementing integers — `001`, `002`, …, `052`. No semantic versioning.
Every change gets a bump, no matter how small. Format the `.toc` Version and
the git tag identically (no `v` prefix).

### CurseForge project page

`README.md` is the source of truth and is rendered on the CurseForge project
page automatically. CurseForge's markdown is similar to GitHub's but
mishandles some HTML — prefer plain markdown over `<p align="center">`-style
HTML. Use shields.io badges for version / license / WoW version.

### Multi-addon releases

When BazCore changes affect dependents:

1. Tag and push BazCore first (others depend on it)
2. Tag and push each dependent addon after BazCore
3. Each addon gets its own version bump and tag

### Tag-position fix

If a tag is pushed with a wrong `.toc` (forgot to bump before commit):

```bash
# 1. Bump the .toc and commit
git commit -m "AddonName.toc: bump version to NNN"

# 2. Delete the bad tag locally and on origin
git tag -d NNN
git push origin :refs/tags/NNN

# 3. Recreate and push
git tag NNN
git push origin master && git push origin NNN
```

Force-push the tag only — never the branch.

---

## 23. Coding Conventions

### General

- 4-space indentation (Lua)
- Local variables preferred over globals
- File-level locals for performance (e.g. `local GetTime = GetTime`)
- Section separators: `-----------` (75 dashes)
- No emojis in code or files unless explicitly requested

### Naming

| Item | Convention |
|---|---|
| Addon objects | `local addon = BazCore:GetAddon("Name")` |
| Constants | `UPPER_SNAKE_CASE` |
| Functions | `PascalCase` for public, `camelCase` for local |
| Variables | `camelCase` |
| Saved variables | `AddonNameDB` |
| Options table keys | hyphen separator (`AddonName-Settings`) |

### Options tables

- `order` values: use gaps (1, 10, 20, 30, 90) for future insertions
- Section headers: `type = "header"`, `name = "Section Name"`
- Empty header (`order = 90`, `name = ""`) to break before action buttons
- Descriptions: default font is medium; `fontSize = "small"` for smaller
- Mix rich content blocks (paragraph, h3, note, …) with form widgets when
  documentation context helps the user

### Popups

- Never write a `StaticPopupDialog` or hand-roll a `BackdropTemplate`
  confirm. Use `BazCore:Confirm` / `Alert` / `OpenPopup` so the dialog
  matches the rest of the suite UI.
- Destructive actions (delete, reset, purge, wipe) should use
  `acceptStyle = "destructive"` so the accept button reads red.
- Never write your own copy/paste dialog. Use `BazCore:OpenCopyDialog`.

### Git

- Commit subjects: focused, ~50–70 chars, namespace prefix common
  (`Options/Range: ...`, `BazBags Categories: ...`)
- No `Co-Authored-By:` lines (visible on CurseForge)
- Always create new commits, never amend pushed commits
- Never force-push to master
- Tag format: plain number matching `.toc` Version (e.g. `052`)
- For tag-position fixes: delete + recreate + push the tag (force-push the
  tag only, never the branch)

---

## 24. Known Issues and Gotchas

### Midnight secret taint

- `tostring()` does **not** strip taint — use `string.format("%s", val)` via
  `pcall`
- Numbers can also be tainted — use `string.format("%d", val)` via `pcall`
- Setting a tainted string as a button `SetAttribute` = **silent failure**
- Always launder before comparing, concatenating, or setting attributes
- For chat-frame work: do channel-list maintenance and tainted string ops
  inside an `AddMessageEventFilter` (Blizzard wraps filters in
  `securecallfunction` natively) rather than in `HookOnEvent` /
  `SetScript`

### BazBars `SetOverrideBindingClick`

- Use `priority = true` (not `false`) to override default WoW bindings
- Combat guard: defer to `PLAYER_REGEN_ENABLED` if in combat
- `ClearOverrideBindings(keybindOwner)` before restoring all

### BazMap `WorldMapFrame`

- Load-on-demand: check `IsAddOnLoaded` or use `ADDON_LOADED` listener
- `SetAttribute` calls need 0.1s delay (Blizzard overrides immediate calls)
- `OnFrameSizeChanged()` required after scale change to refresh pins

### BazBags

- `ContainerFrameItemButtonTemplate`'s `Initialize()` reads
  `parent:IsCombinedBagContainer()` — bag-context frames must return `true`
  here to get the leather/brown empty-slot art (otherwise default blue
  squares appear)
- `Refresh` re-anchors the frame to TOPLEFT before resizing so toggling
  Categorize mode grows downward instead of expanding from the centre

### BazChat editbox

- `SetAltArrowKeyMode(false)` is required for the editbox to consume arrow
  keys instead of letting them propagate to the game (would walk the player
  otherwise)
- Modern WoW chat-send goes through `C_ChatInfo.SendChatMessage`; the
  legacy `SendChatMessage` global is deprecated and not always called by
  Blizzard's pipeline. Hook both if you need to capture sent text.

### BazCore Options panel

- Auto-read icon from TOC: `C_AddOns.GetAddOnMetadata(name, "IconTexture")`
  (returns string, `tonumber()` it for numeric IDs)
- The standalone window uses `CreateScrollCanvas` with a plain `ScrollFrame`
  + `MinimalScrollBar` (not `UIPanelScrollFrameTemplate`)
- `BuildListDetailPanel` expects either a wrapper-shape group whose `args`
  are the leaf groups (BWD Drawers, BazBars Bars) **or** multiple sibling
  top-level groups that get wrapped in a synthetic host
  (`CreateTwoPanelLayout`'s defensive fallback)

### CopyDialog multi-line EditBox

The EditBox **must** be the direct scroll child of the `ScrollFrame`.
Wrapping it in an intermediate scroll-child frame causes the
selection-highlight rectangles to desync from the visible text under
`ScrollUtil`-driven scrolling — the highlight stays parked at its original
y-position while the text scrolls past underneath. The selection itself
remains correct; only the rendered highlight desyncs. Backdrops should be
drawn on a sibling frame **behind** the scroll viewport.

### CurseForge upload

- Requires `CF_API_KEY` secret on the GitHub repo
- If files don't appear: check repo secrets, check CI logs
- New dependencies (like BazCore on a new addon) may trigger moderation
  review

### Libs folder

Some addons (BazBrokerWidget) have a `.gitignore` that excludes `Libs/`
because the `.pkgmeta` packager downloads them at release time. The libs
do **not** exist in the repo working tree. For development, download them
manually (BigWigs packager, LibStub project page, or copy from a sibling
Baz addon that ships them).
