-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazCore CPU Mini Monitor
--
-- Small floating window that mirrors the live data in the full CPU page.
-- For diagnosing in-game spikes (e.g. "the game hitches when I fly
-- through a Voilight Marl") without taking up the entire screen with
-- the Settings panel.
--
-- Layout (compact):
--   ┌──────────────────────────────┐
--   │ CPU Monitor          12 ms/s│  title + total
--   │ BazNotificationCenter  9 ms/s│  top-N rows, colored by share
--   │ BazBars                2 ms/s│
--   │ BazCore              0.4 ms/s│
--   │ ...                          │
--   └──────────────────────────────┘
--
-- Drag the title bar to move; X in the corner to close. Position +
-- visibility persist via BazCoreDB.cpuMini so the monitor reopens at
-- the same spot after /reload.
--
-- Shows a friendly "profiling off" message when scriptProfile is 0 -
-- avoids the user staring at zeroes wondering why nothing's moving.
---------------------------------------------------------------------------

BazCore = BazCore or {}

local TOP_N        = 5
local FRAME_W      = 240
local TITLE_H      = 22
local ROW_H        = 16
local PADDING      = 6
local ROW_GAP      = 1

local mini

---------------------------------------------------------------------------
-- "All addons" sampler. The shared CPUPage sampler only tracks the Baz
-- Suite, so to spot a hitch caused by *any* loaded addon we run our own
-- delta computation over every loaded addon when the mini is in "all"
-- mode. Cheap: just one GetAddOnCPUUsage call per addon per tick, and
-- only when the mini is shown + in all mode.
---------------------------------------------------------------------------

local allModePrev = {}
local allModeCur  = {}
local allModeTotal = 0
local allModePeak  = {}
local allModeLastT = 0

local function ListAllAddons()
    local names = {}
    if not (C_AddOns and C_AddOns.GetNumAddOns) then return names end
    for i = 1, C_AddOns.GetNumAddOns() do
        local name, _, _, loadable = C_AddOns.GetAddOnInfo(i)
        local loaded = C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(i)
        if name and (loaded or loadable) then
            names[#names + 1] = name
        end
    end
    return names
end

local function SampleAllAddons()
    if UpdateAddOnCPUUsage then UpdateAddOnCPUUsage() end
    local now = GetTime() or 0
    local interval = (allModeLastT > 0 and now > allModeLastT)
        and (now - allModeLastT) or 1.0
    if interval <= 0 then interval = 1.0 end

    local total = 0
    for _, name in ipairs(ListAllAddons()) do
        local cum = (GetAddOnCPUUsage and GetAddOnCPUUsage(name)) or 0
        local prev = allModePrev[name] or cum
        local delta = cum - prev
        if delta < 0 then delta = 0 end
        allModePrev[name] = cum

        local rate = delta / interval
        allModeCur[name] = rate
        total = total + rate
        if (allModePeak[name] or 0) < rate then allModePeak[name] = rate end
    end
    allModeTotal = total
    allModeLastT = now
end

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

local function PersistRef()
    BazCoreDB = BazCoreDB or {}
    BazCoreDB.cpuMini = BazCoreDB.cpuMini or { shown = false }
    return BazCoreDB.cpuMini
end

local function SavePosition(frame)
    local point, _, relPoint, x, y = frame:GetPoint()
    local p = PersistRef()
    p.point    = point
    p.relPoint = relPoint
    p.x        = x
    p.y        = y
end

local function ApplyPosition(frame)
    local p = PersistRef()
    frame:ClearAllPoints()
    if p.point then
        frame:SetPoint(p.point, UIParent, p.relPoint or p.point,
            p.x or 0, p.y or 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    end
end

---------------------------------------------------------------------------
-- Mode - "baz" (Suite-only, uses the shared sampler) or "all" (every
-- loaded addon, uses the all-mode sampler above). Persisted in
-- BazCoreDB.cpuMini.mode so the choice survives /reload.
---------------------------------------------------------------------------

local function CurrentMode()
    return (PersistRef().mode == "all") and "all" or "baz"
end

local function SetMode(mode)
    PersistRef().mode = (mode == "all") and "all" or "baz"
end

---------------------------------------------------------------------------
-- Refresh - sorts the chosen addon list by current rate, paints the
-- top-N rows on whichever consumer's frame was passed in.
---------------------------------------------------------------------------

local sortBuf = {}

local function Refresh(frame)
    local state = BazCore:GetCPUStateRef()
    if not state then return end

    local profilingOn = state.profilingOn
    if not profilingOn then
        frame.total:SetText("|cff888888off|r")
        for i, row in ipairs(frame.rows) do
            row.name:SetText(i == 1 and "scriptProfile is off" or "")
            row.value:SetText("")
            row.name:SetTextColor(0.55, 0.55, 0.55)
        end
        if frame.modeBtn then
            frame.modeBtn:SetText(CurrentMode() == "all" and "All" or "Baz")
        end
        return
    end

    local mode = CurrentMode()
    local rates, total, addons

    if mode == "all" then
        SampleAllAddons()
        rates = allModeCur
        total = allModeTotal
        addons = ListAllAddons()
    else
        rates = state.current
        total = state.currentTotal
        addons = BazCore:CPUGetTrackedAddons()
    end

    frame.total:SetText(BazCore:CPUFormatRate(total))

    -- Reuse sortBuf to avoid GC churn on every tick.
    for i = 1, math.max(#sortBuf, #addons) do sortBuf[i] = nil end
    for i, name in ipairs(addons) do
        sortBuf[i] = { name = name, rate = rates[name] or 0 }
    end
    table.sort(sortBuf, function(a, b) return a.rate > b.rate end)

    for i = 1, TOP_N do
        local row = frame.rows[i]
        local entry = sortBuf[i]
        if entry and entry.rate > 0 then
            row.name:SetText(BazCore:CPUGetAddonDisplayName(entry.name))
            row.value:SetText(BazCore:CPUFormatRate(entry.rate))
            local pct = (total > 0) and (entry.rate / total * 100) or 0
            if pct >= 40 then
                row.name:SetTextColor(1.00, 0.50, 0.30)
                row.value:SetTextColor(1.00, 0.50, 0.30)
            elseif pct >= 20 then
                row.name:SetTextColor(1.00, 0.80, 0.30)
                row.value:SetTextColor(1.00, 0.80, 0.30)
            else
                row.name:SetTextColor(0.85, 0.85, 0.85)
                row.value:SetTextColor(0.85, 0.85, 0.85)
            end
        else
            row.name:SetText("")
            row.value:SetText("")
        end
    end

    if frame.modeBtn then
        frame.modeBtn:SetText(mode == "all" and "All" or "Baz")
    end
end

---------------------------------------------------------------------------
-- Shared content - rows + total label + mode toggle, built inside any
-- parent frame. Used by both the floating window and the widget so
-- they look identical and share the Refresh path.
---------------------------------------------------------------------------

local function BuildContent(host, opts)
    opts = opts or {}
    local titleH = opts.titleHeight or TITLE_H
    local rowOffsetX = opts.rowOffsetX or PADDING
    local insetTop = opts.insetTop or PADDING

    -- Title row: gold "CPU Monitor" label, mode toggle (Baz / All),
    -- and current total in cyan. Mode toggle is always present so the
    -- user can switch scope from either surface.
    local titleBar = CreateFrame("Frame", nil, host)
    titleBar:SetPoint("TOPLEFT",  rowOffsetX, -insetTop)
    titleBar:SetPoint("TOPRIGHT", -rowOffsetX, -insetTop)
    titleBar:SetHeight(titleH)
    host._titleBar = titleBar

    if opts.showHeading then
        host.heading = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        host.heading:SetPoint("LEFT", 2, 0)
        host.heading:SetText("CPU Monitor")
        host.heading:SetTextColor(1, 0.82, 0)
    end

    host.total = titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    host.total:SetPoint("RIGHT", opts.totalRightPad or -22, 0)
    host.total:SetTextColor(0.4, 0.85, 1)
    host.total:SetText("...")

    local mb = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
    mb:SetSize(46, 18)
    mb:SetPoint("RIGHT", host.total, "LEFT", -8, 0)
    mb:SetText(CurrentMode() == "all" and "All" or "Baz")
    mb:SetScript("OnClick", function()
        SetMode(CurrentMode() == "all" and "baz" or "all")
        Refresh(host)
    end)
    mb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("CPU Tracking Scope", 1, 0.82, 0)
        GameTooltip:AddLine("|cffffd700Baz|r - only the Baz Suite addons", 1, 1, 1, true)
        GameTooltip:AddLine("|cffffd700All|r - every loaded addon (great for diagnosing third-party hitches)", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    mb:SetScript("OnLeave", GameTooltip_Hide)
    host.modeBtn = mb

    host.rows = {}
    for i = 1, TOP_N do
        local row = CreateFrame("Frame", nil, host)
        row:SetPoint("TOPLEFT",  rowOffsetX,
            -(insetTop + titleH + (i - 1) * (ROW_H + ROW_GAP)))
        row:SetPoint("TOPRIGHT", -rowOffsetX, 0)
        row:SetHeight(ROW_H)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 2, 0)
        row.name:SetPoint("RIGHT", row, "RIGHT", -78, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)

        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.value:SetPoint("RIGHT", -2, 0)
        row.value:SetWidth(70)
        row.value:SetJustifyH("RIGHT")

        host.rows[i] = row
    end
end

local function ContentHeight()
    return TITLE_H + PADDING + TOP_N * (ROW_H + ROW_GAP) + PADDING
end

---------------------------------------------------------------------------
-- Floating window
---------------------------------------------------------------------------

local function Build()
    if mini then return mini end

    local f = CreateFrame("Frame", "BazCoreCPUMini", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, ContentHeight())
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 8,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.88)
    f:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.85)
    f:Hide()

    BuildContent(f, { showHeading = true })

    -- Drag from the title bar.
    local titleBar = f._titleBar
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function()
        f:StopMovingOrSizing()
        SavePosition(f)
    end)
    f:SetMovable(true)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() BazCore:HideCPUMiniMonitor() end)

    ApplyPosition(f)

    if BazCore.SubscribeCPU then
        BazCore:SubscribeCPU(f, function() Refresh(f) end)
    end

    mini = f
    return f
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function BazCore:ShowCPUMiniMonitor()
    Build()
    mini:Show()
    PersistRef().shown = true
end

function BazCore:HideCPUMiniMonitor()
    if mini then mini:Hide() end
    PersistRef().shown = false
end

function BazCore:ToggleCPUMiniMonitor()
    if mini and mini:IsShown() then
        self:HideCPUMiniMonitor()
    else
        self:ShowCPUMiniMonitor()
    end
end

function BazCore:IsCPUMiniMonitorShown()
    return mini and mini:IsShown() or false
end

---------------------------------------------------------------------------
-- Widget version - registers with LibBazWidget-1.0 so BazWidgetDrawers
-- (and any other widget host) can dock the CPU monitor as a regular
-- widget. Re-uses BuildContent so the widget looks identical to the
-- floating window minus the chrome the host supplies.
---------------------------------------------------------------------------

local widgetFrame

local function BuildWidget()
    if widgetFrame then return widgetFrame end
    local f = CreateFrame("Frame", "BazCoreCPUMonitorWidget", UIParent)
    f:SetSize(FRAME_W, ContentHeight())
    BuildContent(f, { showHeading = false })
    if BazCore.SubscribeCPU then
        BazCore:SubscribeCPU(f, function() Refresh(f) end)
    end
    widgetFrame = f
    return f
end

local function RegisterWidget()
    local LBW = LibStub and LibStub("LibBazWidget-1.0", true)
    if not LBW then return end

    BuildWidget()
    LBW:RegisterWidget({
        id           = "bazcore_cpumonitor",
        label        = "CPU Monitor",
        designWidth  = FRAME_W,
        designHeight = ContentHeight(),
        frame        = widgetFrame,
        GetDesiredHeight = function() return ContentHeight() end,
        GetStatusText    = function()
            local state = BazCore:GetCPUStateRef()
            if not state or not state.profilingOn then return "off" end
            local total = (CurrentMode() == "all")
                and allModeTotal
                or state.currentTotal
            return BazCore:CPUFormatRate(total)
        end,
    })
end

---------------------------------------------------------------------------
-- Login bootstrap
--
-- 1. Restore the floating window if it was open last session.
-- 2. Register with LibBazWidget so widget hosts (BazWidgetDrawers,
--    etc.) can pick the CPU monitor up.
---------------------------------------------------------------------------

local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("PLAYER_LOGIN")
bootstrap:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    RegisterWidget()
    if PersistRef().shown then
        BazCore:ShowCPUMiniMonitor()
    end
end)
