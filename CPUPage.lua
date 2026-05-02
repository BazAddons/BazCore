-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazCore CPU Page
--
-- Live snapshot of Baz Suite CPU consumption. Mirror of MemoryPage but
-- targeting per-addon CPU instead of memory:
--
--   * scriptProfile CVar gating - when off, the page renders a setup
--     card that one-clicks the CVar on + reloads. When on, the
--     normal blocks render: summary, per-addon bar list, time-series
--     graph, top-consumers list, recent events.
--
--   * Cumulative-from-API, gauge-on-screen. GetAddOnCPUUsage returns
--     ms-since-session-start. The shared sampler diffs each tick to
--     compute ms-per-second so the bars + graph display a current
--     RATE rather than a monotonically-rising total.
---------------------------------------------------------------------------

local O = BazCore._Options
if not O then return end

---------------------------------------------------------------------------
-- Tunables - mirror MemoryPage so the two surfaces feel identical.
---------------------------------------------------------------------------

local UPDATE_INTERVAL = 1.0    -- seconds between CPU polls
local HISTORY_LEN     = 120    -- 60 seconds of samples at 0.5 Hz
local SUMMARY_HEIGHT  = 78
local ROW_HEIGHT      = 26
local GRAPH_HEIGHT    = 170

---------------------------------------------------------------------------
-- Shared state
--
-- `current` and `currentTotal` are RATE values (ms-per-second) computed
-- from cumulative diffs. `cumulative` and `cumulativeTotal` are the raw
-- monotonic readings from GetAddOnCPUUsage, since session start.
---------------------------------------------------------------------------

local state = {
    current         = {},   -- [name] = ms/sec rate
    cumulative      = {},   -- [name] = total ms since session start
    peak            = {},   -- [name] = peak ms/sec rate this session
    currentTotal    = 0,    -- ms/sec across all tracked addons
    cumulativeTotal = 0,    -- total ms across all tracked addons
    peakTotal       = 0,
    history         = {},   -- ring buffer of total ms/sec samples
    historyHead     = 0,
    -- Internal: previous-tick cumulative readings, used to compute deltas
    prevCumulative  = {},
    prevTickTime    = 0,
    profilingOn     = false,
}
for i = 1, HISTORY_LEN do state.history[i] = 0 end

---------------------------------------------------------------------------
-- Tracked addons - same shape as MemoryPage so both pages cover the
-- same set of Baz addons in the same order.
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
    table.sort(list, function(a, b)
        if a == "BazCore" then return true end
        if b == "BazCore" then return false end
        return a < b
    end)
    return list
end

local function GetAddonDisplayName(name)
    local config = BazCore.addons and BazCore.addons[name]
    if config and config.title then return config.title end
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata(name, "Title") or name
    end
    return name
end

-- Format a CPU rate (ms/second). Below 1 ms/s, show µs for readability.
local function FormatRate(ms)
    if not ms then return "-" end
    if ms < 0.001 then return "0 µs/s" end
    if ms < 1     then return string.format("%.0f µs/s", ms * 1000) end
    if ms < 1000  then return string.format("%.2f ms/s", ms) end
    return string.format("%.0f ms/s", ms)
end

local function FormatTotalMs(ms)
    if not ms then return "-" end
    if ms < 1000  then return string.format("%.0f ms", ms)   end
    if ms < 60000 then return string.format("%.1f s",  ms / 1000) end
    return string.format("%.1f min", ms / 60000)
end

---------------------------------------------------------------------------
-- Sampler - shared across all blocks. Idle when nobody's watching.
---------------------------------------------------------------------------

local subscribers   = {}
local activeTicker
local cachedTracked

local function InvalidateTracked() cachedTracked = nil end

local function GetTrackedAddonsCached()
    if not cachedTracked then cachedTracked = GetTrackedAddons() end
    return cachedTracked
end

local function CollectSample()
    if UpdateAddOnCPUUsage then UpdateAddOnCPUUsage() end

    state.profilingOn = GetCVarBool and GetCVarBool("scriptProfile") or false

    local now = GetTime() or 0
    local interval = state.prevTickTime > 0
        and (now - state.prevTickTime)
        or UPDATE_INTERVAL
    if interval <= 0 then interval = UPDATE_INTERVAL end

    local rateTotal = 0
    local cumTotal  = 0
    for _, name in ipairs(GetTrackedAddonsCached()) do
        local cum = (GetAddOnCPUUsage and GetAddOnCPUUsage(name)) or 0
        state.cumulative[name] = cum
        cumTotal = cumTotal + cum

        local prev = state.prevCumulative[name] or cum
        local delta = cum - prev
        if delta < 0 then delta = 0 end  -- session reset / counter wrap
        state.prevCumulative[name] = cum

        local rate = delta / interval
        state.current[name] = rate
        rateTotal = rateTotal + rate

        if (state.peak[name] or 0) < rate then state.peak[name] = rate end
    end

    state.currentTotal    = rateTotal
    state.cumulativeTotal = cumTotal
    if state.peakTotal < rateTotal then state.peakTotal = rateTotal end
    state.prevTickTime = now

    state.historyHead = (state.historyHead % HISTORY_LEN) + 1
    state.history[state.historyHead] = rateTotal
end

local function Tick()
    local live = {}
    for _, sub in ipairs(subscribers) do
        if sub.frame and sub.frame:GetParent() then
            live[#live + 1] = sub
        end
    end
    subscribers = live

    if #subscribers == 0 then
        if activeTicker then
            activeTicker:Cancel()
            activeTicker = nil
        end
        return
    end

    CollectSample()
    for _, sub in ipairs(subscribers) do
        sub.refresh()
    end
end

local function StartTicker()
    if activeTicker then return end
    if not (C_Timer and C_Timer.NewTicker) then return end
    activeTicker = C_Timer.NewTicker(UPDATE_INTERVAL, Tick)
end

local function Subscribe(frame, refresh)
    InvalidateTracked()
    subscribers[#subscribers + 1] = { frame = frame, refresh = refresh }
    refresh()
    StartTicker()
end

CollectSample()

local function ResetPeaks()
    state.peakTotal = state.currentTotal
    for name, rate in pairs(state.current) do
        state.peak[name] = rate
    end
    Tick()
end

---------------------------------------------------------------------------
-- Public access for sibling modules (e.g. CPUMiniMonitor) that want to
-- ride the same sampler so the ticker stays cheap and cohesive.
---------------------------------------------------------------------------

function BazCore:SubscribeCPU(frame, refresh)
    Subscribe(frame, refresh)
end

function BazCore:GetCPUStateRef()
    return state
end

function BazCore:CPUGetTrackedAddons()
    return GetTrackedAddons()
end

function BazCore:CPUFormatRate(ms)
    return FormatRate(ms)
end

function BazCore:CPUGetAddonDisplayName(name)
    return GetAddonDisplayName(name)
end

---------------------------------------------------------------------------
-- Singleton widget cache - so navigating away and back re-uses frames
-- instead of leaking new ones every visit.
---------------------------------------------------------------------------

local singletons = {}

local function GetOrCreateSingleton(name, builder, parent, contentWidth)
    local s = singletons[name]
    if s and s.frame then
        s.frame:SetParent(parent)
        s.frame:Show()
        if s.frame.SetWidth and contentWidth then
            s.frame:SetWidth(contentWidth)
        end
        return s.frame, s.height
    end
    local frame, height = builder(parent, contentWidth)
    singletons[name] = { frame = frame, height = height }
    return frame, height
end

---------------------------------------------------------------------------
-- Block: cpuSetupCard
--
-- Renders only when scriptProfile CVar is off. One-button card that
-- enables the CVar + reloads. Rendered as a full-card prompt so the
-- user immediately sees why the rest of the page is showing zeroes.
---------------------------------------------------------------------------

local SETUP_HEIGHT = 130

local function BuildCPUSetupCard(parent, contentWidth)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(contentWidth, SETUP_HEIGHT)
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.10, 0.06, 0.04, 0.85)
    frame:SetBackdropBorderColor(1.00, 0.50, 0.20, 0.85)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText("CPU profiling is off")
    title:SetTextColor(1, 0.6, 0.3)

    local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    body:SetPoint("RIGHT", -16, 0)
    body:SetJustifyH("LEFT")
    body:SetWordWrap(true)
    body:SetText("WoW only tracks per-addon CPU usage when the |cffffd700scriptProfile|r CVar is set to 1. Click below to enable it - the UI reloads so the change takes effect, and CPU readings start populating immediately.")
    body:SetTextColor(0.85, 0.85, 0.85)

    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(220, 26)
    btn:SetPoint("BOTTOMLEFT", 16, 12)
    btn:SetText("Enable CPU profiling + /reload")
    btn:SetScript("OnClick", function()
        if BazCore.EnableCPUProfiling then
            BazCore:EnableCPUProfiling(true)
        end
    end)

    local note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("LEFT", btn, "RIGHT", 12, 0)
    note:SetText("Cheap to leave on. Disable any time via /bazcpu disable.")
    note:SetTextColor(0.6, 0.6, 0.6)

    -- The card auto-hides itself the moment scriptProfile gets enabled
    -- (the user might toggle it elsewhere), even though normally the
    -- enable button forces a reload.
    Subscribe(frame, function()
        if state.profilingOn then
            frame:Hide()
        else
            frame:Show()
        end
    end)

    return frame, SETUP_HEIGHT
end

---------------------------------------------------------------------------
-- Block: cpuSummary - big card at the top with current rate + peak.
---------------------------------------------------------------------------

local function BuildCPUSummary(parent, contentWidth)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(contentWidth, SUMMARY_HEIGHT)
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.06, 0.85)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.85)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("TOPLEFT", 16, -12)
    label:SetText("CPU RATE")
    label:SetTextColor(1, 0.82, 0)

    local sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)
    sub:SetText("Combined Baz Suite CPU per second")
    sub:SetTextColor(0.65, 0.65, 0.65)

    local totalVal = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
    totalVal:SetPoint("RIGHT", -20, 8)
    totalVal:SetText("...")
    totalVal:SetTextColor(0.4, 0.85, 1)

    local peakLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    peakLbl:SetPoint("TOPRIGHT", totalVal, "BOTTOMRIGHT", 0, -2)
    peakLbl:SetText("peak: ...")
    peakLbl:SetTextColor(0.7, 0.7, 0.7)

    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetPoint("BOTTOMLEFT", 16, 12)
    bar:SetPoint("BOTTOMRIGHT", -16, 12)
    bar:SetHeight(8)
    bar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
    bar:SetStatusBarColor(0.3, 0.7, 1, 0.85)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0, 0, 0, 0.4)

    Subscribe(frame, function()
        if not state.profilingOn then
            totalVal:SetText("|cff888888--|r")
            peakLbl:SetText("profiling off")
            bar:SetValue(0)
            return
        end
        totalVal:SetText(FormatRate(state.currentTotal))
        peakLbl:SetText("peak: " .. FormatRate(state.peakTotal))
        local pct = (state.peakTotal > 0) and (state.currentTotal / state.peakTotal) or 0
        bar:SetValue(pct)
    end)

    return frame, SUMMARY_HEIGHT
end

---------------------------------------------------------------------------
-- Block: cpuBarList - one row per tracked addon, current rate + share.
---------------------------------------------------------------------------

local LABEL_W   = 160
local PCT_W     = 56
local VALUE_W   = 100
local ROW_GAP_X = 8
local ROW_PAD   = 6

local function BuildCPUBarList(parent, contentWidth)
    local addons = GetTrackedAddons()
    local rowCount = #addons
    local height = rowCount * ROW_HEIGHT + math.max(0, rowCount - 1) * 2 + ROW_PAD * 2

    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(contentWidth, height)
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.06, 0.7)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.85)

    local rows = {}
    for i, name in ipairs(addons) do
        local row = CreateFrame("Frame", nil, frame)
        row:SetSize(contentWidth - 16, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, -ROW_PAD - (i - 1) * (ROW_HEIGHT + 2))

        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.label:SetPoint("LEFT", 6, 0)
        row.label:SetWidth(LABEL_W)
        row.label:SetJustifyH("LEFT")
        row.label:SetText(GetAddonDisplayName(name))
        if name == "BazCore" then
            row.label:SetTextColor(1, 0.82, 0)
        end

        local bar = CreateFrame("StatusBar", nil, row)
        bar:SetPoint("LEFT", row.label, "RIGHT", ROW_GAP_X, 0)
        bar:SetPoint("RIGHT", -PCT_W - VALUE_W - ROW_GAP_X * 2 - 6, 0)
        bar:SetHeight(12)
        bar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
        bar:SetStatusBarColor(0.3, 0.7, 1, 0.85)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        row.bar = bar

        local barBg = bar:CreateTexture(nil, "BACKGROUND")
        barBg:SetAllPoints()
        barBg:SetColorTexture(0, 0, 0, 0.4)

        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.value:SetPoint("LEFT", bar, "RIGHT", ROW_GAP_X, 0)
        row.value:SetWidth(VALUE_W)
        row.value:SetJustifyH("RIGHT")
        row.value:SetText("...")

        row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.pct:SetPoint("LEFT", row.value, "RIGHT", ROW_GAP_X, 0)
        row.pct:SetWidth(PCT_W)
        row.pct:SetJustifyH("RIGHT")
        row.pct:SetTextColor(0.65, 0.65, 0.65)
        row.pct:SetText("...")

        rows[name] = row
    end

    Subscribe(frame, function()
        local total = state.currentTotal
        local maxV = 0
        for _, name in ipairs(addons) do
            local v = state.current[name] or 0
            if v > maxV then maxV = v end
        end
        if maxV < 0.0001 then maxV = 0.0001 end

        for _, name in ipairs(addons) do
            local row = rows[name]
            local rate = state.current[name] or 0
            row.value:SetText(FormatRate(rate))
            row.bar:SetValue(rate / maxV)
            local pct = (total > 0) and (rate / total * 100) or 0
            row.pct:SetText(string.format("%.0f%%", pct))

            if pct >= 40 then
                row.bar:SetStatusBarColor(1.00, 0.50, 0.30, 0.85)
            elseif pct >= 20 then
                row.bar:SetStatusBarColor(1.00, 0.80, 0.30, 0.85)
            else
                row.bar:SetStatusBarColor(0.30, 0.70, 1.00, 0.85)
            end
        end
    end)

    return frame, height
end

---------------------------------------------------------------------------
-- Block: cpuGraph - rolling 60-second time-series of total ms/sec.
---------------------------------------------------------------------------

local function BuildCPUGraph(parent, contentWidth)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(contentWidth, GRAPH_HEIGHT)
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.06, 0.85)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.85)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 16, -10)
    title:SetText("Total CPU - last 60 seconds")
    title:SetTextColor(0.9, 0.9, 0.9)

    local maxLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    maxLbl:SetPoint("TOPRIGHT", -16, -10)
    maxLbl:SetTextColor(0.7, 0.7, 0.7)
    maxLbl:SetText("...")

    local oldestLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    oldestLbl:SetPoint("BOTTOMLEFT", 16, 8)
    oldestLbl:SetTextColor(0.45, 0.45, 0.45)
    oldestLbl:SetText("60s ago")

    local newestLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    newestLbl:SetPoint("BOTTOMRIGHT", -16, 8)
    newestLbl:SetTextColor(0.45, 0.45, 0.45)
    newestLbl:SetText("now")

    local plot = CreateFrame("Frame", nil, frame)
    plot:SetPoint("TOPLEFT", 16, -32)
    plot:SetPoint("BOTTOMRIGHT", -16, 22)

    for _, frac in ipairs({ 0.25, 0.5, 0.75 }) do
        local g = plot:CreateTexture(nil, "BACKGROUND")
        g:SetHeight(1)
        g:SetPoint("BOTTOMLEFT", 0, 0)
        g:SetPoint("BOTTOMRIGHT", 0, 0)
        g:SetColorTexture(1, 1, 1, 0.06)
        plot._grid = plot._grid or {}
        plot._grid[#plot._grid + 1] = { tex = g, frac = frac }
    end

    local bars = {}
    for i = 1, HISTORY_LEN do
        local bar = plot:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(0.3, 0.7, 1, 0.7)
        bar:SetHeight(0.001)
        bars[i] = bar
    end

    local laidOut = false
    local function LayoutGraph()
        local w = plot:GetWidth() or 0
        local h = plot:GetHeight() or 0
        if w < 1 or h < 1 then return end

        local barW = w / HISTORY_LEN
        for i = 1, HISTORY_LEN do
            bars[i]:ClearAllPoints()
            bars[i]:SetPoint("BOTTOMLEFT", (i - 1) * barW, 0)
            bars[i]:SetWidth(math.max(barW - 0.5, 0.5))
        end
        for _, g in ipairs(plot._grid or {}) do
            g.tex:ClearAllPoints()
            g.tex:SetPoint("BOTTOMLEFT", 0, h * g.frac)
            g.tex:SetPoint("BOTTOMRIGHT", 0, h * g.frac)
        end
        laidOut = true
    end
    plot:HookScript("OnSizeChanged", LayoutGraph)

    Subscribe(frame, function()
        if not laidOut then LayoutGraph() end
        local h = plot:GetHeight() or 0
        if h < 1 then return end

        local maxV = 0.0001
        for _, v in ipairs(state.history) do
            if v > maxV then maxV = v end
        end

        local head = state.historyHead
        for plotIdx = 1, HISTORY_LEN do
            local readIdx = ((head + plotIdx - 1) % HISTORY_LEN) + 1
            local v = state.history[readIdx] or 0
            local bh = (v / maxV) * h
            bars[plotIdx]:SetHeight(math.max(bh, 0.001))

            if plotIdx == HISTORY_LEN then
                bars[plotIdx]:SetColorTexture(1.00, 0.82, 0.30, 0.95)
            else
                bars[plotIdx]:SetColorTexture(0.30, 0.70, 1.00, 0.6)
            end
        end

        maxLbl:SetText(FormatRate(maxV))
    end)

    return frame, GRAPH_HEIGHT
end

---------------------------------------------------------------------------
-- Block: cpuTopList - top consumers from the persistent log.
---------------------------------------------------------------------------

local TOP_WINDOW_SEC = 3600
local MAX_TOP_ROWS   = 8
local TOP_ROW_H      = 22

local function BuildCPUTopList(parent, contentWidth)
    local headerH = 22
    local emptyH  = 22
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.06, 0.7)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.85)

    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    header:SetPoint("TOPLEFT", 16, -10)
    header:SetText("Top consumers (last hour)")
    header:SetTextColor(0.9, 0.9, 0.9)

    local windowLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    windowLbl:SetPoint("TOPRIGHT", -16, -10)
    windowLbl:SetTextColor(0.55, 0.55, 0.55)
    windowLbl:SetText("waiting for data...")

    local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", 16, -10 - headerH)
    empty:SetTextColor(0.6, 0.6, 0.6)
    empty:SetText("Waiting for at least 2 minutes of samples...")

    local rowPool = {}
    local function AcquireRow(i)
        local row = rowPool[i]
        if row then return row end
        row = CreateFrame("Frame", nil, frame)
        row:SetSize(contentWidth - 32, TOP_ROW_H)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("LEFT", 0, 0)
        row.name:SetWidth(160)
        row.name:SetJustifyH("LEFT")

        row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.total:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
        row.total:SetWidth(110)
        row.total:SetJustifyH("RIGHT")

        row.rate = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.rate:SetPoint("LEFT", row.total, "RIGHT", 8, 0)
        row.rate:SetWidth(120)
        row.rate:SetJustifyH("RIGHT")
        row.rate:SetTextColor(0.7, 0.7, 0.7)

        rowPool[i] = row
        return row
    end

    Subscribe(frame, function()
        if not BazCore.GetCPUTopConsumers then
            empty:SetText("CPU log not loaded yet.")
            empty:Show()
            for _, r in pairs(rowPool) do r:Hide() end
            frame:SetSize(contentWidth, headerH + emptyH + 16)
            return
        end

        local top, oldestT, latestT = BazCore:GetCPUTopConsumers(TOP_WINDOW_SEC)
        if not top or #top == 0 then
            empty:Show()
            for _, r in pairs(rowPool) do r:Hide() end
            windowLbl:SetText("waiting for data...")
            frame:SetSize(contentWidth, headerH + emptyH + 16)
            return
        end

        empty:Hide()
        if oldestT and latestT then
            local mins = math.max(1, math.floor((latestT - oldestT) / 60))
            windowLbl:SetText(string.format("over last %d min", mins))
        end

        local shown = math.min(MAX_TOP_ROWS, #top)
        local y = -10 - headerH
        for i = 1, shown do
            local g   = top[i]
            local row = AcquireRow(i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 16, y)
            row:Show()

            row.name:SetText(GetAddonDisplayName(g.name))
            row.total:SetText(FormatTotalMs(g.totalMs))

            -- Heat colour by the share of this addon's CPU vs the
            -- biggest consumer in the list - so even a low-CPU suite
            -- has a visible "hottest" highlight.
            local share = g.totalMs / math.max(top[1].totalMs, 0.0001)
            if share >= 0.6 then
                row.total:SetTextColor(1.00, 0.50, 0.30)
            elseif share >= 0.3 then
                row.total:SetTextColor(1.00, 0.85, 0.40)
            else
                row.total:SetTextColor(0.65, 0.65, 0.65)
            end

            row.rate:SetText(string.format("%.0f ms/h", g.ratePerHour))
            y = y - TOP_ROW_H
        end
        for i = shown + 1, #rowPool do rowPool[i]:Hide() end

        frame:SetSize(contentWidth, headerH + shown * TOP_ROW_H + 20)
    end)

    frame:SetSize(contentWidth, headerH + emptyH + 16)
    return frame, headerH + MAX_TOP_ROWS * TOP_ROW_H + 20
end

---------------------------------------------------------------------------
-- Block: cpuEventList - recent annotated events with CPU context.
---------------------------------------------------------------------------

local EVENT_ROW_H = 20
local MAX_EVENT_ROWS = 10

local EVENT_LABELS = {
    login        = "|cff8ce0ffLogin|r",
    reload       = "|cffffd700/reload|r",
    loading      = "|cffaaaaaaLoading|r",
    combat_start = "|cffff8c5cCombat start|r",
    combat_end   = "|cff90ee90Combat end|r",
    zone         = "|cffd0a8ffZone|r",
    mark         = "|cffffd700Mark|r",
}

local function BuildCPUEventList(parent, contentWidth)
    local headerH = 22
    local emptyH  = 22
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.06, 0.7)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.85)

    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    header:SetPoint("TOPLEFT", 16, -10)
    header:SetText("Recent events")
    header:SetTextColor(0.9, 0.9, 0.9)

    local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", 16, -10 - headerH)
    empty:SetTextColor(0.6, 0.6, 0.6)
    empty:SetText("No events recorded yet.")

    local rowPool = {}
    local function AcquireRow(i)
        local row = rowPool[i]
        if row then return row end
        row = CreateFrame("Frame", nil, frame)
        row:SetSize(contentWidth - 32, EVENT_ROW_H)

        row.tstr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.tstr:SetPoint("LEFT", 0, 0)
        row.tstr:SetWidth(70)
        row.tstr:SetJustifyH("LEFT")
        row.tstr:SetTextColor(0.55, 0.55, 0.55)

        row.type = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.type:SetPoint("LEFT", row.tstr, "RIGHT", 8, 0)
        row.type:SetWidth(140)
        row.type:SetJustifyH("LEFT")

        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", row.type, "RIGHT", 8, 0)
        row.label:SetWidth(220)
        row.label:SetJustifyH("LEFT")
        row.label:SetTextColor(0.75, 0.75, 0.75)
        row.label:SetWordWrap(false)

        row.cpu = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.cpu:SetPoint("RIGHT", 0, 0)
        row.cpu:SetJustifyH("RIGHT")
        row.cpu:SetTextColor(0.55, 0.55, 0.55)

        rowPool[i] = row
        return row
    end

    Subscribe(frame, function()
        if not BazCore.GetCPUEvents then
            empty:Show()
            for _, r in pairs(rowPool) do r:Hide() end
            frame:SetSize(contentWidth, headerH + emptyH + 16)
            return
        end

        local events = BazCore:GetCPUEvents()
        local hist   = BazCore.GetCPUHistory and BazCore:GetCPUHistory() or {}
        if #events == 0 then
            empty:Show()
            for _, r in pairs(rowPool) do r:Hide() end
            frame:SetSize(contentWidth, headerH + emptyH + 16)
            return
        end
        empty:Hide()

        -- Sample-time -> deltaTotal lookup so each event row can show
        -- "CPU at this moment" as the rate-equivalent (delta over the
        -- preceding sample window).
        local cpuAt = {}
        for _, s in ipairs(hist) do cpuAt[s.t] = s.deltaTotal or 0 end

        local count = math.min(MAX_EVENT_ROWS, #events)
        local y = -10 - headerH
        for i = 1, count do
            local e = events[#events - i + 1]
            local row = AcquireRow(i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 16, y)
            row:Show()

            row.tstr:SetText(date("%H:%M:%S", e.t))
            row.type:SetText(EVENT_LABELS[e.type] or e.type or "?")
            row.label:SetText(e.label or "")
            local d = e.sampleT and cpuAt[e.sampleT]
            row.cpu:SetText(d and FormatTotalMs(d) or "")
            y = y - EVENT_ROW_H
        end
        for i = count + 1, #rowPool do rowPool[i]:Hide() end

        frame:SetSize(contentWidth, headerH + count * EVENT_ROW_H + 20)
    end)

    frame:SetSize(contentWidth, headerH + emptyH + 16)
    return frame, headerH + MAX_EVENT_ROWS * EVENT_ROW_H + 20
end

---------------------------------------------------------------------------
-- Register block factories with the layout engine.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Block: cpuMiniToggle - Show/Hide the floating mini monitor.
---------------------------------------------------------------------------

local MINI_TOGGLE_HEIGHT = 50

local function BuildCPUMiniToggle(parent, contentWidth)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(contentWidth, MINI_TOGGLE_HEIGHT)
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.06, 0.7)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.85)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", 16, 4)
    label:SetText("Floating Mini Monitor")

    local note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("LEFT", 16, -10)
    note:SetText("Small draggable window with the live top consumers - keep visible while playing to spot in-game spikes.")
    note:SetTextColor(0.6, 0.6, 0.6)
    note:SetWidth(contentWidth - 180)
    note:SetWordWrap(true)
    note:SetJustifyH("LEFT")

    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(120, 26)
    btn:SetPoint("RIGHT", -16, 0)
    local function refreshLabel()
        btn:SetText(BazCore:IsCPUMiniMonitorShown() and "Hide" or "Show")
    end
    btn:SetScript("OnClick", function()
        BazCore:ToggleCPUMiniMonitor()
        refreshLabel()
    end)
    refreshLabel()

    return frame, MINI_TOGGLE_HEIGHT
end

O.widgetFactories.cpuMiniToggle = function(parent, opt, contentWidth)
    return GetOrCreateSingleton("cpuMiniToggle", BuildCPUMiniToggle, parent, contentWidth)
end

O.widgetFactories.cpuSetup = function(parent, opt, contentWidth)
    return GetOrCreateSingleton("cpuSetup", BuildCPUSetupCard, parent, contentWidth)
end
O.widgetFactories.cpuSummary = function(parent, opt, contentWidth)
    return GetOrCreateSingleton("cpuSummary", BuildCPUSummary, parent, contentWidth)
end
O.widgetFactories.cpuBarList = function(parent, opt, contentWidth)
    return GetOrCreateSingleton("cpuBarList", BuildCPUBarList, parent, contentWidth)
end
O.widgetFactories.cpuGraph = function(parent, opt, contentWidth)
    return GetOrCreateSingleton("cpuGraph", BuildCPUGraph, parent, contentWidth)
end
O.widgetFactories.cpuTopList = function(parent, opt, contentWidth)
    return GetOrCreateSingleton("cpuTopList", BuildCPUTopList, parent, contentWidth)
end
O.widgetFactories.cpuEventList = function(parent, opt, contentWidth)
    return GetOrCreateSingleton("cpuEventList", BuildCPUEventList, parent, contentWidth)
end

if O.RegisterFullWidthBlockType then
    O.RegisterFullWidthBlockType("cpuSetup")
    O.RegisterFullWidthBlockType("cpuSummary")
    O.RegisterFullWidthBlockType("cpuBarList")
    O.RegisterFullWidthBlockType("cpuGraph")
    O.RegisterFullWidthBlockType("cpuTopList")
    O.RegisterFullWidthBlockType("cpuEventList")
    O.RegisterFullWidthBlockType("cpuMiniToggle")
end

---------------------------------------------------------------------------
-- Page registration
---------------------------------------------------------------------------

local function GetCPUPage()
    -- Only emit the setup card when profiling is actually off. The
    -- LayoutEngine reserves vertical space based on each block's
    -- factory-reported height, so leaving the block in the args and
    -- having the factory hide its frame would still leak ~130px of
    -- empty space below the intro. Conditional emit keeps the layout
    -- tight when profiling is on - the most common state once the
    -- user has enabled it once.
    local profilingOn = GetCVarBool and GetCVarBool("scriptProfile") or false

    local args = {
        intro = {
            order = 1,
            type  = "lead",
            text  = "Live snapshot of Baz Suite CPU consumption. " ..
                    "The summary + graph below cover the last 60 " ..
                    "seconds in real time. The Top Consumers section " ..
                    "uses the persistent log (one sample per minute, " ..
                    "kept across /reload) to surface the addons " ..
                    "burning the most CPU over the longer window.",
        },
        summary = {
            order = 3,
            type  = "cpuSummary",
        },
        miniToggle = {
            order = 4,
            type  = "cpuMiniToggle",
        },
            perAddonHeader = {
                order = 10,
                type  = "h2",
                name  = "Per Addon",
            },
            barList = {
                order = 11,
                type  = "cpuBarList",
            },
            graphHeader = {
                order = 20,
                type  = "h2",
                name  = "Total Over Time",
            },
            graph = {
                order = 21,
                type  = "cpuGraph",
            },
            topHeader = {
                order = 30,
                type  = "h2",
                name  = "Top Consumers (persistent log)",
            },
            topLead = {
                order = 31,
                type  = "lead",
                text  = "Sampled once per minute and persisted across " ..
                        "/reload. Ranks addons by total CPU ms inside the " ..
                        "rolling window so spikes outside the live 60-second " ..
                        "view still show up here.",
            },
            topList = {
                order = 32,
                type  = "cpuTopList",
            },
            eventList = {
                order = 33,
                type  = "cpuEventList",
            },
            actionsHeader = {
                order = 40,
                type  = "h2",
                name  = "Actions",
            },
            resetPeaksButton = {
                order = 41,
                type  = "execute",
                name  = "Reset Peaks",
                desc  = "Resets the per-addon peak rates and the total peak to the current values.",
                width = "half",
                func  = ResetPeaks,
            },
            dumpButton = {
                order = 42,
                type  = "execute",
                name  = "Export Log",
                desc  = "Opens a popup with the full persistent CPU log (CSV) in a selectable text box. Click Select All, then Ctrl+C to copy. Slash equivalents: /bazcpu export (popup), /bazcpu dump (chat).",
                width = "half",
                func  = function()
                    if BazCore.OpenCPUDumpDialog then
                        BazCore:OpenCPUDumpDialog()
                    elseif BazCore.DumpCPULog then
                        BazCore:DumpCPULog()
                    end
                end,
            },
            resetLogButton = {
                order = 43,
                type  = "execute",
                name  = "Reset Log",
                desc  = "Wipes the persistent CPU log. Use this before reproducing a CPU issue so the log only captures the relevant timeframe.",
                width = "half",
                func  = function()
                    if BazCore.ResetCPULog then BazCore:ResetCPULog() end
                end,
            },
            disableButton = {
                order = 44,
                type  = "execute",
                name  = "Disable Profiling",
                desc  = "Sets the scriptProfile CVar back to 0 and reloads. Re-enable any time via the setup card or /bazcpu enable.",
                width = "half",
                confirm            = true,
                confirmTitle       = "Disable CPU profiling?",
                confirmText        = "Sets scriptProfile=0 and reloads. CPU readings stop populating until you turn it back on.",
                confirmStyle       = "destructive",
                confirmAcceptLabel = "Disable + /reload",
                func  = function()
                    if BazCore.DisableCPUProfiling then
                        BazCore:DisableCPUProfiling(true)
                    end
                end,
            },
    }

    -- Conditional setup card: only added to the args when profiling is
    -- off, so the LayoutEngine doesn't reserve any vertical space for
    -- it once the user has profiling enabled.
    if not profilingOn then
        args.setup = {
            order = 2,
            type  = "cpuSetup",
        }
    end

    return {
        name = "CPU",
        type = "group",
        args = args,
    }
end

local PAGE_KEY = "BazCore-CPU"
BazCore:RegisterOptionsTable(PAGE_KEY, GetCPUPage)
BazCore:AddToSettings(PAGE_KEY, "CPU Usage", "BazCore")
