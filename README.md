# BazCore

[![Part of BazAddons](https://img.shields.io/badge/Part_of-BazAddons-b8924a?labelColor=2a2519)](https://bazaddons.com) [![WoW](https://img.shields.io/badge/WoW-12.0_Midnight-blue)](https://worldofwarcraft.blizzard.com/en-us/midnight) ![License](https://img.shields.io/badge/License-GPL_v2-green) ![Version](https://img.shields.io/github/v/tag/BazAddons/BazCore?label=Version&color=orange)

Shared framework for the Baz Suite of World of Warcraft addons.

BazCore is the foundation library that powers every addon in the Baz Suite. It handles addon registration, saved variables, unified profiles, the standalone Options window, page builders, rich content blocks, list/detail panels, form widgets, the User Manual system, Edit Mode integration, minimap buttons, slash commands, event dispatching, and dockable widgets - so each addon focuses on its own features instead of reinventing boilerplate.

BazCore also embeds [LibBazWidget-1.0](https://github.com/bazsec/LibBazWidget), the standalone widget registry library that powers BazWidgetDrawers' dockable widget system.

***

## Features

### Addon Framework

*   **RegisterAddon** - one-call registration with title, saved variable, defaults, slash commands, minimap button, and lifecycle callbacks
*   **Unified profiles** - per-character profiles wired automatically through RegisterAddon, stored in BazCoreDB
*   **Profile migration** - automatically migrates old per-addon SavedVariables into the unified system
*   **QueueForLogin** - register code that runs once at PLAYER_LOGIN, after the addon's saved variables are ready

### Standalone Options Window

*   **Dedicated window** for every Baz addon's settings — replaces Blizzard's cramped Settings panel
*   **Bottom tabs** — one per Baz addon you have installed, click to switch
*   **Left sidebar** lists the active addon's sub-categories (User Manual, General Settings, custom pages)
*   **Right content panel** scrolls automatically when content overflows
*   Dark textured background matching Blizzard's Specialization window
*   ESC closes, draggable, position remembered across sessions
*   Blizzard's AddOn List still has an "Addon Options" button that jumps straight here

### Page Builders

Standardized generators for common settings pages, all returning option-table structs ready to register via RegisterOptionsTable:

*   **CreateLandingPage** - description + features + slash commands intro page
*   **CreateModulesPage** - flat list of enable/disable toggles per module/widget
*   **CreateGlobalOptionsPage** - per-key override toggles that cascade to all widgets
*   **CreateManagedListPage** - list-detail page for collections of editable items (categories, drawers, bars, profiles). Auto-h1 detail title, intro/introBlocks, Create/Reset buttons, source-based collapsible sections - cohesive with the User Manual chrome

### Rich Content Blocks

For documentation pages and managed-list detail panels:

*   **Headings**: h1, h2, h3, h4
*   **Text**: paragraph, lead, caption, quote
*   **Lists**: bulleted or ordered, three levels of nesting
*   **Layout**: divider, spacer, collapsible (with persistent state per session)
*   **Media**: image (texture, atlas, fileID, with caption), code (monospace box), table (header + striped rows)
*   **Callouts**: note (tip / info / warning / danger - colored bg + accent strip + label)

### Form Widgets

*   **toggle** - checkbox with label and optional description
*   **range** - slider with click-anywhere-to-snap behavior, an editable value box on the side for precise numeric entry, and value commits on release rather than mid-drag
*   **input** - edit box (Enter to commit, Esc to revert)
*   **select** - dropdown that auto-sizes to fit its longest value
*   **execute** - button, optional confirm dialog, optional half-width for side-by-side layout

### List / Detail Panels

*   **BuildListDetailPanel** - left list of clickable rows + right detail panel
*   **Gold-gradient selection highlight** matching Blizzard's Traveler's Log + Quest tracker
*   **Source-based collapsible sections** auto-enabled when any child group has a `source` field
*   **Hover + select states**, persistent selection across refreshes
*   **Per-row execute buttons** above the list (e.g., Create New, Reset Defaults)
*   **Three-button portrait icon** support via CreatePortraitWindow with portraitOnClick / portraitTooltip

### User Manual System

*   **RegisterUserGuide(addonName, guide)** - addon's manual lives next to its settings as a "User Manual" sub-category
*   **Tree navigation on the left** with collapsible sections, gold-gradient selection
*   **Rich content panel on the right** rendering all the block types listed above
*   **Pages support flat `text` field OR rich `blocks` array** + one level of nested `children`
*   Built-in BazCore manual ships with the framework - any addon can add its own with one call

### Edit Mode Integration

*   **RegisterEditModeFrame** - register any frame as an Edit Mode target with drag, snap, settings popup, and nudge controls
*   **Grid snapping** with live preview lines
*   **Selection sync** - selecting a BazCore frame deselects Blizzard frames and vice versa
*   **Settings popup** with checkboxes, sliders, and action buttons translated from the addon's options

### Dockable Widget API

*   **RegisterDockableWidget / UnregisterDockableWidget** - shims through to LibBazWidget-1.0
*   **GetDockableWidgets / GetDockableWidget** - query the widget registry
*   **RegisterDockableWidgetCallback** - subscribe to registry changes
*   **Widget contract** - id, label, frame, designWidth, designHeight, plus optional GetDesiredHeight, GetStatusText, GetOptionsArgs, OnDock, OnUndock

### Notification Bridge

*   **RegisterNotificationModule / PushNotification** - route notifications through BazNotificationCenter when installed
*   **Lazy module registration** on first push - no load order worries

### Utilities

*   **Events** - event dispatching and QueueForLogin helper
*   **Timers** - throttle and debounce helpers
*   **ObjectPool** - frame pooling for recycling UI elements
*   **Format** - number formatting, time formatting, safe string handling
*   **Animations** - fade, slide, and scale animation helpers
*   **ButtonGlow** - spell proc glow overlay system
*   **Keybinds** - keybind management with SetOverrideBindingClick
*   **Serialization** - export/import config strings
*   **CreatePortraitWindow** - addon-window helper with Blizzard's standard portrait chrome, drag, ESC close, position persistence, and three-button portrait icon (left/middle/right)
*   **CreateItemButton** - item-button frame helper (icon, quality border, slot art) for addons that need bag-slot-style visuals

***

## Slash Commands

| Command | Description |
| --- | --- |
| `/bazcore` | Open the BazCore Options window |

***

## Compatibility

*   **WoW Version:** Retail 12.0 (Midnight)
*   **Zero external dependencies** - BazCore depends on nothing except WoW itself
*   **Midnight API safe** - taint-safe patterns throughout
*   **LibStub** - embedded for LibBazWidget-1.0 version negotiation
*   **LibBazWidget-1.0** - embedded standalone widget registry library

***

## The Baz Suite

BazCore powers the following addons:

*   **[BazBars](https://www.curseforge.com/wow/addons/bazbars)** - Custom extra action bars
*   **[BazBags](https://www.curseforge.com/wow/addons/bazbags)** - Unified bag panel
*   **[BazWidgetDrawers](https://www.curseforge.com/wow/addons/bazwidgetdrawers)** - Slide-out widget drawer
*   **[BazWidgets](https://www.curseforge.com/wow/addons/bazwidgets)** - Widget pack for BazWidgetDrawers
*   **[BazNotificationCenter](https://www.curseforge.com/wow/addons/baznotificationcenter)** - Toast notification system
*   **[BazLootNotifier](https://www.curseforge.com/wow/addons/bazlootnotifier)** - Animated loot popups
*   **[BazFlightZoom](https://www.curseforge.com/wow/addons/bazflightzoom)** - Auto zoom on flying mounts
*   **[BazMap](https://www.curseforge.com/wow/addons/bazmap)** - Resizable map and quest log window
*   **[BazMapPortals](https://www.curseforge.com/wow/addons/bazmapportals)** - Mage portal/teleport map pins

***

## License

BazCore is licensed under the **GNU General Public License v2** (GPL v2).
