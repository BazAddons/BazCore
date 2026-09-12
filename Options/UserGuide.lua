-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazCore Options: User Manual
--
-- Hosts the User Manual bottom tab. Any BazCore-compatible addon can
-- register its user guide via BazCore:RegisterUserGuide(addonName, guide).
-- Each registered guide becomes a sub-category in the User Manual tab.
--
-- Guide format:
--   {
--       title = "BazCore",                 -- optional; defaults to addonName
--       intro = "Lead paragraph.",         -- optional; shown above page list
--       pages = {                           -- optional tree of pages
--           {
--               title = "Overview",
--               text  = "Page body...",     -- supports \n\n paragraph breaks
--               children = {                -- optional sub-pages (one level)
--                   { title = "Sub Topic", text = "..." },
--               },
--           },
--           ...
--       },
--       -- Backward-compat: a flat sections list still works
--       sections = {
--           { heading = "...", text = "..." },
--       },
--   }
--
-- Text supports WoW escape codes (|cffxxxxxx...|r for colors). Use
-- \n for line breaks, \n\n for paragraph breaks.
---------------------------------------------------------------------------

local O = BazCore._Options

local guides = {}      -- [addonName] = guide table
local guideState = {}  -- [addonName] = { expanded = {[key]=true}, selectedKey = "1" }

-- List width / gap constants live in Options/Constants.lua so the
-- standard list/detail panel and the User Manual tree resolve to
-- identical dimensions.

---------------------------------------------------------------------------
-- Tree helpers
---------------------------------------------------------------------------

-- Walk pages tree, producing a flat list of nodes that should be visible
-- given the current expansion state.
-- Each node: { page, key, depth, hasChildren }
local function FlattenVisibleNodes(pages, expanded, depth, parentKey, out)
    out = out or {}
    for i, page in ipairs(pages or {}) do
        local key = parentKey and (parentKey .. "/" .. i) or tostring(i)
        local hasChildren = page.children and #page.children > 0
        out[#out + 1] = { page = page, key = key, depth = depth, hasChildren = hasChildren }
        if hasChildren and expanded[key] then
            FlattenVisibleNodes(page.children, expanded, depth + 1, key, out)
        end
    end
    return out
end

-- Find the first leaf page (used for default selection)
local function FindFirstPageKey(pages, parentKey)
    if not pages or #pages == 0 then return nil end
    return parentKey and (parentKey .. "/1") or "1"
end

-- Look up a page node by its key path (e.g. "1/2")
local function FindPageByKey(pages, key)
    if not pages or not key then return nil end
    local cur = pages
    local node
    for part in string.gmatch(key, "[^/]+") do
        local idx = tonumber(part)
        if not idx or not cur or not cur[idx] then return nil end
        node = cur[idx]
        cur = node.children
    end
    return node
end

---------------------------------------------------------------------------
-- Title bar (delegates to O.BuildTitleBar so the User Manual + the
-- standard list/detail page render identical headers).
---------------------------------------------------------------------------

local function BuildTitleBar(parent, addonName, guide, contentWidth)
    return O.BuildTitleBar(parent, {
        title        = guide.title or addonName,
        addonName    = addonName,
        contentWidth = contentWidth,
    })
end

---------------------------------------------------------------------------
-- Render the page-content panel (right side)
---------------------------------------------------------------------------

-- Convert a page (from the user guide schema) into a normalized list of
-- content blocks. Supports both the new `blocks` field AND the legacy
-- `text`/`sections` fields so existing guides keep working.
local function PageToBlocks(page)
    if not page then return {} end
    if page.blocks then return page.blocks end

    local blocks = {}
    if page.text and page.text ~= "" then
        blocks[#blocks + 1] = { type = "paragraph", text = page.text }
    end
    if page.sections then
        for _, section in ipairs(page.sections) do
            if section.heading and section.heading ~= "" then
                blocks[#blocks + 1] = { type = "h3", text = section.heading }
            end
            if section.text and section.text ~= "" then
                blocks[#blocks + 1] = { type = "paragraph", text = section.text }
            end
        end
    end
    return blocks
end

local function RenderPageContent(parent, page, contentWidth)
    O.ClearChildren(parent)
    if not page then return end

    -- Page title (h1) at top, then the page's blocks
    local headerBlocks = {}
    if page.title and page.title ~= "" then
        headerBlocks[#headerBlocks + 1] = { type = "h1", text = page.title }
    end

    local allBlocks = {}
    for _, b in ipairs(headerBlocks) do allBlocks[#allBlocks + 1] = b end
    for _, b in ipairs(PageToBlocks(page)) do allBlocks[#allBlocks + 1] = b end

    -- Render each block, but keep a list so we can re-flow Y offsets
    -- whenever a collapsible expands/collapses. Without this, blocks
    -- below a collapsible are anchored at fixed Y values measured at
    -- render time, so an opened collapsible overlaps its siblings and
    -- the parent height stays too short for the scroll frame.
    local items = {}
    local innerWidth = contentWidth - O.PAD * 2
    for _, block in ipairs(allBlocks) do
        local factory = O.widgetFactories[block.type]
        if factory then
            local widget, h = factory(parent, block, innerWidth)
            widget:Show()
            items[#items + 1] = { widget = widget, height = h }
        end
    end

    local function Reflow()
        local y = -O.PAD
        for _, item in ipairs(items) do
            item.widget:ClearAllPoints()
            item.widget:SetPoint("TOPLEFT", parent, "TOPLEFT", O.PAD, y)
            -- Read the widget's CURRENT height (collapsibles change
            -- theirs as they animate; everything else stays static).
            local h = item.widget:GetHeight() or item.height
            y = y - h - O.SPACING
        end
        parent:SetHeight(math.abs(y) + O.PAD)
    end

    -- Hook each block's _onHeightChanged so any collapsible that grows
    -- or shrinks triggers a full re-flow. Non-collapsible blocks never
    -- fire the hook - assigning the field is harmless.
    for _, item in ipairs(items) do
        item.widget._onHeightChanged = Reflow
    end

    Reflow()
end

---------------------------------------------------------------------------
-- Tree list rebuild
---------------------------------------------------------------------------

local function RebuildTree(listContent, addonName, guide, listW, onSelect)
    O.ClearChildren(listContent)
    local state = guideState[addonName]
    local nodes = FlattenVisibleNodes(guide.pages, state.expanded, 0)

    local rowWidth = listW - 26
    local rows = {}
    for _, node in ipairs(nodes) do
        local capturedKey  = node.key
        local hasChildren  = node.hasChildren and true or false
        local capturedPage = node.page
        rows[#rows + 1] = {
            key        = capturedKey,
            label      = capturedPage.title or "",
            isParent   = hasChildren,
            expanded   = state.expanded[capturedKey] and true or false,
            isSelected = (capturedKey == state.selectedKey),
            depth      = node.depth,
            onClick    = function()
                if hasChildren then
                    state.expanded[capturedKey] = not state.expanded[capturedKey]
                end
                state.selectedKey = capturedKey
                onSelect(capturedPage)
                RebuildTree(listContent, addonName, guide, listW, onSelect)
            end,
        }
    end

    local _, totalH = O.RenderListRows(listContent, rows, { width = rowWidth })
    listContent:SetHeight(math.max(totalH or 0, 1))
end

---------------------------------------------------------------------------
-- Convert legacy `sections` to `pages` so everything goes through one
-- code path. Each section becomes a top-level page.
---------------------------------------------------------------------------

local function NormalizeGuide(guide)
    if guide.pages and #guide.pages > 0 then return guide end
    if guide.sections and #guide.sections > 0 then
        local pages = {}
        for _, section in ipairs(guide.sections) do
            pages[#pages + 1] = {
                title = section.heading,
                text  = section.text,
            }
        end
        -- Don't mutate caller's table - clone the relevant fields
        return {
            title    = guide.title,
            intro    = guide.intro,
            pages    = pages,
            sections = guide.sections,  -- preserved for reference
        }
    end
    return guide
end

---------------------------------------------------------------------------
-- Custom renderer: title bar + tree list (left) + content panel (right)
---------------------------------------------------------------------------

local function RenderGuide(container, addonName)
    local rawGuide = guides[addonName]
    if not rawGuide then return end
    local guide = NormalizeGuide(rawGuide)

    guideState[addonName] = guideState[addonName] or { expanded = {}, selectedKey = nil }
    local state = guideState[addonName]

    -- Default selection: first top-level page
    if not state.selectedKey then
        state.selectedKey = FindFirstPageKey(guide.pages)
    end

    local containerW = container:GetWidth() or 800

    -- Title bar at top
    local titleBar, titleH = BuildTitleBar(container, addonName, guide, containerW)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)

    -- Optional intro paragraph below title bar
    local introH = 0
    local introOffset = -titleH
    if guide.intro and guide.intro ~= "" then
        local intro = container:CreateFontString(nil, "OVERLAY")
        intro:SetFontObject(O.DESC_FONT)
        intro:SetPoint("TOPLEFT", O.PAD, introOffset - 4)
        intro:SetWidth(containerW - O.PAD * 2)
        intro:SetJustifyH("LEFT")
        intro:SetText(guide.intro)
        intro:SetTextColor(unpack(O.TEXT_DESC))
        intro:SetWordWrap(true)
        introH = intro:GetStringHeight() + 10
    end

    local belowHeaderY = -titleH - introH

    -- Split frame for list (left) + detail (right)
    local splitFrame = CreateFrame("Frame", nil, container)
    splitFrame:SetPoint("TOPLEFT", 0, belowHeaderY)
    splitFrame:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Compute list width via the shared resolver so the standard
    -- list/detail panel ends up the same size for the same container.
    local listW = O.ResolveListWidth(containerW)

    -- Left list backdrop
    local listBg = CreateFrame("Frame", nil, splitFrame, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", 0, 0)
    listBg:SetPoint("BOTTOMLEFT", 0, 0)
    listBg:SetWidth(listW)
    listBg:SetBackdrop(O.LIST_BACKDROP)
    listBg:SetBackdropColor(unpack(O.LIST_BG))
    listBg:SetBackdropBorderColor(unpack(O.PANEL_BORDER))

    -- List scroll
    local listScroll = CreateFrame("ScrollFrame", nil, listBg)
    listScroll:SetPoint("TOPLEFT", 4, -6)
    listScroll:SetPoint("BOTTOMRIGHT", -14, 4)
    listScroll:EnableMouseWheel(true)

    local listScrollBar = CreateFrame("EventFrame", nil, listBg, "MinimalScrollBar")
    listScrollBar:SetPoint("TOPLEFT", listScroll, "TOPRIGHT", 2, 0)
    listScrollBar:SetPoint("BOTTOMLEFT", listScroll, "BOTTOMRIGHT", 2, 0)
    ScrollUtil.InitScrollFrameWithScrollBar(listScroll, listScrollBar)
    O.AutoHideScrollbar(listScroll, listScrollBar)

    local listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetWidth(listW - 26)
    listScroll:SetScrollChild(listContent)

    -- Right detail panel
    local detailFrame = CreateFrame("Frame", nil, splitFrame, "BackdropTemplate")
    detailFrame:SetPoint("TOPLEFT", listBg, "TOPRIGHT", O.PAGE_LIST_GAP, 0)
    detailFrame:SetPoint("BOTTOMRIGHT", 0, 0)
    detailFrame:SetBackdrop(O.LIST_BACKDROP)
    detailFrame:SetBackdropColor(unpack(O.PANEL_BG))
    detailFrame:SetBackdropBorderColor(unpack(O.PANEL_BORDER))

    local detailScroll = CreateFrame("ScrollFrame", nil, detailFrame)
    detailScroll:SetPoint("TOPLEFT", 4, -4)
    detailScroll:SetPoint("BOTTOMRIGHT", -14, 4)
    detailScroll:EnableMouseWheel(true)

    local detailScrollBar = CreateFrame("EventFrame", nil, detailFrame, "MinimalScrollBar")
    detailScrollBar:SetPoint("TOPLEFT", detailScroll, "TOPRIGHT", 2, 0)
    detailScrollBar:SetPoint("BOTTOMLEFT", detailScroll, "BOTTOMRIGHT", 2, 0)
    ScrollUtil.InitScrollFrameWithScrollBar(detailScroll, detailScrollBar)
    O.AutoHideScrollbar(detailScroll, detailScrollBar)

    local detailContent = CreateFrame("Frame", nil, detailScroll)
    detailContent:SetWidth(detailFrame:GetWidth() - 28)
    detailScroll:SetScrollChild(detailContent)

    local function Select(page)
        local dw = detailContent:GetWidth() - O.PAD
        if dw <= 0 then dw = 360 end
        RenderPageContent(detailContent, page, dw)
    end

    -- Initial tree render
    RebuildTree(listContent, addonName, guide, listW, Select)

    -- Initial content render (deferred so widths settle)
    C_Timer.After(0, function()
        if not detailContent then return end
        detailContent:SetWidth(detailFrame:GetWidth() - 28)
        local page = FindPageByKey(guide.pages, state.selectedKey)
        Select(page)
    end)

    detailFrame:SetScript("OnSizeChanged", function(self, w)
        detailContent:SetWidth(w - 28)
        local page = FindPageByKey(guide.pages, state.selectedKey)
        Select(page)
    end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- RegisterUserGuide: each addon's guide becomes a "User Guide" sub-category
-- under that addon's own bottom tab. No separate User Manual tab - docs
-- live next to the settings they describe.
function BazCore:RegisterUserGuide(addonName, guide)
    if type(addonName) ~= "string" or addonName == "" then return end
    if type(guide) ~= "table" then return end

    guides[addonName] = guide
    -- Reset view state so a re-registration doesn't strand a stale selection
    guideState[addonName] = { expanded = {}, selectedKey = nil }

    -- Register the guide as a sub-category of the addon itself
    local key = "UserGuide_" .. addonName
    local entry = BazCore._optionsTables[key] or {}
    entry.func = function() return { name = addonName, args = {} } end  -- placeholder
    entry.customRender = function(container)
        RenderGuide(container, addonName)
    end
    BazCore._optionsTables[key] = entry
    BazCore:AddToSettings(key, "User Manual", addonName)

    if BazCore.RefreshOptions then
        BazCore:RefreshOptions(key)
    end
end

BazCore._userGuides = guides

---------------------------------------------------------------------------
-- BazCore's own built-in user guide
---------------------------------------------------------------------------

BazCore:RegisterUserGuide("BazCore", {
    title = "BazCore",
    intro = "BazCore is the shared framework that powers the Baz Suite of World of Warcraft addons. Pick a topic on the left to read about it.",
    pages = {
        {
            title = "Welcome",
            blocks = {
                { type = "lead", text = "BazCore is a framework - it has no visible features on its own. Its job is to host the rest of the Baz Suite addons and provide them with a unified options window, profile system, minimap button, and shared APIs." },
                { type = "note", style = "info", text = "Everything in this manual is registered by an addon when it loads. What you see depends on which Baz addons you have installed." },
                { type = "h2", text = "What you'll find here" },
                { type = "list", items = {
                    "A bottom tab for every Baz addon you have installed",
                    "Per-addon documentation in this User Manual tab",
                    "A unified Profiles system you can configure per-character",
                    "Edit Mode integration for any addon that places frames on screen",
                }},
                { type = "h2", text = "Open commands" },
                { type = "table",
                  columns = { "Command", "Effect" },
                  rows = {
                      { "/bazcore",       "Open this window to BazCore" },
                      { "/bazbars",       "Open with BazBars active" },
                      { "/bwd",           "Open with BazWidgetDrawers active" },
                      { "/bnc",           "Open with BazNotificationCenter active" },
                  },
                },
            },
        },
        {
            title = "The Baz Suite",
            blocks = {
                { type = "lead", text = "Each Baz addon plugs into this window as a bottom tab. Only BazCore itself appears in Blizzard's AddOn Settings list - its \"Open Options\" button jumps here." },
                { type = "paragraph", text = "Pick a sub-category to read about each addon individually. Every addon has its own complete User Manual under its own bottom tab once installed." },
            },
            children = {
                {
                    title = "BazBars",
                    blocks = {
                        { type = "lead", text = "Custom action bars that don't consume Blizzard's 1-120 action slot IDs. Create as many bars as you want, place them anywhere, configure through Blizzard's Edit Mode." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "Up to 24x24 button grids per bar (576 buttons each), unlimited number of bars",
                            "Drag spells, items, macros, toys, mounts, battle pets, and equipment sets onto buttons",
                            "Native Blizzard look - same atlas textures, cooldown sweeps, proc glows, range tinting",
                            "Edit Mode integration with grid snap and pixel-precise nudge",
                            "Quick Keybind mode (hover button + press key to bind)",
                            "Per-button macrotext editor with /cast conditionals + #showtooltip",
                            "Import / Export bar configs as shareable strings",
                            "Optional Masque skinning per bar",
                        }},
                        { type = "note", style = "tip", text = "Slash: |cff00ff00/bb|r to open settings; |cff00ff00/bb create|r to spawn a fresh bar from chat." },
                    },
                },
                {
                    title = "BazBags",
                    blocks = {
                        { type = "lead", text = "Unified bag panel that replaces Blizzard's combined bag UI. All bags + the reagent bag in one window with two display modes, six auto-classified categories, custom categories, and three ways to pin items." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "Two display modes: per-bag sections (Blizzard-style) or grouped by category",
                            "Six default categories that auto-classify items by type and quality",
                            "Three ways to pin items: shift+right-click menu, Categorize-mode drop slots, or settings page",
                            "Hide whole categories from view (Junk, Quest Items, anything)",
                            "Custom categories for any organisation scheme",
                            "Three-button portrait icon: left-click sorts, middle-click toggles Categorize mode, right-click changes bags",
                            "Search box that filters every bag at once",
                            "Inline gold display + tracked-currency strip with alignment options",
                        }},
                        { type = "note", style = "tip", text = "Slash: |cff00ff00/bbg|r to toggle; the B key opens BazBags too (it hooks Blizzard's bag toggles)." },
                    },
                },
                {
                    title = "BazWidgetDrawers",
                    blocks = {
                        { type = "lead", text = "Full-height slide-out side drawer that hosts a vertical stack of dockable widgets. Anchors flush to the left or right edge of your screen and fades out of the way when you're not using it." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "Switchable side (left or right) with auto-flipping tab and slide direction",
                            "Configurable width (120-400 px) with uniform live re-scaling of every docked widget",
                            "Smart fade chrome - drawer disappears when not hovered, widget content stays readable",
                            "Lock mode hides all chrome for a clean minimalist look",
                            "Multiple drawer presets with tab switching",
                            "Per-widget collapse, drag-to-reorder, floating mode (Edit Mode detach)",
                            "Built-in widgets: Quest Tracker, Minimap, Minimap Buttons, Zone Text, Micro Menu, Info Bar",
                            "Dormant widgets that auto-hide when not relevant - no wasted slots",
                        }},
                        { type = "note", style = "tip", text = "Slash: |cff00ff00/bwd|r to toggle the drawer." },
                    },
                },
                {
                    title = "BazWidgets",
                    blocks = {
                        { type = "lead", text = "A pack of 26 ready-to-dock widgets for BazWidgetDrawers covering activity, character info, currency, navigation, weekly progress, and utilities. Many are dormant - they only appear when relevant." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "Activity & Group: Dungeon Finder, Pull Timer, Active Delve, Delve Timer, Delve Companion, Bountiful Tracker",
                            "Character & Gear: Repair, Stat Summary, Item Level, Trinket Tracker, Hearthstone Cooldown, Free Bag Slots, Collection Counter",
                            "Currency & Economy: Gold Tracker, Currency Bar, Tracked Reputation",
                            "Navigation: Coordinates, Speed Monitor",
                            "Weekly Progress: Weekly Checklist, Reset Timers",
                            "Utilities: Note Pad, Stopwatch, To-Do List, Calculator, Performance, Tooltip",
                        }},
                        { type = "note", style = "info", text = "Requires BazWidgetDrawers as a host. Dormant widgets are marked with [D] in the Widgets settings list and can be reordered while dormant." },
                    },
                },
                {
                    title = "BazBrokerWidget",
                    blocks = {
                        { type = "lead", text = "Bridges LibDataBroker (LDB) feeds into BazWidgetDrawers. Every addon that publishes data via LDB - Bagnon, Recount, Skada, BugSack, almost anything with a minimap data button - shows up as its own dockable widget." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "One BWD widget per LDB feed - drag-to-reorder, float, enable/disable per-feed for free",
                            "Live updates - text, value, icon, label changes flow through automatically",
                            "Late-registration aware - feeds that register after login appear without a /reload",
                            "Click and tooltip forwarding - clicks invoke the addon's normal launcher action",
                            "Supports both LDB types: data source (text + value) and launcher (icon-only)",
                        }},
                        { type = "note", style = "info", text = "Requires BazWidgetDrawers as a host. Slash: |cff00ff00/bbw|r." },
                    },
                },
                {
                    title = "BazNotificationCenter",
                    blocks = {
                        { type = "lead", text = "A modern notification center that captures dozens of game events and presents them as polished animated toasts plus a persistent scrollable history panel." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "20 built-in modules: Loot, XP, Reputation, Achievements, Quests, Mail, Auction, Calendar, Collections, Currency (Inventory), Group, Instance, Keystone, Vault, Rares, Zones, Social, System, TalkingHead, Professions",
                            "Per-module toggles - disable just the noisy ones, keep the rest",
                            "Configurable history retention (1-90 days, default 7)",
                            "Do Not Disturb mode silences toasts while keeping the history",
                            "Toast position, duration, stacking direction all configurable",
                            "Smart handoff with BazLootNotifier - no duplicate notifications",
                            "Custom-source API for other addons to push their own notifications",
                        }},
                        { type = "note", style = "tip", text = "Slash: |cff00ff00/bnc|r for settings; |cff00ff00/bnc panel|r opens the history panel." },
                    },
                },
                {
                    title = "BazFlightZoom",
                    blocks = {
                        { type = "lead", text = "Automatically zooms your camera (and optionally your minimap) out when you take flight, then restores your previous zoom levels when you dismount. No keybinds, no macros, no interaction needed." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "Auto camera zoom on flying mounts with configurable max distance (5-50)",
                            "Smooth zoom transitions instead of instant snaps",
                            "Configurable zoom delay after mount-up",
                            "Optional minimap zoom - handy for spotting nodes and rares from altitude",
                            "Optional separate zoom for ground mounts with its own distance setting",
                            "Restores your exact previous values on dismount",
                        }},
                        { type = "note", style = "tip", text = "Slash: |cff00ff00/bfz|r for settings." },
                    },
                },
                {
                    title = "BazMap",
                    blocks = {
                        { type = "lead", text = "Detaches the World Map from Blizzard's panel system and turns it into a freely resizable, repositionable window. Map mode and quest log mode each remember their own size and position independently." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "Drag any edge to resize, drag the title to move",
                            "Independent saved layouts for Map (M key) and Quest Log (L key) modes",
                            "Doesn't push other UI panels around when opened",
                            "Per-character profiles - one character can have a giant fullscreen map while another runs a compact corner panel",
                            "Edit Mode compatible - the map is independent of your Edit Mode layout",
                        }},
                        { type = "note", style = "tip", text = "Slash: |cff00ff00/bazmap|r for settings; |cff00ff00/bazmap reset|r restores default positions." },
                    },
                },
                {
                    title = "BazMapPortals",
                    blocks = {
                        { type = "lead", text = "Mage-only addon that places clickable pin icons on the world map at every destination a mage can teleport or portal to. Click a pin to cast the spell directly from the map - no need to dig through the spellbook." },
                        { type = "h3", text = "Highlights" },
                        { type = "list", items = {
                            "Pins on every map at the right destinations",
                            "Left-click casts the teleport (you alone); right-click casts the portal (group members can step through)",
                            "Pins only appear for spells you actually know - more appear as you learn new teleports",
                            "Faction-restricted destinations only show on the appropriate faction",
                            "Manual coordinate overrides for tricky maps via slash commands",
                            "Includes Midnight's Silvermoon City for both factions",
                        }},
                        { type = "note", style = "warning", text = "Mage-only. Pins simply don't appear on other classes. Slash: |cff00ff00/mp|r for settings." },
                    },
                },
            },
        },
        {
            title = "Opening the Options Window",
            blocks = {
                { type = "lead", text = "There are several ways to open this window." },
                { type = "h3", text = "Minimap Button" },
                { type = "paragraph", text = "Left-click toggles the default addon. Right-click opens a menu listing every Baz addon - pick one to jump to its tab." },
                { type = "h3", text = "Addon Compartment" },
                { type = "paragraph", text = "The Baz icon in Blizzard's compartment dropdown behaves the same way as the minimap button." },
                { type = "h3", text = "Slash Commands" },
                { type = "paragraph", text = "|cff00ff00/bazcore|r opens this window directly to BazCore. Each addon also has its own slash command (|cff00ff00/bazbars|r, |cff00ff00/bwd|r, |cff00ff00/bnc|r, etc.) that opens with that addon's tab active." },
            },
        },
        {
            title = "Profiles",
            text = "Every Baz addon supports per-character profiles. You can use the default profile, share settings across characters, or give each character its own configuration.\n\nOpen any addon's |cffffd700Profiles|r sub-category to:\n  • Create a new profile\n  • Switch the active profile for this character\n  • Copy settings from another profile\n  • Reset or delete a profile\n\nProfiles are stored per-addon - switching your BazBars profile doesn't affect your BazWidgetDrawers profile.",
        },
        {
            title = "Global Options",
            text = "Addons with many modules or widgets expose a |cffffd700Global Options|r sub-category. These are overrides that apply to every module at once.\n\nFor example, BazWidgets has per-widget settings for fade alpha, title visibility, and font size. If you enable a global override for \"Title Bar\", every widget hides its title - regardless of its individual setting. Disable the override to return each widget to its own setting.\n\nThis is the fastest way to apply a consistent look across many widgets or bars without editing each one.",
        },
        {
            title = "Edit Mode Integration",
            text = "Baz addons that place frames on-screen (BazBars, BazWidgetDrawers, BazMap) integrate with Blizzard's |cffffd700Edit Mode|r:\n\n  • Frames appear as movable elements when you open Edit Mode\n  • Positions are saved to your active Edit Mode layout\n  • Switching Edit Mode layouts switches frame positions\n  • Anchors and offsets remain editable inside each addon's options for fine-grained control",
        },
        {
            title = "For Addon Authors",
            blocks = {
                { type = "lead", text = "BazCore is a documented public framework. Any addon can depend on it and use its APIs." },
                { type = "h3", text = "Plugging into the Options window" },
                { type = "code", text = "BazCore:RegisterOptionsTable(\"MyAddon\", optionsTable)\nBazCore:AddToSettings(\"MyAddon\", \"My Addon\")" },
                { type = "paragraph", text = "Your addon appears as a bottom tab. Sub-categories register the same way with a parent name passed as the third argument." },
                { type = "h3", text = "User Manual page (this very page!)" },
                { type = "code", text = "BazCore:RegisterUserGuide(\"MyAddon\", {\n    title = \"My Addon\",\n    intro = \"One-line summary.\",\n    pages = {\n        { title = \"Welcome\", blocks = { ... } },\n    },\n})" },
                { type = "h3", text = "Block types you can use in pages" },
                { type = "list", items = {
                    "h1 / h2 / h3 / h4 - heading hierarchy",
                    "paragraph / lead / caption / quote - text styles",
                    "list - bulleted or numbered, supports nesting",
                    "image - texture, atlas, or fileID with caption",
                    "note - tip / info / warning / danger callouts",
                    "code - monospace block for slash commands and macros",
                    "table - header row + data rows",
                    "collapsible - animated expand/collapse with persistent state",
                    "divider / spacer - layout helpers",
                }},
                { type = "collapsible", title = "Try a collapsible", style = "h3", blocks = {
                    { type = "paragraph", text = "Collapsibles persist their state across sessions automatically - give them a |cffffd700key|r to control where the state is stored, or rely on the auto-derived key based on the title." },
                    { type = "note", style = "tip", text = "Collapsibles can contain other collapsibles. Nest as deep as you want." },
                }},
                { type = "h3", text = "Other APIs" },
                { type = "list", items = {
                    "RegisterDockableWidget - host a widget inside BazWidgetDrawers",
                    "Profiles - per-character settings wiring",
                    "MinimapButton - share the Baz minimap button",
                    "EditMode - register frames into Blizzard's Edit Mode",
                }},
                { type = "note", style = "info", text = "See |cffffd700BAZ_SUITE_DEVELOPER_REFERENCE.txt|r in the BazCore folder for the full API reference with code examples." },
            },
        },
    },
})
