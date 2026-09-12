-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazCore Memory Log
--
-- Long-term memory sampler. The MemoryPage's live view (60 seconds at
-- 0.5 Hz, in-memory) is great for "is this widget leaking RIGHT NOW"
-- but useless for finding slow drift or correlating growth with
-- gameplay events. This module fills that gap:
--
--   * One snapshot per minute, persisted to BazCoreDB
--   * Per-addon series, not just the combined total
--   * Annotated events (login / reload / combat / zone change) so the
--     user can answer "what changed when this addon spiked?"
--   * Public API consumed by MemoryPage's "Trends & Events" section
--   * Slash command + export hook so the data can be pasted into a
--     spreadsheet or shared in a bug report
--
-- The data is intentionally small: 240 samples (4 hours) of ~10 addons
-- = roughly 30-50 KB in the saved variable, which is negligible next
-- to the in-game memory footprint we're trying to measure.
---------------------------------------------------------------------------

BazCore = BazCore or {}

local MAX_SAMPLES     = 240   -- 4 hours of one-per-minute data
local MAX_EVENTS      = 200   -- ring buffer of recent annotated events
local SAMPLE_INTERVAL = 60    -- seconds between samples

local log = {
    samples   = {},
    head      = 0,            -- last-written sample index
    events    = {},
    eventHead = 0,
}

---------------------------------------------------------------------------
-- Tracked addons - mirrors MemoryPage's tracking list. We resolve this
-- on every snapshot rather than caching so newly-registered addons
-- start showing up immediately.
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
-- Persistence - both directions go through BazCoreDB.memLog.
---------------------------------------------------------------------------

local function PersistRef()
    if not BazCoreDB then return nil end
    BazCoreDB.memLog = BazCoreDB.memLog or {
        samples   = {},
        head      = 0,
        events    = {},
        eventHead = 0,
        version   = 1,
    }
    return BazCoreDB.memLog
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
-- Snapshot - takes a memory reading for every tracked addon and pushes
-- it onto the ring buffer. Called from the periodic ticker AND from
-- the event hook so we always have a "before/after" pair around the
-- interesting moment.
---------------------------------------------------------------------------

local function Snapshot()
    if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end

    local sample = { t = time(), addons = {}, total = 0 }
    for _, name in ipairs(GetTrackedAddons()) do
        local kb = (GetAddOnMemoryUsage and GetAddOnMemoryUsage(name)) or 0
        sample.addons[name] = kb
        sample.total = sample.total + kb
    end

    -- collectgarbage("count") returns the total Lua heap size in KB
    -- across the entire UI. Per-addon GetAddOnMemoryUsage undercounts
    -- because it doesn't capture transient intermediate strings /
    -- upvalues that the GC eventually reclaims. Watching the Lua heap
    -- shows the REAL allocation rate so we can spot spikes that don't
    -- show up cleanly in the per-addon columns.
    sample.luaHeapKB = collectgarbage and collectgarbage("count") or 0

    log.head = (log.head % MAX_SAMPLES) + 1
    log.samples[log.head] = sample
    Save()
end

---------------------------------------------------------------------------
-- Event annotations - tagged with the current snapshot so the page can
-- show "memory at the moment of <event>". Snapshot first, then push
-- the event referencing the same timestamp.
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

-- GetMemoryHistory()
--   Returns the samples in chronological order (oldest first). Each
--   entry is { t, total, addons = { [name] = kb } }.
function BazCore:GetMemoryHistory()
    local out = {}
    for i = 1, MAX_SAMPLES do
        local idx = ((log.head + i - 1) % MAX_SAMPLES) + 1
        local s = log.samples[idx]
        if s then out[#out + 1] = s end
    end
    return out
end

-- GetMemoryEvents()
--   Returns annotated events in chronological order. Each entry:
--   { t, type, label, sampleT }.
function BazCore:GetMemoryEvents()
    local out = {}
    for i = 1, MAX_EVENTS do
        local idx = ((log.eventHead + i - 1) % MAX_EVENTS) + 1
        local e = log.events[idx]
        if e then out[#out + 1] = e end
    end
    return out
end

-- GetMemoryGrowth(windowSec)
--   For each tracked addon, computes (latest_kb - oldest_kb_within_window)
--   over the requested window in seconds. Useful for spotting steady
--   growth (= leaking). Returns an array sorted descending by growth,
--   each entry { name, deltaKB, ratePerHour, latestKB, oldestKB }.
function BazCore:GetMemoryGrowth(windowSec)
    windowSec = windowSec or 3600  -- default: 1 hour
    local hist = self:GetMemoryHistory()
    if #hist < 2 then return {} end

    local now = time()
    local cutoff = now - windowSec

    -- Latest sample
    local latest = hist[#hist]

    -- Find oldest sample inside the window
    local oldest
    for _, s in ipairs(hist) do
        if s.t >= cutoff then
            oldest = s
            break
        end
    end
    if not oldest or oldest == latest then return {} end

    local elapsedHours = math.max((latest.t - oldest.t) / 3600, 1 / 60)

    local out = {}
    for name, kb in pairs(latest.addons) do
        local was = oldest.addons[name] or kb  -- if addon wasn't tracked yet, treat as no growth
        local delta = kb - was
        out[#out + 1] = {
            name        = name,
            latestKB    = kb,
            oldestKB    = was,
            deltaKB     = delta,
            ratePerHour = delta / elapsedHours,
        }
    end
    table.sort(out, function(a, b) return a.deltaKB > b.deltaKB end)
    return out, oldest.t, latest.t
end

-- Quote a CSV field if it could break parsing - i.e. contains a
-- comma or quote. Numbers and timestamps go through as-is.
local function CsvField(v)
    if v == nil then return "" end
    local s = tostring(v)
    if s:find('[",]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

-- BuildDumpString()
--   Builds the full CSV log as a single string (instead of printing
--   line-by-line). Used by the popup dialog and any future export hook.
local function BuildDumpString()
    local hist = BazCore:GetMemoryHistory()
    if #hist == 0 then return nil end

    -- Collect every addon name across the history so the CSV columns
    -- line up even when an addon was registered partway through.
    local nameSet, nameList = {}, {}
    for _, s in ipairs(hist) do
        for name in pairs(s.addons) do
            if not nameSet[name] then
                nameSet[name] = true
                nameList[#nameList + 1] = name
            end
        end
    end
    table.sort(nameList)

    local lines = {}

    -- Header. lua_heap_kb is the full Lua heap (collectgarbage count) -
    -- a stronger signal than the per-addon columns because it captures
    -- intermediate strings / closures the GC eventually reclaims.
    local header = { "time", "total_kb", "lua_heap_kb" }
    for _, n in ipairs(nameList) do header[#header + 1] = n end
    lines[#lines + 1] = table.concat(header, ",")

    -- Data rows
    for _, s in ipairs(hist) do
        local row = {
            date("%Y-%m-%d %H:%M:%S", s.t),
            string.format("%.0f", s.total),
            string.format("%.0f", s.luaHeapKB or 0),
        }
        for _, n in ipairs(nameList) do
            row[#row + 1] = string.format("%.0f", s.addons[n] or 0)
        end
        lines[#lines + 1] = table.concat(row, ",")
    end

    -- Events appended after a blank line so a CSV parser can split
    -- them into a separate sheet if desired.
    local events = BazCore:GetMemoryEvents()
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

-- DumpMemoryLog()
--   Prints the log to chat as CSV. Kept for /bazmem dump - useful
--   when you want a quick scan of recent rows without the popup.
function BazCore:DumpMemoryLog()
    local content, sampleCount = BuildDumpString()
    if not content then
        print("|cffffd700BazCore:|r memory log is empty - wait for the first sample (samples are taken every minute).")
        return
    end

    print("|cffffd700BazCore Memory Log:|r " .. sampleCount .. " sample(s). Copy lines below into a spreadsheet (CSV):")
    for line in content:gmatch("[^\n]+") do
        print(line)
    end
end

-- OpenMemoryDumpDialog()
--   Opens (or rebuilds the content of) the export dialog. The dialog
--   itself lives in CopyDialog.lua and is reusable by any addon that
--   wants a paste-friendly export popup; we just hand it our content.
function BazCore:OpenMemoryDumpDialog()
    local content, sampleCount = BuildDumpString()
    if not content then
        print("|cffffd700BazCore:|r memory log is empty - wait for the first sample (samples are taken every minute).")
        return
    end
    if not BazCore.OpenCopyDialog then
        -- Fall back to chat dump if CopyDialog isn't loaded.
        return self:DumpMemoryLog()
    end
    BazCore:OpenCopyDialog({
        title    = "BazCore Memory Log Export",
        subtitle = "CSV format. Click Select All then Ctrl+C to copy.",
        content  = content,
        stats    = string.format("%d sample(s) | %d characters",
                                 sampleCount, #content),
    })
end

-- ResetMemoryLog()
--   Wipes the persistent log. Bound to a button on the page.
function BazCore:ResetMemoryLog()
    log.samples   = {}
    log.head      = 0
    log.events    = {}
    log.eventHead = 0
    Save()
end

-- MarkMemoryEvent(type, label)
--   Public hook for any module to drop a labeled annotation in the
--   log. Snapshots first, then tags the new sample with the given
--   type + label so the dump shows memory at exactly that moment.
--   Use for: panel-show/hide hooks, tab-switch hooks, expensive
--   one-shot operations the user wants to bracket.
function BazCore:MarkMemoryEvent(evType, label)
    PushEvent(evType or "mark", label)
end

-- WatchMemory(durationSec, intervalSec, opts)
--   Switches to high-frequency sampling for `durationSec` seconds, at
--   `intervalSec` cadence (default 2 s). Useful for catching transient
--   spikes that the per-minute ticker glosses over - the user invokes
--   this right before reproducing the issue.
--
--   opts.onComplete = optional fn() fired when the watch finishes
--       naturally (not when cancelled). Used by /bazmem armwatch to
--       auto-open the export popup so the user can paste the dump
--       without remembering an extra slash command.
local watchTicker
function BazCore:WatchMemory(durationSec, intervalSec, opts)
    durationSec = tonumber(durationSec) or 60
    intervalSec = tonumber(intervalSec) or 2
    opts = opts or {}
    if watchTicker then watchTicker:Cancel() end

    local started = GetTime()
    PushEvent("watch_start", string.format("%ds @ %.1fs cadence", durationSec, intervalSec))

    watchTicker = C_Timer.NewTicker(intervalSec, function(self)
        Snapshot()
        if (GetTime() - started) >= durationSec then
            PushEvent("watch_end")
            self:Cancel()
            watchTicker = nil
            if opts.onComplete then
                pcall(opts.onComplete)
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Event hookup
--
-- We can't register events until the addon is loaded, but we can't
-- access BazCoreDB until PLAYER_LOGIN. The bootstrap below restores
-- the persisted log on login, then takes an immediate snapshot tagged
-- as "login" or "reload" depending on whether the world frame already
-- existed (PLAYER_ENTERING_WORLD's isReload arg gives us this).
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

        -- Honour any pending /bazmem armwatch the user set before the
        -- last /reload. SavedVariables persist across reload, so a
        -- flag stored here survives the unload+reload cycle and we
        -- can pick it up on the very first sample after login.
        local pending = BazCoreDB and BazCoreDB.memLogPendingWatch
        if pending then
            BazCoreDB.memLogPendingWatch = nil  -- consume; one-shot per arm
            local secs    = tonumber(pending.secs)        or 30
            local cadence = tonumber(pending.intervalSec) or 2
            -- Run shortly after PLAYER_LOGIN so the rest of the suite
            -- has finished its own login work (registrations, queued
            -- callbacks). 0.1s is enough buffer; the watch then runs
            -- before the user can realistically open the panel.
            C_Timer.After(0.1, function()
                PushEvent("armwatch_fire",
                    string.format("auto: %ds @ %.1fs", secs, cadence))
                if BazCore.WatchMemory then
                    BazCore:WatchMemory(secs, cadence, {
                        -- When the watch ends, pop the export dialog
                        -- straight away so the user doesn't have to
                        -- remember /bazmem export. Skip if their UI
                        -- isn't visible (taxi flight, etc.) - they'd
                        -- rather see it next time.
                        onComplete = function()
                            if BazCore.OpenMemoryDumpDialog then
                                BazCore:OpenMemoryDumpDialog()
                                print("|cffffd700BazCore:|r armed watch finished. Memory log popped open for export.")
                            end
                        end,
                    })
                end
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        local _, isReload = ...
        if not enteredWorldOnce then
            enteredWorldOnce = true
            PushEvent(isReload and "reload" or "login")
        else
            -- Loading screens between zones (e.g. portal, instance entry)
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
-- Slash command - quick access without opening the panel.
--   /bazmem        - prints a summary of current growth rates
--   /bazmem dump   - dumps the full TSV log
---------------------------------------------------------------------------

SLASH_BAZMEM1 = "/bazmem"
SlashCmdList.BAZMEM = function(msg)
    msg = msg or ""

    -- Strip the trailing whitespace but preserve case + spaces inside
    -- the label so "/bazmem mark After Opening Panel" works.
    local raw = msg:gsub("^%s+", ""):gsub("%s+$", "")
    local cmd = raw:match("^(%S+)") or ""
    local rest = raw:sub(#cmd + 1):gsub("^%s+", "")
    local lcmd = cmd:lower()

    if lcmd == "export" or lcmd == "popup" then
        BazCore:OpenMemoryDumpDialog()
        return
    end
    if lcmd == "dump" then
        BazCore:DumpMemoryLog()
        return
    end
    if lcmd == "reset" then
        BazCore:ResetMemoryLog()
        print("|cffffd700BazCore:|r memory log cleared.")
        return
    end
    if lcmd == "mark" then
        local label = rest ~= "" and rest or "manual mark"
        BazCore:MarkMemoryEvent("mark", label)
        local heap = collectgarbage and collectgarbage("count") or 0
        print(string.format("|cffffd700BazCore:|r marked '%s' (Lua heap: %.0f KB)", label, heap))
        return
    end
    if lcmd == "watch" then
        local secs = tonumber(rest:match("^(%d+)")) or 60
        local cadence = tonumber(rest:match("@(%d+%.?%d*)")) or 2
        BazCore:WatchMemory(secs, cadence, {
            -- Manual /bazmem watch also pops the export dialog when
            -- it finishes - same convenience as armwatch.
            onComplete = function()
                if BazCore.OpenMemoryDumpDialog then
                    BazCore:OpenMemoryDumpDialog()
                    print("|cffffd700BazCore:|r watch finished. Memory log popped open for export.")
                end
            end,
        })
        print(string.format("|cffffd700BazCore:|r sampling every %.1fs for %ds. Reproduce the issue now; popup will open when done.",
            cadence, secs))
        return
    end
    if lcmd == "armwatch" then
        local secs = tonumber(rest:match("^(%d+)")) or 30
        local cadence = tonumber(rest:match("@(%d+%.?%d*)")) or 2
        if not BazCoreDB then
            print("|cffffd700BazCore:|r DB not ready yet - try after /reload.")
            return
        end
        BazCoreDB.memLogPendingWatch = { secs = secs, intervalSec = cadence }
        print(string.format("|cffffd700BazCore:|r watch armed - will sample every %.1fs for %ds starting right after your next /reload, then pop the export popup. Type |cffffd700/bazmem disarm|r to cancel.",
            cadence, secs))
        return
    end
    if lcmd == "disarm" then
        if BazCoreDB and BazCoreDB.memLogPendingWatch then
            BazCoreDB.memLogPendingWatch = nil
            print("|cffffd700BazCore:|r armed watch cancelled.")
        else
            print("|cffffd700BazCore:|r no armed watch to cancel.")
        end
        return
    end

    local growth = BazCore:GetMemoryGrowth(3600)
    if #growth == 0 then
        print("|cffffd700BazCore:|r not enough samples yet for a growth estimate (need at least 2 minutes of data).")
        return
    end
    print("|cffffd700BazCore Memory Growth (last hour):|r")
    for i = 1, math.min(8, #growth) do
        local g = growth[i]
        local sign = g.deltaKB >= 0 and "+" or ""
        print(string.format("  %-22s %s%.1f KB  (%s%.1f KB/h)  now %.0f KB",
            g.name, sign, g.deltaKB, sign, g.ratePerHour, g.latestKB))
    end
    print("|cffffd700Commands:|r")
    print("  |cffffd700/bazmem mark <label>|r     - tag an event in the log")
    print("  |cffffd700/bazmem watch <secs>|r     - sample every 2s for a burst, popup at end")
    print("  |cffffd700/bazmem armwatch <secs>|r  - watch fires AFTER next /reload (catches first-open)")
    print("  |cffffd700/bazmem disarm|r           - cancel an armed watch")
    print("  |cffffd700/bazmem export|r           - popup CSV (paste-friendly)")
    print("  |cffffd700/bazmem dump|r             - chat CSV (quick scan)")
    print("  |cffffd700/bazmem reset|r            - clear log")
end
