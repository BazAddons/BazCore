-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazCore: Core Module
-- Addon registry, lifecycle management, addon objects
---------------------------------------------------------------------------

BazCore = BazCore or {}
BazCore.addons = {}
BazCore.addonObjects = {}
BazCore.VERSION = C_AddOns.GetAddOnMetadata("BazCore", "Version") or "?"

---------------------------------------------------------------------------
-- Addon Object Prototype
-- Other modules extend this via BazCore.AddonMixin
---------------------------------------------------------------------------

local AddonMixin = {}
AddonMixin.__index = AddonMixin
BazCore.AddonMixin = AddonMixin

function AddonMixin:GetSetting(key)
    if self.db and self.db.profile then return self.db.profile[key] end
end

function AddonMixin:SetSetting(key, value)
    if self.db and self.db.profile then self.db.profile[key] = value end
end

---------------------------------------------------------------------------
-- Lifecycle: PLAYER_LOGIN queue
---------------------------------------------------------------------------

local loginReady = false
local loginQueue = {}

-- Memory-log phase marker. Defined as a local stub before MemoryLog
-- has loaded; the real MarkMemoryEvent is published once that file
-- runs. The check makes it safe to call from any startup path.
local function PhaseMark(label)
    if BazCore.MarkMemoryEvent then
        BazCore:MarkMemoryEvent("phase", label)
    end
end

local lifecycleFrame = CreateFrame("Frame")
lifecycleFrame:RegisterEvent("PLAYER_LOGIN")
lifecycleFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        loginReady = true
        PhaseMark("login:queue-start (" .. #loginQueue .. " callbacks)")
        for _, entry in ipairs(loginQueue) do
            -- Two shapes coexist: bare functions (legacy unlabelled
            -- callers) and { fn, label } tables (new labelled form).
            -- Type-check before indexing - indexing a function value
            -- is a Lua error.
            if type(entry) == "function" then
                entry()
            else
                local fn    = entry.fn
                local label = entry.label
                if label then PhaseMark("login:before-" .. label) end
                fn()
                if label then PhaseMark("login:after-" .. label) end
            end
        end
        wipe(loginQueue)
        PhaseMark("login:queue-end")
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

-- QueueForLogin(fn [, label])
--   Queues a callback for PLAYER_LOGIN. When `label` is provided, the
--   memory log brackets the callback's execution with phase markers
--   so the next /bazmem armwatch dump shows which queued task was
--   responsible for any spike.
function BazCore:QueueForLogin(fn, label)
    if loginReady then
        if label then PhaseMark("login:before-" .. label) end
        fn()
        if label then PhaseMark("login:after-" .. label) end
    else
        if label then
            table.insert(loginQueue, { fn = fn, label = label })
        else
            table.insert(loginQueue, fn)
        end
    end
end

---------------------------------------------------------------------------
-- Addon Registration
---------------------------------------------------------------------------

function BazCore:RegisterAddon(name, config)
    self.addons[name] = config

    -- Create addon object with convenience methods
    local addon = setmetatable({
        name = name,
        config = config,
        loaded = false,
    }, AddonMixin)
    self.addonObjects[name] = addon

    -- Capture the calling file's per-addon shared table (the second
    -- vararg `(...)` in standard WoW addon Lua, conventionally named
    -- `addon` or `BazXXX` in the file's locals). This is where
    -- modules typically attach themselves (addon.Replica = Replica,
    -- addon.Window = Window, etc.) - i.e. the actual namespace tree
    -- the CPU profiler's drill-down walker needs to find functions
    -- in. WoW doesn't expose these tables anywhere by default, so we
    -- fish it out of the caller's locals via the debug API. Stored
    -- on BazCore.addonNamespaces[name] keyed by addon name.
    --
    -- Looks for a table-typed local named "addon" (the convention
    -- across the Baz suite) in the caller's frame. Falls back to
    -- scanning all locals for the first table that contains common
    -- addon-shared keys, so non-conforming naming still works.
    self.addonNamespaces = self.addonNamespaces or {}
    if debug and debug.getlocal then
        local found
        local i = 1
        while true do
            local lname, lval = debug.getlocal(2, i)
            if not lname then break end
            if type(lval) == "table" and (lname == "addon" or lname == name) then
                found = lval
                break
            end
            i = i + 1
        end
        if found then self.addonNamespaces[name] = found end
    end

    -- Deferred init on ADDON_LOADED
    EventUtil.ContinueOnAddOnLoaded(name, function()
        -- Initialize saved variables (for addons that still have their own SV, e.g. BNC history)
        if config.savedVariable then
            local svName = config.savedVariable
            _G[svName] = _G[svName] or {}

            if not config.profiles and config.defaults then
                local sv = _G[svName]
                for k, v in pairs(config.defaults) do
                    if sv[k] == nil then sv[k] = v end
                end
            end
        end

        -- Unified profile setup: addon data lives in BazCoreDB.profiles
        if config.profiles and BazCore.InitAddonProfile then
            -- Migrate old per-addon SV profiles into BazCoreDB (one-time)
            if config.savedVariable and BazCore.MigrateAddonProfiles then
                BazCore:MigrateAddonProfiles(name, config.savedVariable)
            end

            -- Ensure addon section exists with defaults in active profile
            BazCore:InitAddonProfile(name, config)

            -- Auto-wire addon.db.profile proxy
            if BazCore.CreateDBProxy then
                addon.db = BazCore:CreateDBProxy(name)
            end
        end

        -- onLoad callback (SV ready, before UI)
        if config.onLoad then
            config.onLoad(addon)
        end


        -- Register slash commands (Commands module)
        if config.slash and BazCore.RegisterCommands then
            BazCore:RegisterCommands(name, config)
        end

        -- Register minimap entry (MinimapButton module)
        if config.minimap and BazCore.RegisterMinimapEntry then
            BazCore:RegisterMinimapEntry(name, config.minimap)
        end

        addon.loaded = true

        -- onReady callback (after SV + UI init + PLAYER_LOGIN). The
        -- label flows through to the memory-log phase markers so a
        -- /bazmem armwatch dump shows per-addon onReady cost.
        if config.onReady then
            BazCore:QueueForLogin(function()
                config.onReady(addon)
            end, "onReady:" .. name)
        end
    end)

    return addon
end

function BazCore:GetAddon(name)
    return self.addonObjects[name]
end

---------------------------------------------------------------------------
-- BazCore's own settings page (registered after all modules load)
---------------------------------------------------------------------------

-- Initialize unified profile structure early (before addons load)
EventUtil.ContinueOnAddOnLoaded("BazCore", function()
    BazCoreDB = BazCoreDB or {}
    if BazCore.InitProfiles then
        BazCore:InitProfiles()
    end
end)

BazCore:QueueForLogin(function()
    if not BazCore.RegisterOptionsTable then return end

    BazCoreDB = BazCoreDB or {}
    BazCoreDB.minimap = BazCoreDB.minimap or { hide = false }

    BazCoreDB.welcomeMessage = BazCoreDB.welcomeMessage == nil and true or BazCoreDB.welcomeMessage

    -- (the rest of this callback registers BazCore's own pages -
    -- Landing, Settings subcategory, Profiles subcategory)
    -- Labelled "BazCoreSelfPages" so the memory-log phase markers
    -- attribute any allocation that happens here cleanly.

    -- Landing page
    BazCore:RegisterOptionsTable("BazCore", function()
        local landing = BazCore:CreateLandingPage("BazCore", {
            subtitle = "Shared framework",
            description = "Shared framework library for the Baz Suite of addons. " ..
                "Provides profiles, settings panels, Edit Mode integration, events, " ..
                "slash commands, minimap button, and UI utilities.",
            features = "Declarative addon registration with lifecycle management. " ..
                "Profile system with per-character/class/spec assignment. " ..
                "Two-column options panel with branded headers. " ..
                "Edit Mode framework with grid snapping and settings popup. " ..
                "Object pooling, timers, animations, and string safety utilities.",
        })

        -- Suite version list. The dedicated Memory Usage sub-page
        -- (MemoryPage.lua) handles the live memory readout - this
        -- landing page just orients the user with version info.
        local versionLines = {}
        local sorted = {}
        for name, config in pairs(BazCore.addons) do
            sorted[#sorted + 1] = { name = config.title or name, toc = config.savedVariable and name }
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)
        for _, info in ipairs(sorted) do
            local ver = "?"
            if info.toc then
                ver = C_AddOns.GetAddOnMetadata(info.toc, "Version") or "?"
            end
            versionLines[#versionLines + 1] = "|cffffffff" .. info.name .. "|r v" .. ver
        end

        landing.args.suiteHeader = { order = 30, type = "header", name = "Baz Suite" }
        landing.args.versionList = { order = 31, type = "description", name = "|cff3399ffBazCore|r v" .. BazCore.VERSION .. "\n" .. table.concat(versionLines, "\n") }

        return landing
    end)
    BazCore:AddToSettings("BazCore", "BazCore")

    -- Settings subcategory
    BazCore:RegisterOptionsTable("BazCore-Settings", function()
        return {
            name = "Settings",
            type = "group",
            args = {
                minimapBtn = {
                    order = 1,
                    type = "toggle",
                    name = "Show Minimap Button",
                    desc = "Show or hide the shared Baz minimap button",
                    get = function() return not BazCoreDB.minimap.hide end,
                    set = function(_, val)
                        BazCoreDB.minimap.hide = not val
                        if val then
                            BazCore:ShowMinimapButton()
                        else
                            BazCore:HideMinimapButton()
                        end
                    end,
                },
                welcomeMsg = {
                    order = 2,
                    type = "toggle",
                    name = "Show Welcome Messages",
                    desc = "Show addon loaded messages in chat on login",
                    get = function() return BazCoreDB.welcomeMessage end,
                    set = function(_, val) BazCoreDB.welcomeMessage = val end,
                },
            },
        }
    end)
    BazCore:AddToSettings("BazCore-Settings", "General Settings", "BazCore")

    -- Suite welcome line: prints "BazCore vXXX, BazBars vYYY, ..." for
    -- every registered Baz addon on login, sorted alphabetically.
    -- Suppressed when welcomeMessage is toggled off in General Settings.
    --
    -- Deferred via C_Timer.After(0, ...) so it runs after every other
    -- login-queued handler in this same tick, in particular BazChat's
    -- Replica:Start which reassigns DEFAULT_CHAT_FRAME to its own
    -- replica window. Without the defer our print() landed on
    -- Blizzard's hidden ChatFrame1 (the original DEFAULT_CHAT_FRAME at
    -- the moment our QueueForLogin ran), invisible to the user. Same
    -- reason the Guild MOTD doesn't show: Blizzard prints it directly
    -- to its own frames which BazChat has hidden.
    if BazCoreDB.welcomeMessage ~= false then
        C_Timer.After(0, function()
            local entries = { string.format("|cff3399ffBazCore|r v%s",
                tostring(BazCore.VERSION or "?")) }
            local sorted = {}
            for name, config in pairs(BazCore.addons) do
                sorted[#sorted + 1] = { name = config.title or name, toc = name }
            end
            table.sort(sorted, function(a, b) return a.name < b.name end)
            for _, info in ipairs(sorted) do
                local ver = (C_AddOns and C_AddOns.GetAddOnMetadata
                    and C_AddOns.GetAddOnMetadata(info.toc, "Version")) or "?"
                entries[#entries + 1] = string.format("|cffffd700%s|r v%s",
                    info.name, ver)
            end
            BazCore:Print(table.concat(entries, ", "))
        end)
    end

    -- Profiles subcategory (unified for all Baz Suite addons)
    if BazCore.GetProfileOptionsTable then
        BazCore:RegisterOptionsTable("BazCore-Profiles", function()
            return BazCore:GetProfileOptionsTable()
        end)
        BazCore:AddToSettings("BazCore-Profiles", "Profiles", "BazCore")
    end
end, "BazCoreSelfPages")

---------------------------------------------------------------------------
-- Do Not Disturb: environmental state check
-- Returns true if player is in combat or an encounter is active
---------------------------------------------------------------------------

local encounterActive = false

local dndFrame = CreateFrame("Frame")
dndFrame:RegisterEvent("ENCOUNTER_START")
dndFrame:RegisterEvent("ENCOUNTER_END")
dndFrame:SetScript("OnEvent", function(_, event)
    encounterActive = (event == "ENCOUNTER_START")
end)

function BazCore:IsDND()
    return InCombatLockdown() or encounterActive
end

---------------------------------------------------------------------------
-- Notification Bridge
-- Routes to BazNotificationCenter if installed, nil otherwise.
--
-- Baz Suite addons that want to push notifications call:
--   BazCore:RegisterNotificationModule("BazBars", { icon = ..., label = ... })
-- and then:
--   BazCore:PushNotification({ module = "BazBars", title = "...", ... })
--
-- If BNC isn't installed, both calls silently do nothing so addons don't
-- need to guard against missing BNC themselves.
---------------------------------------------------------------------------

local registeredNotificationModules = {}

local function TryRegisterModule(moduleId, info)
    if not BazNotificationCenter or not BNC or not BNC.RegisterModule then return end
    if registeredNotificationModules[moduleId] then return end
    BNC:RegisterModule({
        id = moduleId,
        name = info.label or moduleId,
        icon = info.icon or "Interface\\Icons\\INV_Misc_Bell_01",
    })
    registeredNotificationModules[moduleId] = true
end

function BazCore:RegisterNotificationModule(moduleId, info)
    if not moduleId then return end
    info = info or {}
    -- Remember the registration so we can re-apply it when BNC loads later
    registeredNotificationModules[moduleId] = registeredNotificationModules[moduleId] or false
    TryRegisterModule(moduleId, info)
    -- Store info for late registration if BNC isn't loaded yet
    registeredNotificationModules[moduleId .. "_info"] = info
end

function BazCore:PushNotification(data)
    if not BazNotificationCenter or not BazNotificationCenter.Push then return end
    if data and data.module and not registeredNotificationModules[data.module] then
        -- Lazy-register on first push if caller forgot to register explicitly
        local info = registeredNotificationModules[data.module .. "_info"] or {}
        TryRegisterModule(data.module, info)
    end
    return BazNotificationCenter:Push(data)
end

-- Auto-register the BazCore internal module for things like profile-change
-- toasts. Done on PLAYER_LOGIN so BNC has finished loading.
BazCore:QueueForLogin(function()
    BazCore:RegisterNotificationModule("_bazcore", {
        label = "BazCore",
        icon = "Interface\\Icons\\INV_Gizmo_GoblingTonkController",
    })
end)

---------------------------------------------------------------------------
-- BazCore's own slash commands
-- /bazcore (or /bc) opens the options window. Sub-commands cover the most
-- common day-to-day actions: profile switching and default-profile setup.
---------------------------------------------------------------------------

BazCore:QueueForLogin(function()
    if not BazCore.RegisterCommands then return end

    BazCore:RegisterCommands("BazCore", {
        title = "BazCore",
        slash = { "/bazcore", "/bc" },
        defaultHandler = function()
            if BazCore.OpenOptionsPanel then
                BazCore:OpenOptionsPanel("BazCore")
            end
        end,
        commands = {
            profile = {
                desc = "Show or switch the active profile",
                handler = function(args)
                    if not args or args == "" then
                        BazCore:Print("Active profile: |cff00ff00" .. BazCore:GetActiveProfile() .. "|r")
                        return
                    end
                    if BazCore:SetActiveProfile(args) then
                        BazCore:Print("Switched to profile: |cff00ff00" .. args .. "|r")
                    else
                        BazCore:Print("|cffff4444No profile named '" .. args .. "'|r")
                    end
                end,
            },
            profiles = {
                desc = "List all profiles",
                handler = function()
                    local active  = BazCore:GetActiveProfile()
                    local default = BazCore:GetDefaultProfile()
                    BazCore:Print("Profiles:")
                    for _, name in ipairs(BazCore:ListProfiles()) do
                        local tags = ""
                        if name == active  then tags = tags .. " |cff00ff00(active)|r"  end
                        if name == default then tags = tags .. " |cffffd700(default)|r" end
                        print("  " .. name .. tags)
                    end
                end,
            },
            default = {
                desc = "Set the profile new characters auto-attach to (or print the current default)",
                handler = function(args)
                    if not args or args == "" then
                        BazCore:Print("Default profile for new characters: |cffffd700" .. BazCore:GetDefaultProfile() .. "|r")
                        return
                    end
                    if BazCore:SetDefaultProfile(args) then
                        BazCore:Print("'|cffffd700" .. args .. "|r' set as the default for new characters.")
                    else
                        BazCore:Print("|cffff4444No profile named '" .. args .. "'|r")
                    end
                end,
            },
        },
    })
end)
