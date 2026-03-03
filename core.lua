--- RCPowerLoot/core.lua
-- Integrates with RCLootCouncil to add:
--   1. An RPL column on the voting frame (ilvl upgrade score).
--   2. A "Loot History" button on the voting frame.
--   3. A Loot History viewer frame (30 / 60 / 90 day filter, raid-only toggle).
--
-- Loot data is read directly from RCLootCouncil's own history database
-- (RCLootCouncilLootDB), so nothing extra needs to be tracked or synced.

local ADDON_NAME, ns = ...

-- ============================================================
-- Constants
-- ============================================================
local VERSION = "0.1.0"

-- ============================================================
-- Addon namespace table (shared with bis.lua / comms.lua)
-- ============================================================
local RPL = {}
ns.RPL = RPL
RPL.RC         = nil   -- RCLootCouncil addon reference (set on detection)
RPL.filterDays = 30    -- Active day-filter for the history frame

-- ============================================================
-- Helpers
-- ============================================================

--- Returns the date string for (today minus `days`) in "YYYY/MM/DD" format.
-- Dates stored by RC use this same format, so lexicographic comparison works.
local function CutoffDateStr(days)
    return date("%Y/%m/%d", time() - days * 86400)
end

--- Shorthand chat print with a gold [RPL] prefix.
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[RPL]|r " .. tostring(msg))
end

--- Returns a set-table of current raid member names (full and short form).
local function GetRaidMemberSet()
    local members = {}
    local n = GetNumGroupMembers()
    if n > 0 then
        for i = 1, n do
            local name = GetRaidRosterInfo(i)
            if name then
                members[name] = true
                local short = name:match("^([^%-]+)")
                if short then members[short] = true end
            end
        end
    end
    return members
end

-- ============================================================
-- History Data
-- ============================================================

--- Returns a flat, date-descending list of loot history entries.
-- Each entry: { player, itemLink, date, ilvl, class, response }
-- @param days     number   Max age in days (30 / 60 / 90)
-- @param raidOnly boolean  When true, restrict to current raid members
function RPL:GetFilteredHistory(days, raidOnly)
    if not (self.RC and self.RC.GetHistoryDB) then return {} end

    local lootDB      = self.RC:GetHistoryDB()
    local cutoff      = CutoffDateStr(days)
    local raidMembers = raidOnly and GetRaidMemberSet() or nil
    local results     = {}

    for playerName, entries in pairs(lootDB) do
        -- Skip non-table values (RC may store metadata keys at the top level)
        if type(entries) ~= "table" then
            -- continue
        else
            -- Raid filter
            local inRaid = true
            if raidMembers then
                local short = playerName:match("^([^%-]+)") or playerName
                inRaid = raidMembers[playerName] or raidMembers[short]
            end

            if inRaid then
                for _, entry in ipairs(entries) do
                    if entry.date and entry.date >= cutoff then
                        local _, _, _, ilvl = GetItemInfo(entry.lootWon or "")
                        results[#results + 1] = {
                            player   = playerName,
                            itemLink = entry.lootWon or "",
                            date     = entry.date,
                            ilvl     = ilvl or 0,
                            class    = entry.class,
                            response = entry.responseID,
                        }
                    end
                end
            end
        end
    end

    -- Sort newest → oldest (lexicographic on "YYYY/MM/DD" is correct)
    table.sort(results, function(a, b) return a.date > b.date end)
    return results
end

-- ============================================================
-- History Frame
-- ============================================================

-- Layout constants mirroring RC's ROW_HEIGHT = 20 design
local ROW_H     = 20
local POOL_SIZE = 22   -- Number of visible rows in the viewport
local FRAME_W   = 660
local FRAME_H   = 490

-- WoW class colours (fallback when RAID_CLASS_COLORS is unavailable)
local CLASS_COLOR = {
    WARRIOR     = {0.78, 0.61, 0.43},
    PALADIN     = {0.96, 0.55, 0.73},
    HUNTER      = {0.67, 0.83, 0.45},
    ROGUE       = {1.00, 0.96, 0.41},
    PRIEST      = {1.00, 1.00, 1.00},
    DEATHKNIGHT = {0.77, 0.12, 0.23},
    SHAMAN      = {0.00, 0.44, 0.87},
    MAGE        = {0.25, 0.78, 0.92},
    WARLOCK     = {0.53, 0.53, 0.93},
    MONK        = {0.00, 1.00, 0.59},
    DRUID       = {1.00, 0.49, 0.04},
    DEMONHUNTER = {0.64, 0.19, 0.79},
    EVOKER      = {0.20, 0.58, 0.50},
}

-- Column layout: { header, x-offset from viewport left edge, display width }
local COLUMNS = {
    { label = "Player", x =   0, w = 140 },
    { label = "Item",   x = 144, w = 256 },
    { label = "Date",   x = 404, w =  96 },
    { label = "iLvl",  x = 504, w =  50 },
    { label = "Reason", x = 558, w =  82 },
}

--- Sets the visual state of the day-filter buttons.
local function UpdateFilterBtnStates(btns, activeDays)
    for _, b in ipairs(btns) do
        if b.rplDays == activeDays then
            b:LockHighlight()
        else
            b:UnlockHighlight()
        end
    end
end

--- Writes entry data into a single pool row.
local function PopulateRow(row, entry)
    local shortName = entry.player:match("^([^%-]+)") or entry.player

    -- Player name coloured by class
    local cc = (entry.class and CLASS_COLOR[entry.class]) or
               (RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]) or nil
    if cc then
        local r = cc.r or cc[1] or 1
        local g = cc.g or cc[2] or 1
        local b = cc.b or cc[3] or 1
        row.playerCell:SetTextColor(r, g, b)
    else
        row.playerCell:SetTextColor(1, 1, 1)
    end
    row.playerCell:SetText(shortName)

    -- Item link (renders as a hyperlink)
    row.itemCell:SetText(entry.itemLink)
    row.itemLink = entry.itemLink

    -- Date: "YYYY/MM/DD" → "YYYY-MM-DD"
    row.dateCell:SetText(entry.date:gsub("/", "-"))

    -- iLvl: use cached value; a GET_ITEM_INFO_RECEIVED event refreshes later
    if entry.ilvl and entry.ilvl > 0 then
        row.ilvlCell:SetText(tostring(entry.ilvl))
    else
        row.ilvlCell:SetText("")
    end

    -- Response / reason
    row.reasonCell:SetText(entry.response or "")
    row.reasonCell:SetTextColor(0.7, 0.7, 0.7)
end

--- Repositions the row pool to cover the currently visible scroll window.
-- Virtual scrolling: only POOL_SIZE rows exist; they are relocated and
-- repopulated as the user scrolls, so arbitrarily large result sets work.
function RPL:UpdatePooledRows()
    local f = self.historyFrame
    if not (f and f.cachedEntries) then return end

    local entries   = f.cachedEntries
    local scrollVal = f.scrollFrame:GetVerticalScroll()
    local firstIdx  = math.floor(scrollVal / ROW_H)  -- 0-based index of top entry

    for poolIdx, row in ipairs(f.rows) do
        local entryIdx = firstIdx + poolIdx   -- 1-based entry index
        local entry    = entries[entryIdx]

        -- Move this pool row to its virtual position in the content area
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.content, "TOPLEFT",
                     0, -((firstIdx + poolIdx - 1) * ROW_H))

        if entry then
            PopulateRow(row, entry)
            row:Show()
        else
            row:Hide()
            row.itemLink = nil
        end
    end
end

--- Builds and caches the main Loot History frame (created once, reused).
function RPL:CreateHistoryFrame()
    if self.historyFrame then return self.historyFrame end

    -- ── Outer frame (dark backdrop matching RC's default skin) ───────────
    local f = CreateFrame("Frame", "RPLHistoryFrame", UIParent,
                          BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "RPLHistoryFrame")   -- ESC closes the frame

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile     = true, tileSize = 32, edgeSize = 26,
            insets   = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        f:SetBackdropColor(0, 0, 0, 0.92)
        f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end

    -- ── Title bar (centred, matching RC's title-frame appearance) ─────────
    local titleBar = CreateFrame("Frame", nil, f,
                                 BackdropTemplateMixin and "BackdropTemplate" or nil)
    titleBar:SetHeight(24)
    titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",   14, -10)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT",  -14, -10)
    if titleBar.SetBackdrop then
        titleBar:SetBackdrop({
            bgFile  = "Interface\\DialogFrame\\UI-DialogBox-Header",
            tile    = false, edgeSize = 0,
            insets  = { left = 0, right = 0, top = 0, bottom = 0 },
        })
    end

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("CENTER", titleBar, "CENTER")
    titleText:SetText("RPL – Loot History")
    titleText:SetTextColor(1, 1, 1)

    -- ── Close button ──────────────────────────────────────────────────────
    local closeBtn = CreateFrame("Button", "RPLHistoryFrameClose", f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- ── Filter buttons (30 / 60 / 90 days) ───────────────────────────────
    local FILTER_Y = -40

    local filterLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 18, FILTER_Y)
    filterLabel:SetText("Show last:")
    filterLabel:SetTextColor(0.9, 0.9, 0.9)

    local filterBtns = {}
    local function MakeFilterBtn(label, days, leftAnchor, xOff)
        local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        btn:SetSize(72, 22)
        btn:SetText(label)
        btn.rplDays = days
        btn:SetPoint("LEFT", leftAnchor, "RIGHT", xOff, 0)
        btn:SetScript("OnClick", function()
            RPL.filterDays = days
            UpdateFilterBtnStates(filterBtns, days)
            RPL:RefreshHistoryFrame()
        end)
        filterBtns[#filterBtns + 1] = btn
        return btn
    end

    local b30 = MakeFilterBtn("30 Days", 30, filterLabel, 6)
    local b60 = MakeFilterBtn("60 Days", 60, b30, 4)
    local b90 = MakeFilterBtn("90 Days", 90, b60, 4)
    f.filterBtns = filterBtns
    UpdateFilterBtnStates(filterBtns, RPL.filterDays)

    -- ── "Current Raid Only" checkbox ──────────────────────────────────────
    local cbRaid = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cbRaid:SetSize(22, 22)
    cbRaid:SetPoint("LEFT", b90, "RIGHT", 14, 0)
    cbRaid:SetChecked(true)
    local cbLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cbLabel:SetPoint("LEFT", cbRaid, "RIGHT", 2, 0)
    cbLabel:SetText("Current Raid Only")
    cbLabel:SetTextColor(0.9, 0.9, 0.9)
    cbRaid:SetScript("OnClick", function() RPL:RefreshHistoryFrame() end)
    f.cbRaid = cbRaid

    -- ── Column headers ────────────────────────────────────────────────────
    local HDR_Y   = FILTER_Y - 30
    local LEFT    = 18    -- left-edge padding inside the frame

    for _, col in ipairs(COLUMNS) do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT + col.x, HDR_Y)
        fs:SetWidth(col.w)
        fs:SetJustifyH("LEFT")
        fs:SetText(col.label)
        fs:SetTextColor(1, 0.82, 0)   -- RC gold
    end

    -- Divider line under the column headers
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.5, 0.5, 0.5, 0.5)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT",  f, "TOPLEFT",  14, HDR_Y - 15)
    divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, HDR_Y - 15)

    -- ── Scroll frame ──────────────────────────────────────────────────────
    local SCROLL_TOP = HDR_Y - 19

    local scrollFrame = CreateFrame("ScrollFrame", "RPLHistoryScrollFrame", f,
                                    "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     f, "TOPLEFT",   LEFT, SCROLL_TOP)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 36)
    f.scrollFrame = scrollFrame

    -- The scroll-child represents the total data height; rows are positioned
    -- inside it by UpdatePooledRows() based on scroll offset (virtual scroll).
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(FRAME_W - LEFT * 2 - 16)
    content:SetHeight(POOL_SIZE * ROW_H)    -- grows in RefreshHistoryFrame
    scrollFrame:SetScrollChild(content)
    f.content = content

    -- ── Row pool ─────────────────────────────────────────────────────────
    -- POOL_SIZE rows are created once; UpdatePooledRows() moves them as the
    -- user scrolls, making the display effectively unbounded in entry count.
    f.rows = {}
    for i = 1, POOL_SIZE do
        local row = CreateFrame("Button", nil, content)
        row:SetSize(FRAME_W - LEFT * 2 - 16, ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)

        -- Alternating background
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if i % 2 == 0 then
            bg:SetColorTexture(0.10, 0.10, 0.10, 0.45)
        else
            bg:SetColorTexture(0.04, 0.04, 0.04, 0.20)
        end

        -- Hover highlight (gold tint, matching RC's ST highlight)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.82, 0, 0.12)

        -- Player cell
        local playerCell = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        playerCell:SetPoint("LEFT", row, "LEFT", COLUMNS[1].x, 0)
        playerCell:SetWidth(COLUMNS[1].w)
        playerCell:SetJustifyH("LEFT")
        playerCell:SetWordWrap(false)
        row.playerCell = playerCell

        -- Item link cell
        local itemCell = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        itemCell:SetPoint("LEFT", row, "LEFT", COLUMNS[2].x, 0)
        itemCell:SetWidth(COLUMNS[2].w)
        itemCell:SetJustifyH("LEFT")
        itemCell:SetWordWrap(false)
        row.itemCell = itemCell

        -- Date cell
        local dateCell = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dateCell:SetPoint("LEFT", row, "LEFT", COLUMNS[3].x, 0)
        dateCell:SetWidth(COLUMNS[3].w)
        dateCell:SetJustifyH("LEFT")
        row.dateCell = dateCell

        -- iLvl cell
        local ilvlCell = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ilvlCell:SetPoint("LEFT", row, "LEFT", COLUMNS[4].x, 0)
        ilvlCell:SetWidth(COLUMNS[4].w)
        ilvlCell:SetJustifyH("RIGHT")
        row.ilvlCell = ilvlCell

        -- Reason / response cell
        local reasonCell = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        reasonCell:SetPoint("LEFT", row, "LEFT", COLUMNS[5].x, 0)
        reasonCell:SetWidth(COLUMNS[5].w)
        reasonCell:SetJustifyH("LEFT")
        reasonCell:SetWordWrap(false)
        row.reasonCell = reasonCell

        -- Full item tooltip on hover
        row:SetScript("OnEnter", function(self)
            if self.itemLink and self.itemLink ~= "" then
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetHyperlink(self.itemLink)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row:Hide()
        f.rows[i] = row
    end

    -- Hook the scroll bar so the pool updates when the user scrolls
    if scrollFrame.ScrollBar then
        scrollFrame.ScrollBar:HookScript("OnValueChanged", function()
            RPL:UpdatePooledRows()
        end)
    end

    -- ── Status line ───────────────────────────────────────────────────────
    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    statusText:SetTextColor(0.6, 0.6, 0.6)
    f.statusText = statusText

    self.historyFrame = f
    return f
end

--- Runs the full data query, caches results, and refreshes the visible rows.
function RPL:RefreshHistoryFrame()
    local f = self.historyFrame
    if not f then return end

    local raidOnly = f.cbRaid:GetChecked()
    local entries  = self:GetFilteredHistory(self.filterDays, raidOnly)

    -- Cache for use by UpdatePooledRows() and the item-cache event handler
    f.cachedEntries = entries

    -- Resize content so the scrollbar accurately represents total row count
    f.content:SetHeight(math.max(#entries * ROW_H, POOL_SIZE * ROW_H))

    -- Reset scroll to top before rendering
    f.scrollFrame:SetVerticalScroll(0)

    self:UpdatePooledRows()

    UpdateFilterBtnStates(f.filterBtns, self.filterDays)

    local raidStr = raidOnly and " · raid only" or ""
    f.statusText:SetText(
        string.format("%d entries · last %d days%s", #entries, self.filterDays, raidStr))
end

--- Opens (or refreshes) the Loot History frame.
function RPL:ShowHistoryFrame()
    local f = self:CreateHistoryFrame()
    f:Show()
    self:RefreshHistoryFrame()
end

--- Called by GET_ITEM_INFO_RECEIVED; updates ilvl cells for newly cached items.
function RPL:OnItemInfoReceived(itemID)
    local f = self.historyFrame
    if not (f and f:IsShown() and f.cachedEntries) then return end

    -- Update any matching entry in the cache, then refresh visible rows
    local changed = false
    for _, entry in ipairs(f.cachedEntries) do
        if entry.ilvl == 0 and entry.itemLink ~= "" then
            local _, _, _, ilvl = GetItemInfo(entry.itemLink)
            if ilvl and ilvl > 0 then
                entry.ilvl = ilvl
                changed = true
            end
        end
    end
    if changed then self:UpdatePooledRows() end
end

-- ============================================================
-- Voting Frame Integration
-- ============================================================

--- Adds the "Loot History" button to the RC voting frame on first show.
local function AddHistoryButton(votingFrame)
    if not votingFrame or votingFrame.rplHistoryBtn then return end

    -- Parent and anchor both on votingFrame for consistent positioning
    local btn = CreateFrame("Button", "RPLHistoryButton", votingFrame, "UIPanelButtonTemplate")
    btn:SetSize(100, 22)
    btn:SetText("Loot History")
    -- The native Close/Abort button sits at (TOPRIGHT, -10, -40);
    -- place ours 28 px below it.
    btn:SetPoint("TOPRIGHT", votingFrame, "TOPRIGHT", -10, -68)
    btn:SetScript("OnClick", function() RPL:ShowHistoryFrame() end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("RPL Loot History")
        GameTooltip:AddLine("View loot awarded to raid members", 1, 1, 1)
        GameTooltip:AddLine(
            string.format("Currently showing last %d days", RPL.filterDays),
            0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    votingFrame.rplHistoryBtn = btn
end

--- Injects the RPL upgrade-score column into the voting frame scroll table.
-- Must run after RCVotingFrame:OnInitialize() (creates scrollCols)
-- but before RCVotingFrame:OnEnable() (calls GetFrame → builds the ST).
local function InjectRPLColumn(RCVotingFrameModule)
    if RCVotingFrameModule._rplColInjected then return end

    -- Insert after column index 7 ("Diff") in RC's default layout
    tinsert(RCVotingFrameModule.scrollCols, 8, {
        name         = "RPL",
        colName      = "rpl",
        width        = 42,
        align        = "CENTER",
        sortnext     = 7,
        DoCellUpdate = function(rowFrame, cellFrame, data, cols, row, realrow, column, table, ...)
            if not (data and data[realrow]) then return end
            local diff = data[realrow].diff
            if not diff or diff == 0 then
                cellFrame.text:SetText("–")
                cellFrame.text:SetTextColor(0.45, 0.45, 0.45)
                return
            end
            cellFrame.text:SetText(tostring(diff))
            if diff >= 20 then
                cellFrame.text:SetTextColor(0.20, 1.00, 0.20)   -- bright green
            elseif diff >= 8 then
                cellFrame.text:SetTextColor(1.00, 0.80, 0.20)   -- gold
            elseif diff > 0 then
                cellFrame.text:SetTextColor(0.80, 0.80, 0.80)   -- light grey
            else
                cellFrame.text:SetTextColor(0.90, 0.30, 0.30)   -- red: side-grade / downgrade
            end
        end,
        OnEnter = function(rowFrame, cellFrame, ...)
            GameTooltip:SetOwner(cellFrame, "ANCHOR_RIGHT")
            GameTooltip:AddLine("RPL Score")
            GameTooltip:AddLine("Item-level upgrade over the player's equipped gear.", 1, 1, 1, true)
            GameTooltip:AddLine(
                "|cff44ff44High|r ≥20   |cffffcc00Mid|r 8-19   |cffccccccLow|r 1-7   |cffff4444Side-grade|r ≤0",
                nil, nil, nil, true)
            GameTooltip:Show()
        end,
        OnLeave = function() GameTooltip:Hide() end,
    })

    RCVotingFrameModule._rplColInjected = true
end

--- Hooks into the RCVotingFrame module after RCLootCouncil loads.
function RPL:HookVotingFrame()
    local ok, module = pcall(function()
        return self.RC:GetModule("RCVotingFrame")
    end)
    if not (ok and module) then
        Print("Warning: RCVotingFrame module not found.")
        return
    end

    -- ── RPL column ──────────────────────────────────────────────────────
    -- scrollCols is available after OnInitialize. The ST is built in
    -- OnEnable/GetFrame, which fires during PLAYER_LOGIN — after our
    -- ADDON_LOADED hook runs, so we can insert directly.
    if module.scrollCols then
        InjectRPLColumn(module)
    else
        -- Fallback: hook OnInitialize in case load order is unusual
        local origInit = module.OnInitialize
        module.OnInitialize = function(self, ...)
            if origInit then origInit(self, ...) end
            InjectRPLColumn(self)
        end
    end

    -- ── Loot History button ──────────────────────────────────────────────
    -- Hook Show() so the button is added the first time the frame appears.
    -- (module.frame is created lazily inside GetFrame → OnEnable)
    local origShow = module.Show
    module.Show = function(self, ...)
        origShow(self, ...)
        if self.frame then
            AddHistoryButton(self.frame)
        end
    end
end

-- ============================================================
-- Slash Commands
-- ============================================================

SLASH_RPLHISTORY1 = "/rplhistory"
SLASH_RPLHISTORY2 = "/rph"
SlashCmdList["RPLHISTORY"] = function()
    RPL:ShowHistoryFrame()
end

SLASH_RPL1 = "/rpl"
SlashCmdList["RPL"] = function(args)
    local cmd = args and args:match("^(%S+)") or ""
    cmd = cmd:lower()

    if cmd == "history" or cmd == "h" then
        RPL:ShowHistoryFrame()

    elseif cmd == "bis" then
        local rest = args:match("^%S+%s+(.+)$") or ""
        if ns.BIS then
            ns.BIS:HandleBisCommand(rest)
        else
            Print("BIS module not loaded.")
        end

    else
        Print("Commands:")
        Print("  /rpl history           – Open loot history viewer")
        Print("  /rpl bis <item link>   – Mark item as BIS for your spec")
        Print("  /rph                   – Shortcut: open history viewer")
    end
end

-- ============================================================
-- Event Handling
-- ============================================================

local eventFrame = CreateFrame("Frame", "RPLEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...

        if addonName == ADDON_NAME then
            Print(string.format("v%s loaded.", VERSION))
        end

        if addonName == "RCLootCouncil" then
            -- Get the RC addon object through AceAddon-3.0
            local rcOk, rc = pcall(function()
                return LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil")
            end)
            RPL.RC = (rcOk and rc) or _G["RCLootCouncil"]

            if RPL.RC then
                local ver = RPL.RC.version or RPL.RC.versionNum or "?"
                Print(string.format("RCLootCouncil v%s detected.", tostring(ver)))
                RPL:HookVotingFrame()
            else
                Print("RCLootCouncil not found after ADDON_LOADED – history unavailable.")
            end
        end

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Fire only when the history frame is open and items were uncached
        local itemID = ...
        RPL:OnItemInfoReceived(itemID)
    end
end)
