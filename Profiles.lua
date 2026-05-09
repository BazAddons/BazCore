-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazCore: Profiles Module
-- Unified profile system - one profile controls all Baz Suite addons
-- Profiles stored in BazCoreDB.profiles[profileName][addonName] = { ... }
---------------------------------------------------------------------------

local DEFAULT_PROFILE = "Default"

-- Profile change callbacks per addon
local profileCallbacks = {} -- [addonName] = { handler1, handler2, ... }

---------------------------------------------------------------------------
-- Character Identity
---------------------------------------------------------------------------

local function GetCharacterKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    return name and realm and (name .. " - " .. realm) or "Unknown"
end

local function GetClassKey()
    local _, class = UnitClass("player")
    return class or "UNKNOWN"
end

local function GetSpecKey()
    local class = GetClassKey()
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local _, specName = GetSpecializationInfo(specIndex)
    return specName and (class .. ":" .. specName) or nil
end

---------------------------------------------------------------------------
-- Fill defaults for an addon section within a profile
---------------------------------------------------------------------------

local function FillAddonDefaults(profileSection, defaults)
    if not defaults then return end
    for k, v in pairs(defaults) do
        if profileSection[k] == nil then
            if type(v) == "table" then
                profileSection[k] = CopyTable(v)
            else
                profileSection[k] = v
            end
        end
    end
end

local function FillAllAddonDefaults(profile)
    for addonName, config in pairs(BazCore.addons) do
        if config.profiles and config.defaults then
            if not profile[addonName] then
                profile[addonName] = {}
            end
            FillAddonDefaults(profile[addonName], config.defaults)
        end
    end
end

---------------------------------------------------------------------------
-- Profile Initialization
-- Called once during BazCore's own ADDON_LOADED
---------------------------------------------------------------------------

function BazCore:InitProfiles()
    local sv = BazCoreDB

    if not sv.profiles then
        sv.profiles = {}
    end
    if not sv.assignments then
        sv.assignments = {}
    end

    -- Create Default profile if it doesn't exist
    if not sv.profiles[DEFAULT_PROFILE] then
        sv.profiles[DEFAULT_PROFILE] = {}
    end

    -- Default-profile pointer: which profile should brand-new characters
    -- inherit? Falls back to the built-in "Default" if not set, or if
    -- the pointed-to profile no longer exists.
    if sv.defaultProfile and not sv.profiles[sv.defaultProfile] then
        sv.defaultProfile = nil
    end
    local defaultName = sv.defaultProfile or DEFAULT_PROFILE

    -- New character on first login: assign directly to the default profile
    -- (no per-character copy). Changes to the default propagate to every
    -- character using it, which is what users expect from a "default."
    local charKey = GetCharacterKey()
    if charKey ~= "Unknown" and not sv.assignments[charKey] then
        sv.assignments[charKey] = defaultName
    end

    -- Resolve which profile this character should use
    sv.activeProfile = self:ResolveProfile() or DEFAULT_PROFILE

    -- Ensure the resolved profile exists
    if not sv.profiles[sv.activeProfile] then
        sv.profiles[sv.activeProfile] = {}
    end
end

---------------------------------------------------------------------------
-- Per-Addon Profile Setup
-- Called from RegisterAddon when profiles = true
-- Ensures the addon's section exists and has defaults filled
---------------------------------------------------------------------------

function BazCore:InitAddonProfile(addonName, config)
    local sv = BazCoreDB
    if not sv or not sv.profiles then return end

    local profileName = sv.activeProfile or DEFAULT_PROFILE
    local profile = sv.profiles[profileName]
    if not profile then return end

    -- Ensure addon section exists
    if not profile[addonName] then
        profile[addonName] = {}
    end

    -- Fill defaults
    FillAddonDefaults(profile[addonName], config.defaults)
end

---------------------------------------------------------------------------
-- Migration: Pull old per-addon SavedVariables into BazCoreDB
---------------------------------------------------------------------------

function BazCore:MigrateAddonProfiles(addonName, oldSVName)
    local oldSV = _G[oldSVName]
    if not oldSV or not oldSV.profiles then return end

    local sv = BazCoreDB

    -- Migrate each profile
    for profileName, profileData in pairs(oldSV.profiles) do
        if not sv.profiles[profileName] then
            sv.profiles[profileName] = {}
        end
        -- Only migrate if this addon doesn't already have data in the unified profile
        if not sv.profiles[profileName][addonName] then
            sv.profiles[profileName][addonName] = profileData
        end
    end

    -- Migrate assignments (first addon's assignments win for shared scopes)
    if oldSV.assignments then
        for scope, profileName in pairs(oldSV.assignments) do
            if not sv.assignments[scope] then
                sv.assignments[scope] = profileName
            end
        end
    end

    -- Use the old active profile if we haven't set one yet
    if sv.activeProfile == DEFAULT_PROFILE and oldSV.activeProfile and oldSV.activeProfile ~= DEFAULT_PROFILE then
        if sv.profiles[oldSV.activeProfile] then
            sv.activeProfile = oldSV.activeProfile
        end
    end

    -- Clear old profile data from the addon's SV (keep non-profile data like history)
    oldSV.profiles = nil
    oldSV.assignments = nil
    oldSV.activeProfile = nil
end

---------------------------------------------------------------------------
-- Profile Resolution
-- Determines which profile a character should use based on assignments
---------------------------------------------------------------------------

function BazCore:ResolveProfile()
    local sv = BazCoreDB
    if not sv or not sv.assignments then return DEFAULT_PROFILE end

    local assignments = sv.assignments

    -- Priority 1: Character-specific
    local charKey = GetCharacterKey()
    if assignments[charKey] then
        return assignments[charKey]
    end

    -- Priority 2: Class + Spec
    local specKey = GetSpecKey()
    if specKey and assignments[specKey] then
        return assignments[specKey]
    end

    -- Priority 3: Class only
    local classKey = GetClassKey()
    if assignments[classKey] then
        return assignments[classKey]
    end

    -- Priority 4: Default
    return DEFAULT_PROFILE
end

---------------------------------------------------------------------------
-- Profile Management API (unified - no addonName parameter)
---------------------------------------------------------------------------

function BazCore:GetActiveProfile()
    local sv = BazCoreDB
    return sv and sv.activeProfile or DEFAULT_PROFILE
end

---------------------------------------------------------------------------
-- Default-Profile Pointer
-- The "default" profile is the one new characters auto-attach to on
-- their first login. Any profile can be promoted to default; the
-- built-in "Default" is the fallback.
---------------------------------------------------------------------------

function BazCore:GetDefaultProfile()
    local sv = BazCoreDB
    return (sv and sv.defaultProfile) or DEFAULT_PROFILE
end

function BazCore:SetDefaultProfile(profileName)
    local sv = BazCoreDB
    if not sv or not sv.profiles or not sv.profiles[profileName] then
        return false
    end
    sv.defaultProfile = profileName
    BazCore:Fire("BAZ_DEFAULT_PROFILE_CHANGED", profileName)
    return true
end

function BazCore:ClearDefaultProfile()
    local sv = BazCoreDB
    if not sv then return false end
    sv.defaultProfile = nil
    BazCore:Fire("BAZ_DEFAULT_PROFILE_CHANGED", DEFAULT_PROFILE)
    return true
end

function BazCore:SetActiveProfile(profileName)
    local sv = BazCoreDB
    if not sv or not sv.profiles[profileName] then return false end

    local oldProfile = sv.activeProfile
    sv.activeProfile = profileName

    -- Fill defaults for all addons in the new profile
    FillAllAddonDefaults(sv.profiles[profileName])

    -- Fire callbacks for all addons
    for addonName, config in pairs(BazCore.addons) do
        if config.profiles then
            self:FireProfileChanged(addonName, profileName, oldProfile)
        end
    end

    -- Push a toast through BazNotificationCenter if it's installed
    if oldProfile ~= profileName then
        BazCore:PushNotification({
            module = "_bazcore",
            title = "Profile Changed",
            message = "Switched to " .. profileName,
            icon = "Interface\\Icons\\INV_Misc_Book_09",
            priority = "low",
        })
    end
    return true
end

function BazCore:CreateProfile(profileName)
    local sv = BazCoreDB
    if not sv then return false end

    sv.profiles = sv.profiles or {}
    if sv.profiles[profileName] then return false end

    sv.profiles[profileName] = {}
    FillAllAddonDefaults(sv.profiles[profileName])

    BazCore:Fire("BAZ_PROFILE_CREATED", profileName)
    return true
end

function BazCore:CopyProfile(fromName, toName)
    local sv = BazCoreDB
    if not sv or not sv.profiles then return false end

    local source = sv.profiles[fromName]
    if not source then return false end

    if not sv.profiles[toName] then
        sv.profiles[toName] = {}
    end

    -- Deep copy entire profile (all addon sections)
    wipe(sv.profiles[toName])
    for k, v in pairs(source) do
        if type(v) == "table" then
            sv.profiles[toName][k] = CopyTable(v)
        else
            sv.profiles[toName][k] = v
        end
    end

    BazCore:Fire("BAZ_PROFILE_COPIED", fromName, toName)
    return true
end

function BazCore:DeleteProfile(profileName)
    local sv = BazCoreDB
    if not sv or not sv.profiles then return false end

    if sv.activeProfile == profileName then return false end
    if profileName == DEFAULT_PROFILE then return false end

    sv.profiles[profileName] = nil

    -- Clean up assignments pointing to deleted profile
    if sv.assignments then
        for scope, assignedProfile in pairs(sv.assignments) do
            if assignedProfile == profileName then
                sv.assignments[scope] = nil
            end
        end
    end

    -- If the default-profile pointer was on this one, fall back to "Default"
    if sv.defaultProfile == profileName then
        sv.defaultProfile = nil
    end

    BazCore:Fire("BAZ_PROFILE_DELETED", profileName)
    return true
end

function BazCore:RenameProfile(oldName, newName)
    local sv = BazCoreDB
    if not sv or not sv.profiles then return false end

    if not oldName or not newName or oldName == "" or newName == "" then return false end
    if oldName == newName then return true end
    if oldName == DEFAULT_PROFILE then return false end
    if sv.profiles[newName] then return false end

    sv.profiles[newName] = sv.profiles[oldName]
    sv.profiles[oldName] = nil

    if sv.activeProfile == oldName then
        sv.activeProfile = newName
    end

    if sv.assignments then
        for scope, assignedProfile in pairs(sv.assignments) do
            if assignedProfile == oldName then
                sv.assignments[scope] = newName
            end
        end
    end

    -- Move the default-profile pointer if it was on the renamed profile
    if sv.defaultProfile == oldName then
        sv.defaultProfile = newName
    end

    BazCore:Fire("BAZ_PROFILE_RENAMED", oldName, newName)
    return true
end

function BazCore:ResetProfile(profileName)
    local sv = BazCoreDB
    if not sv or not sv.profiles then return false end

    profileName = profileName or sv.activeProfile
    local profile = sv.profiles[profileName]
    if not profile then return false end

    wipe(profile)
    FillAllAddonDefaults(profile)

    if profileName == sv.activeProfile then
        for addonName, config in pairs(BazCore.addons) do
            if config.profiles then
                self:FireProfileChanged(addonName, profileName, profileName)
            end
        end
    end

    BazCore:Fire("BAZ_PROFILE_RESET", profileName)
    return true
end

function BazCore:ListProfiles()
    local sv = BazCoreDB
    if not sv or not sv.profiles then return {} end

    local list = {}
    for name in pairs(sv.profiles) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

---------------------------------------------------------------------------
-- Profile Assignment (unified)
---------------------------------------------------------------------------

function BazCore:AssignProfile(scope, profileName)
    local sv = BazCoreDB
    if not sv then return false end

    sv.assignments = sv.assignments or {}

    local scopeKey
    if scope == "character" then
        scopeKey = GetCharacterKey()
    elseif scope == "class" then
        scopeKey = GetClassKey()
    elseif scope == "spec" then
        scopeKey = GetSpecKey()
        if not scopeKey then return false end
    else
        return false
    end

    if profileName then
        sv.assignments[scopeKey] = profileName
    else
        sv.assignments[scopeKey] = nil
    end

    return true
end

---------------------------------------------------------------------------
-- Profile Change Callbacks
---------------------------------------------------------------------------

function BazCore:FireProfileChanged(addonName, newProfile, oldProfile)
    local callbacks = profileCallbacks[addonName]
    if callbacks then
        for _, fn in ipairs(callbacks) do
            fn(newProfile, oldProfile)
        end
    end
    BazCore:Fire("BAZ_PROFILE_CHANGED", addonName, newProfile, oldProfile)
end

---------------------------------------------------------------------------
-- DB Proxy: addon.db.profile accessor
-- Reads/writes BazCoreDB.profiles[activeProfile][addonName][key]
---------------------------------------------------------------------------

function BazCore:CreateDBProxy(addonName)
    local profileProxy = setmetatable({}, {
        __index = function(_, key)
            local sv = BazCoreDB
            if not sv or not sv.profiles then return nil end
            local profileName = sv.activeProfile or DEFAULT_PROFILE
            local profile = sv.profiles[profileName]
            if not profile or not profile[addonName] then return nil end
            return profile[addonName][key]
        end,
        __newindex = function(_, key, value)
            local sv = BazCoreDB
            if not sv then return end
            local profileName = sv.activeProfile or DEFAULT_PROFILE
            if not sv.profiles then sv.profiles = {} end
            if not sv.profiles[profileName] then sv.profiles[profileName] = {} end
            if not sv.profiles[profileName][addonName] then sv.profiles[profileName][addonName] = {} end
            sv.profiles[profileName][addonName][key] = value
        end,
        __pairs = function(_)
            local sv = BazCoreDB
            if not sv or not sv.profiles then return next, {}, nil end
            local profileName = sv.activeProfile or DEFAULT_PROFILE
            local section = sv.profiles[profileName] and sv.profiles[profileName][addonName]
            return next, section or {}, nil
        end,
    })

    return { profile = profileProxy }
end

-- AddonMixin method
local AddonMixin = BazCore.AddonMixin

function AddonMixin:OnProfileChanged(handler)
    if not profileCallbacks[self.name] then
        profileCallbacks[self.name] = {}
    end
    table.insert(profileCallbacks[self.name], handler)
end

---------------------------------------------------------------------------
-- Auto-Generated Profile Options Table
-- Unified - one Profiles page in BazCore settings for all addons
---------------------------------------------------------------------------

function BazCore:GetProfileOptionsTable()
    local function RefreshProfilesPanel()
        -- Re-render the standalone Options window's Profiles
        -- subcategory if it's currently visible. Uses BazCore's
        -- public RefreshOptions API rather than poking at the
        -- internal optionsTables.canvas field (that field was never
        -- populated, so the old direct-poke path silently no-op'd).
        if BazCore.RefreshOptions then
            BazCore:RefreshOptions("BazCore-Profiles")
        end
    end

    local function BuildProfileArgs()
        local profileList = BazCore:ListProfiles()
        local profileGroups = {}

        for i, profileName in ipairs(profileList) do
            local isActive    = (profileName == BazCore:GetActiveProfile())
            local isBuiltin   = (profileName == DEFAULT_PROFILE)
            local isDefault   = (profileName == BazCore:GetDefaultProfile())

            local nameLabel = profileName
            if isActive  then nameLabel = nameLabel .. " |cff00ff00(active)|r"  end
            if isBuiltin then nameLabel = nameLabel .. " |cffffd700(default)|r" end

            profileGroups["profile_" .. i] = {
                order = i,
                type = "group",
                name = nameLabel,
                args = {
                    statusHeader = {
                        order = 1,
                        type = "header",
                        name = "Profile: " .. profileName,
                    },
                    rename = {
                        order = 1.5,
                        type = "input",
                        name = isBuiltin and "Profile Name (cannot rename Default)" or "Profile Name",
                        desc = isBuiltin and "" or "Type a new name and press Enter to rename",
                        get = function() return profileName end,
                        set = function(_, val)
                            if isBuiltin then
                                BazCore:Print("Cannot rename the Default profile.")
                                return
                            end
                            if val and val ~= "" and val ~= profileName then
                                if BazCore:RenameProfile(profileName, val) then
                                    BazCore:Print("Renamed '" .. profileName .. "' to '" .. val .. "'")
                                    RefreshProfilesPanel()
                                else
                                    BazCore:Print("Could not rename: name may already exist.")
                                end
                            end
                        end,
                    },
                    activate = {
                        order = 2,
                        type = "execute",
                        name = isActive and "|cff00ff00Active Profile|r" or "Switch to This Profile",
                        desc = isActive and "This is the current profile" or "Activate this profile for all Baz Suite addons",
                        func = function()
                            if not isActive then
                                BazCore:SetActiveProfile(profileName)
                                BazCore:Print("Switched to profile: " .. profileName)
                                RefreshProfilesPanel()
                            end
                        end,
                    },
                    setDefault = {
                        order = 3,
                        type = "execute",
                        name = isDefault and "|cffffd700Default for New Characters|r" or "Set as Default for New Characters",
                        desc = isDefault
                            and "New characters automatically attach to this profile."
                            or "Make this the profile new characters automatically use on first login. Existing characters are not affected.",
                        func = function()
                            if isDefault then
                                BazCore:Print("'" .. profileName .. "' is already the default for new characters.")
                            else
                                if BazCore:SetDefaultProfile(profileName) then
                                    BazCore:Print("'" .. profileName .. "' set as the default for new characters.")
                                    RefreshProfilesPanel()
                                end
                            end
                        end,
                    },
                    copyHeader = {
                        order = 10,
                        type = "header",
                        name = "Actions",
                    },
                    copyFrom = {
                        order = 11,
                        type = "select",
                        name = "Copy Settings From",
                        desc = "Overwrite this profile with settings from another (all addons)",
                        values = function()
                            local vals = {}
                            for _, name in ipairs(BazCore:ListProfiles()) do
                                if name ~= profileName then
                                    vals[name] = name
                                end
                            end
                            return vals
                        end,
                        get = function() return "" end,
                        set = function(_, val)
                            if BazCore:CopyProfile(val, profileName) then
                                BazCore:Print("Copied '" .. val .. "' into '" .. profileName .. "'")
                                if isActive then
                                    for addonName, config in pairs(BazCore.addons) do
                                        if config.profiles then
                                            BazCore:FireProfileChanged(addonName, profileName, profileName)
                                        end
                                    end
                                end
                            end
                        end,
                    },
                    resetProfile = {
                        order = 12,
                        type = "execute",
                        name = "Reset to Defaults",
                        desc = "Reset all addon settings in this profile to defaults",
                        confirm = true,
                        confirmText = "Reset '" .. profileName .. "' to defaults for all addons?",
                        func = function()
                            BazCore:ResetProfile(profileName)
                            BazCore:Print("'" .. profileName .. "' reset to defaults.")
                        end,
                    },
                    deleteProfile = {
                        order = 20,
                        type = "execute",
                        name = "|cffff4444Delete This Profile|r",
                        desc = isBuiltin and "Cannot delete Default profile" or (isActive and "Cannot delete the active profile" or "Permanently delete this profile"),
                        confirm = not (isBuiltin or isActive),
                        confirmText = "Delete profile '" .. profileName .. "'? This cannot be undone.",
                        func = function()
                            if isBuiltin then
                                BazCore:Print("Cannot delete the Default profile.")
                            elseif isActive then
                                BazCore:Print("Cannot delete the active profile. Switch first.")
                            else
                                BazCore:DeleteProfile(profileName)
                                BazCore:Print("Deleted profile: " .. profileName)
                                RefreshProfilesPanel()
                            end
                        end,
                    },
                    assignHeader = {
                        order = 30,
                        type = "header",
                        name = "Auto-Assignment",
                    },
                    assignDesc = {
                        order = 31,
                        type = "description",
                        name = "Automatically use this profile for:",
                    },
                    assignChar = {
                        order = 32,
                        type = "execute",
                        name = "This Character",
                        func = function()
                            BazCore:AssignProfile("character", profileName)
                            BazCore:Print("'" .. profileName .. "' assigned to this character.")
                        end,
                    },
                    assignClass = {
                        order = 33,
                        type = "execute",
                        name = "This Class",
                        func = function()
                            BazCore:AssignProfile("class", profileName)
                            BazCore:Print("'" .. profileName .. "' assigned to this class.")
                        end,
                    },
                    assignSpec = {
                        order = 34,
                        type = "execute",
                        name = "This Spec",
                        func = function()
                            if BazCore:AssignProfile("spec", profileName) then
                                BazCore:Print("'" .. profileName .. "' assigned to this spec.")
                            else
                                BazCore:Print("Could not determine current spec.")
                            end
                        end,
                    },
                },
            }
        end

        return profileGroups
    end

    local activeProfile  = BazCore:GetActiveProfile()
    local defaultProfile = BazCore:GetDefaultProfile()

    return {
        name = "Profiles",
        subtitle = "Baz Suite profile management",
        type = "group",
        args = {
            intro = {
                order = 0.1,
                type = "lead",
                text = "Profiles control settings for all Baz Suite addons at once. Switching profiles changes every addon's configuration together.",
            },
            statusNote = {
                order = 0.2,
                type = "note",
                style = "info",
                text = "Active profile: |cff00ff00" .. activeProfile .. "|r" ..
                       "    \194\183    Default for new characters: |cffffd700" .. defaultProfile .. "|r" ..
                       "\n\nNew characters auto-attach to the default profile on first login. Mark any profile as default with the |cffffd700Set as Default|r button on its page.",
            },
            newProfile = {
                order = 2,
                type = "execute",
                name = "Create New Profile",
                desc = "Create a new profile for all Baz Suite addons",
                func = function()
                    local profiles = BazCore:ListProfiles()
                    local name = "New Profile"
                    local num = 1
                    local nameExists = true
                    while nameExists do
                        nameExists = false
                        for _, p in ipairs(profiles) do
                            if p == name then
                                nameExists = true
                                num = num + 1
                                name = "New Profile " .. num
                                break
                            end
                        end
                    end
                    BazCore:CreateProfile(name)
                    BazCore:Print("Created profile: " .. name)
                    RefreshProfilesPanel()
                end,
            },
            profiles = {
                order = 10,
                type = "group",
                name = "Profiles",
                args = BuildProfileArgs(),
            },
        },
    }
end
