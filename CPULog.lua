-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazCore CPU Log
--
-- Long-term per-addon CPU sampler. Mirror of MemoryLog but for CPU
-- usage. Two important differences from memory:
--
--   * CPU profiling is gated by the global `scriptProfile` CVar.
--     When it's 0, GetAddOnCPUUsage returns 0 for everything.
--     Setting it requires a /reload to take effect.
--
--   * GetAddOnCPUUsage returns CUMULATIVE ms since the CVar was
--     enabled (or session start). To show "current rate" we sample
--     periodically and compute deltas. The persistent log stores
--     the cumulative reading per sample so the deltas can be
--     reconstructed offline; reload events reset the counter so
--     each session is its own monotonic series.
--
-- Sampling cadence matches MemoryLog: one snapshot per minute,
-- 240 samples = 4 hours retained. Persisted to BazCoreDB.cpuLog.
---------------------------------------------------------------------------

BazCore = BazCore or {}

local MAX_SAMPLES     = 240   -- 4 hours of one-per-minute data
local MAX_EVENTS      = 200   -- ring buffer of recent annotated events
local SAMPLE_INTERVAL = 60    -- seconds between samples

local log = {
    samples   = {},
    head      = 0,
    events    = {},
    eventHead = 0,
}

---------------------------------------------------------------------------
-- Tracked addons - mirrors CPUPage's tracking list. Resolved on every
-- snapshot so newly-registered addons start showing up immediately.
---------------------------------------------------------------------------

local function GetTrackedAddons()
    local list = { "BazCore" }
    local seen = { BazCore = true }
    for name in pairs(BazCore.addons or {}) do
        if not seen[name] then
            list[#list + 1] = name
            seen[name] = true
        end
    end
    table.sort(list)
    return list
end

---------------------------------------------------------------------------
-- Persistence - both directions go through BazCoreDB.cpuLog.
---------------------------------------------------------------------------

local function PersistRef()
    if not BazCoreDB then return nil end
    BazCoreDB.cpuLog = BazCoreDB.cpuLog or {
        samples   = {},
        head      = 0,
        events    = {},
        eventHead = 0,
        version   = 1,
    }
    return BazCoreDB.cpuLog
end

local function Save()
    local p = PersistRef()
    if not p then return end
    p.samples   = log.samples
    p.head      = log.head
    p.events    = log.events
    p.eventHead = log.eventHead
end

local function Restore()
    local p = PersistRef()
    if not p then return end
    log.samples   = p.samples   or {}
    log.head      = p.head      or 0
    log.events    = p.events    or {}
    log.eventHead = p.eventHead or 0
end

---------------------------------------------------------------------------
-- scriptProfile CVar guards
--
-- Without scriptProfile, GetAddOnCPUUsage returns 0 for everything.
-- Snapshot still records (zero rows are useful as "CPU profiling is
-- off" signal) but skips delta computations that would be meaningless.
---------------------------------------------------------------------------

local function IsProfilingEnabled()
    return GetCVarBool and GetCVarBool("scriptProfile") or false
end

---------------------------------------------------------------------------
-- Snapshot - takes a CPU reading for every tracked addon and pushes
-- it onto the ring buffer. Cumulative-since-session in `addons[name]`,
-- pre-computed delta-since-last-sample in `delta[name]`.
---------------------------------------------------------------------------

local function Snapshot()
    if UpdateAddOnCPUUsage then UpdateAddOnCPUUsage() end

    local sample = {
        t           = time(),
        addons      = {},
        delta       = {},
        total       = 0,
        deltaTotal  = 0,
        profilingOn = IsProfilingEnabled(),
    }

    -- Find the previous sample on the ring so we can compute deltas.
    -- Reload markers reset the cumulative counter, so we only diff
    -- against samples taken in the same session - the event log lets
    -- us detect that. For simplicity here we just check that the
    -- previous cumulative is <= current; if it dropped, treat as a
    -- session break and emit delta = current.
    local prev
    if log.head > 0 then prev = log.samples[log.head] end

    for _, name in ipairs(GetTrackedAddons()) do
        local ms = (GetAddOnCPUUsage and GetAddOnCPUUsage(name)) or 0
        sample.addons[name] = ms
        sample.total = sample.total + ms

        local prevMs = prev and prev.addons and prev.addons[name] or 0
        local d = ms - prevMs
        if d < 0 then d = ms end  -- session reset; previous can't apply
        sample.delta[name] = d
        sample.deltaTotal = sample.deltaTotal + d
    end

    log.head = (log.head % MAX_SAMPLES) + 1
    log.samples[log.head] = sample
    Save()
end

---------------------------------------------------------------------------
-- Event annotations
---------------------------------------------------------------------------

local function PushEvent(evType, label)
    Snapshot()
    log.eventHead = (log.eventHead % MAX_EVENTS) + 1
    log.events[log.eventHead] = {
        t       = time(),
        type    = evType,
        label   = label,
        sampleT = log.samples[log.head] and log.samples[log.head].t,
    }
    Save()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function BazCore:GetCPUHistory()
    local out = {}
    for i = 1, MAX_SAMPLES do
        local idx = ((log.head + i - 1) % MAX_SAMPLES) + 1
        local s = log.samples[idx]
        if s then out[#out + 1] = s end
    end
    return out
end

function BazCore:GetCPUEvents()
    local out = {}
    for i = 1, MAX_EVENTS do
        local idx = ((log.eventHead + i - 1) % MAX_EVENTS) + 1
        local e = log.events[idx]
        if e then out[#out + 1] = e end
    end
    return out
end

-- GetCPUTopConsumers(windowSec)
--   For each tracked addon, sums the per-sample deltas inside the
--   window so the result is total ms spent in that addon's code in
--   the window. Sorted descending. Returns the array plus the
--   timestamps of the oldest + newest samples used.
function BazCore:GetCPUTopConsumers(windowSec)
    windowSec = windowSec or 3600
    local hist = self:GetCPUHistory()
    if #hist < 2 then return {} end

    local now    = time()
    local cutoff = now - windowSec
    local oldest, newest

    local sums = {}
    for _, s in ipairs(hist) do
        if s.t >= cutoff then
            if not oldest then oldest = s end
            newest = s
            for name, d in pairs(s.delta or {}) do
                sums[name] = (sums[name] or 0) + d
            end
        end
    end
    if not newest or not oldest or oldest == newest then return {} end

    local elapsedHours = math.max((newest.t - oldest.t) / 3600, 1 / 60)

    local out = {}
    for name, total in pairs(sums) do
        out[#out + 1] = {
            name        = name,
            totalMs     = total,
            ratePerHour = total / elapsedHours,
        }
    end
    table.sort(out, function(a, b) return a.totalMs > b.totalMs end)
    return out, oldest.t, newest.t
end

---------------------------------------------------------------------------
-- Dump / export
---------------------------------------------------------------------------

local function CsvField(v)
    if v == nil then return "" end
    local s = tostring(v)
    if s:find('[",]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

local function BuildDumpString()
    local hist = BazCore:GetCPUHistory()
    if #hist == 0 then return nil end

    local nameSet, nameList = {}, {}
    for _, s in ipairs(hist) do
        for name in pairs(s.addons or {}) do
            if not nameSet[name] then
                nameSet[name] = true
                nameList[#nameList + 1] = name
            end
        end
    end
    table.sort(nameList)

    local lines = {}

    local header = { "time", "profiling_on", "total_ms_cumulative", "total_delta_ms" }
    for _, n in ipairs(nameList) do header[#header + 1] = n .. "_cumulative_ms" end
    for _, n in ipairs(nameList) do header[#header + 1] = n .. "_delta_ms" end
    lines[#lines + 1] = table.concat(header, ",")

    for _, s in ipairs(hist) do
        local row = {
            date("%Y-%m-%d %H:%M:%S", s.t),
            s.profilingOn and "1" or "0",
            string.format("%.2f", s.total or 0),
            string.format("%.2f", s.deltaTotal or 0),
        }
        for _, n in ipairs(nameList) do
            row[#row + 1] = string.format("%.2f", (s.addons and s.addons[n]) or 0)
        end
        for _, n in ipairs(nameList) do
            row[#row + 1] = string.format("%.2f", (s.delta and s.delta[n]) or 0)
        end
        lines[#lines + 1] = table.concat(row, ",")
    end

    local events = BazCore:GetCPUEvents()
    if #events > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "time,type,label"
        for _, e in ipairs(events) do
            lines[#lines + 1] = string.format("%s,%s,%s",
                date("%Y-%m-%d %H:%M:%S", e.t),
                CsvField(e.type),
                CsvField(e.label))
        end
    end

    return table.concat(lines, "\n"), #hist
end

function BazCore:DumpCPULog()
    local content, sampleCount = BuildDumpString()
    if not content then
        print("|cffffd700BazCore:|r CPU log is empty - wait for the first sample (samples are taken every minute).")
        return
    end
    print("|cffffd700BazCore CPU Log:|r " .. sampleCount .. " sample(s). Copy lines below into a spreadsheet (CSV):")
    for line in content:gmatch("[^\n]+") do
        print(line)
    end
end

function BazCore:OpenCPUDumpDialog()
    local content, sampleCount = BuildDumpString()
    if not content then
        print("|cffffd700BazCore:|r CPU log is empty - wait for the first sample.")
        return
    end
    if not BazCore.OpenCopyDialog then
        return self:DumpCPULog()
    end
    BazCore:OpenCopyDialog({
        title    = "BazCore CPU Log Export",
        subtitle = "CSV format. Click Select All then Ctrl+C to copy.",
        content  = content,
        stats    = string.format("%d sample(s) | %d characters",
                                 sampleCount, #content),
    })
end

function BazCore:ResetCPULog()
    log.samples   = {}
    log.head      = 0
    log.events    = {}
    log.eventHead = 0
    Save()
end

function BazCore:MarkCPUEvent(evType, label)
    PushEvent(evType or "mark", label)
end

function BazCore:IsCPUProfilingEnabled()
    return IsProfilingEnabled()
end

---------------------------------------------------------------------------
-- Per-function drill-down
--
-- GetFunctionCPUUsage(func, includeChildren) returns cumulative ms per
-- function reference, but you need the actual function refs to call it
-- on. Walk the addon's globals + its BazCore-registered table looking
-- for functions, deduping by identity, then rank descending. Includes
-- nested tables (addon.Module.SomeMethod) up to a depth cap so deeply
-- nested helpers are still visible.
--
-- Returns: array of { path, ms, msSelf } sorted by ms desc, where
--   ms     = cumulative ms including children
--   msSelf = own-body ms (children excluded)
---------------------------------------------------------------------------

-- Detect Blizzard / WoW UI frames - tables whose metatable's __index
-- exposes the standard Frame method `GetObjectType`. We skip these in
-- the walker because (a) recursing through frame method tables is
-- enormous and exposes internal Blizzard tables we don't want to
-- profile, and (b) calling GetFunctionCPUUsage on certain C-backed
-- frame methods can crash the client.
local function IsBlizzardFrame(t)
    if type(t) ~= "table" then return false end
    -- Frames respond to GetObjectType via their metatable's __index
    -- chain. rawget guards against any custom __index that might
    -- throw or recurse into us.
    local mt = getmetatable(t)
    if not mt then return false end
    local idx = rawget(mt, "__index")
    if type(idx) == "table"
       and type(rawget(idx, "GetObjectType")) == "function" then
        return true
    end
    -- Some addons put GetObjectType directly on the frame table.
    if type(rawget(t, "GetObjectType")) == "function" then
        return true
    end
    return false
end

-- Some keys under an addon's namespace point at known-bad-to-recurse
-- targets even when they're not Frame instances - things like the SV
-- root, the BazCore addon-config table itself (we already walk it
-- separately), or an addon's `core` field that loops back to BazCore.
local function ShouldSkipKey(k)
    if type(k) ~= "string" then return false end
    if k == "core"      then return true end  -- loop back to BazCore
    if k == "config"    then return true end  -- big options table
    if k == "db"        then return true end  -- SV proxy
    if k == "VERSION"   then return true end  -- string, harmless but noise
    return false
end

function BazCore:GetAddonFunctionCPU(addonName, opts)
    opts = opts or {}
    local maxDepth     = opts.maxDepth     or 3      -- conservative
    local minMs        = opts.minMs        or 0
    local maxFunctions = opts.maxFunctions or 2000   -- upper bound

    if not addonName then return {} end
    if not GetFunctionCPUUsage then return {} end

    -- Collect the root namespaces to walk. The big one is
    -- BazCore.addonNamespaces[name] - the per-file shared `addon`
    -- table captured at RegisterAddon time, where most Baz addons
    -- attach their modules (addon.Replica, addon.Window, addon.Tabs,
    -- etc.). Without this, the walker would only find what the
    -- addon's public _G global exposes, which is usually just a
    -- handful of methods. Plus the public global, the addon-config
    -- table, and the AddonMixin object for completeness. Identity-
    -- deduped via the `visited` set so a function reachable through
    -- multiple paths gets queried once.
    local roots = {}
    if BazCore.addonNamespaces and BazCore.addonNamespaces[addonName] then
        roots[#roots + 1] = {
            name = addonName,
            t    = BazCore.addonNamespaces[addonName],
        }
    end
    if BazCore.addonObjects and BazCore.addonObjects[addonName] then
        roots[#roots + 1] = {
            name = addonName .. "(obj)",
            t    = BazCore.addonObjects[addonName],
        }
    end
    if _G[addonName] and type(_G[addonName]) == "table" then
        roots[#roots + 1] = { name = addonName, t = _G[addonName] }
    end
    if BazCore.addons and BazCore.addons[addonName] then
        roots[#roots + 1] = {
            name = addonName .. "(config)",
            t    = BazCore.addons[addonName],
        }
    end
    if addonName == "BazNotificationCenter" and _G.BNC then
        roots[#roots + 1] = { name = "BNC", t = _G.BNC }
    end

    if #roots == 0 then return {} end

    if UpdateAddOnCPUUsage then UpdateAddOnCPUUsage() end

    local results = {}
    local seenFn  = {}
    local visited = {}

    -- Wrap pairs() in pcall so a custom __pairs metamethod that errors
    -- (or any other table-iter pathology) doesn't kill the whole walk.
    local function safePairs(t)
        local ok, iter, state, ctrl = pcall(pairs, t)
        if not ok then return function() end end
        return iter, state, ctrl
    end

    -- Wrap GetFunctionCPUUsage too. Calling it on certain C-backed
    -- functions has been reported to crash the client - belt + braces.
    local function safeCPU(fn, includeChildren)
        local ok, v = pcall(GetFunctionCPUUsage, fn, includeChildren)
        if ok and type(v) == "number" then return v end
        return 0
    end

    local function walk(t, prefix, depth)
        if visited[t] or depth > maxDepth then return end
        if IsBlizzardFrame(t) then return end       -- crash guard
        if #results >= maxFunctions then return end -- cap to keep dump readable
        visited[t] = true

        for k, v in safePairs(t) do
            if not ShouldSkipKey(k) then
                local kstr = tostring(k)
                local path = prefix == "" and kstr or (prefix .. "." .. kstr)
                if type(v) == "function" and not seenFn[v] then
                    seenFn[v] = true
                    local ms     = safeCPU(v, true)
                    local msSelf = safeCPU(v, false)
                    if ms >= minMs then
                        results[#results + 1] = {
                            path   = path,
                            ms     = ms,
                            msSelf = msSelf,
                        }
                    end
                    if #results >= maxFunctions then return end
                elseif type(v) == "table"
                       and not visited[v]
                       and not IsBlizzardFrame(v) then
                    walk(v, path, depth + 1)
                end
            end
        end
    end

    for _, root in ipairs(roots) do
        walk(root.t, root.name, 1)
    end

    table.sort(results, function(a, b) return a.ms > b.ms end)
    return results
end

-- Print the top N functions for `addonName` to chat. n defaults to 20.
function BazCore:DumpAddonFunctionCPU(addonName, n)
    if not IsProfilingEnabled() then
        print("|cffffd700BazCore:|r CPU profiling is off. Enable via /bazcpu enable first.")
        return
    end
    local results = self:GetAddonFunctionCPU(addonName)
    if not results or #results == 0 then
        print("|cffffd700BazCore:|r no tracked functions found for '"
            .. tostring(addonName) .. "'.")
        return
    end
    n = n or 20
    local shown = math.min(n, #results)
    print(string.format("|cffffd700BazCore CPU Top %d functions for %s:|r",
        shown, tostring(addonName)))
    print("  ms (incl)   ms (self)   path")
    for i = 1, shown do
        local r = results[i]
        print(string.format("  %9.1f   %9.1f   %s",
            r.ms, r.msSelf, r.path))
    end
end

-- Enable scriptProfile and reload. Bound to the page's setup-card
-- button. SetCVar("scriptProfile", "1") returns true on success;
-- the CVar requires a /reload before GetAddOnCPUUsage starts
-- returning non-zero.
function BazCore:EnableCPUProfiling(reloadAfter)
    if not SetCVar then return false end
    SetCVar("scriptProfile", "1")
    if reloadAfter and ReloadUI then
        ReloadUI()
    end
    return true
end

function BazCore:DisableCPUProfiling(reloadAfter)
    if not SetCVar then return false end
    SetCVar("scriptProfile", "0")
    if reloadAfter and ReloadUI then
        ReloadUI()
    end
    return true
end

---------------------------------------------------------------------------
-- Event hookup - same shape as MemoryLog so the two logs are
-- coherent on the same gameplay events.
---------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("PLAYER_REGEN_DISABLED")
boot:RegisterEvent("PLAYER_REGEN_ENABLED")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")

local enteredWorldOnce = false

boot:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        Restore()
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(SAMPLE_INTERVAL, Snapshot)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitial, isReload = ...
        if not enteredWorldOnce then
            enteredWorldOnce = true
            PushEvent(isReload and "reload" or "login")
        else
            PushEvent("loading", GetMinimapZoneText and GetMinimapZoneText() or nil)
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        PushEvent("combat_start")
    elseif event == "PLAYER_REGEN_ENABLED" then
        PushEvent("combat_end")
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        PushEvent("zone", GetMinimapZoneText and GetMinimapZoneText() or nil)
    end
end)

---------------------------------------------------------------------------
-- Slash command
--   /bazcpu             - prints top consumers + status
--   /bazcpu enable      - enable scriptProfile + /reload
--   /bazcpu disable     - disable scriptProfile + /reload
--   /bazcpu mark <lbl>  - tag an event
--   /bazcpu export      - popup CSV
--   /bazcpu dump        - chat CSV
--   /bazcpu reset       - clear log
---------------------------------------------------------------------------

SLASH_BAZCPU1 = "/bazcpu"
SlashCmdList.BAZCPU = function(msg)
    msg = msg or ""
    local raw = msg:gsub("^%s+", ""):gsub("%s+$", "")
    local cmd = raw:match("^(%S+)") or ""
    local rest = raw:sub(#cmd + 1):gsub("^%s+", "")
    local lcmd = cmd:lower()

    if lcmd == "enable" then
        BazCore:EnableCPUProfiling(true)
        return
    end
    if lcmd == "disable" then
        BazCore:DisableCPUProfiling(true)
        return
    end
    if lcmd == "export" or lcmd == "popup" then
        BazCore:OpenCPUDumpDialog(); return
    end
    if lcmd == "dump" then BazCore:DumpCPULog(); return end
    if lcmd == "reset" then
        BazCore:ResetCPULog()
        print("|cffffd700BazCore:|r CPU log cleared.")
        return
    end
    if lcmd == "mark" then
        local label = rest ~= "" and rest or "manual mark"
        BazCore:MarkCPUEvent("mark", label)
        print(string.format("|cffffd700BazCore:|r marked '%s'", label))
        return
    end
    if lcmd == "mini" then
        if BazCore.ToggleCPUMiniMonitor then
            BazCore:ToggleCPUMiniMonitor()
            print(string.format("|cffffd700BazCore:|r mini monitor %s",
                BazCore:IsCPUMiniMonitorShown() and "shown" or "hidden"))
        end
        return
    end
    if lcmd == "top" then
        local target = rest:match("^(%S+)") or "BazCore"
        local n      = tonumber(rest:match("(%d+)%s*$")) or 20
        BazCore:DumpAddonFunctionCPU(target, n)
        return
    end

    print("|cffffd700BazCore CPU Profile|r")
    if not IsProfilingEnabled() then
        print("  Profiling is |cffff8c5cdisabled|r. /bazcpu enable to turn on (will /reload).")
        return
    end

    local top = BazCore:GetCPUTopConsumers(3600)
    if #top == 0 then
        print("  Not enough samples yet for a top-consumers report.")
        return
    end
    print("  Top CPU consumers (last hour):")
    for i = 1, math.min(8, #top) do
        local g = top[i]
        print(string.format("  %-22s  %.0f ms total  (%.0f ms/h)",
            g.name, g.totalMs, g.ratePerHour))
    end
    print("|cffffd700Commands:|r /bazcpu top <addon> | enable | disable | mark | mini | export | dump | reset")
end
