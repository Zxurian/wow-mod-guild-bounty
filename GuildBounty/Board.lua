-- Guild Bounty: the bounty board window (Top 10 by kills of guild members).
local _, GB = ...

local board
local ROW_H = 22
local COLS = {
    { key = "rank",    label = "#",           width = 26,  justify = "CENTER" },
    { key = "name",    label = "Player",      width = 170, justify = "LEFT" },
    { key = "kills",   label = "Guild Kills", width = 80,  justify = "CENTER" },
    { key = "victims", label = "Victims",     width = 65,  justify = "CENTER" },
    { key = "deaths",  label = "Slain",       width = 60,  justify = "CENTER" },
}

local function sortedCounts(map)
    local list = {}
    for name, n in pairs(map) do list[#list + 1] = { name = name, n = n } end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    return list
end

local function countKeys(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
end

local function savePosition(f)
    local point, _, relPoint, x, y = f:GetPoint()
    GB.db.settings.board.point = { point, relPoint, x, y }
end

function GB.ApplyBoardSettings()
    if not board then return end
    local s = GB.db.settings.board
    board:SetScale(s.scale or 1)
    board:ClearAllPoints()
    if s.point then board:SetPoint(s.point[1], UIParent, s.point[2], s.point[3], s.point[4])
    else board:SetPoint("CENTER", UIParent, "CENTER", 0, 60) end
end

local function rowTooltip(row)
    local t = row.target
    if not t then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(GB.ClassColored(t.name, t.class))
    GameTooltip:AddLine(t.name, 0.6, 0.6, 0.6)
    GameTooltip:AddDoubleLine("On board since", date("%Y-%m-%d", t.added), 1, 0.82, 0, 1, 1, 1)
    local mine = GB.PersonalKillCount(t.name)
    if mine > 0 then GameTooltip:AddDoubleLine("Killed you", mine, 1, 0.82, 0, 1, 1, 1) end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("Guild members killed (%d)", t.kills), 1, 0.3, 0.3)
    for _, v in ipairs(sortedCounts(t.victims)) do
        GameTooltip:AddDoubleLine("  " .. GB.ShortName(v.name), v.n, 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    if t.deaths > 0 then
        GameTooltip:AddLine(string.format("Slain by guild members (%d)", t.deaths), 0.3, 1, 0.3)
        for _, v in ipairs(sortedCounts(t.slayers)) do
            GameTooltip:AddDoubleLine("  " .. GB.ShortName(v.name), v.n, 1, 1, 1, 1, 1, 1)
        end
    else
        GameTooltip:AddLine("Not yet slain by the guild.", 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Recent", 1, 0.82, 0)
    for i = 1, math.min(5, #t.log) do
        local when, text = GB.FormatLogEntry(t, t.log[i])
        GameTooltip:AddDoubleLine(text, when, 1, 1, 1, 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine("Click for full history", 0.4, 0.8, 1)
    GameTooltip:Show()
end

local function create()
    local f = CreateFrame("Frame", "GuildBountyBoardFrame", UIParent, "BackdropTemplate")
    f:SetSize(440, 112 + ROW_H * GB.TOP_N)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not GB.db.settings.board.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition(self) end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    tinsert(UISpecialFrames, "GuildBountyBoardFrame")   -- close with Escape

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Guild Bounty Board")

    f.guild = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.guild:SetPoint("TOP", title, "BOTTOM", 0, -4)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    -- Hide directly: the template default routes through HideUIPanel, which is
    -- blocked in combat lockdown. These frames are not secure, so Hide() is safe.
    close:SetScript("OnClick", function() f:Hide() end)

    local gear = CreateFrame("Button", nil, f)
    gear:SetSize(20, 20)
    gear:SetPoint("RIGHT", close, "LEFT", -2, 0)
    gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    gear:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    gear:SetScript("OnClick", function() GB.ToggleConfig() end)
    gear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Options"); GameTooltip:Show()
    end)
    gear:SetScript("OnLeave", GameTooltip_Hide)

    -- Column headers
    local x = 22
    for _, col in ipairs(COLS) do
        local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", x, -62)
        h:SetWidth(col.width)
        h:SetJustifyH(col.justify)
        h:SetText(col.label)
        x = x + col.width
    end
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.4)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 20, -76)
    line:SetPoint("TOPRIGHT", -20, -76)

    f.rows = {}
    for i = 1, GB.TOP_N do
        local row = CreateFrame("Button", nil, f)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 20, -80 - (i - 1) * ROW_H)
        row:SetWidth(400)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0.04)
        end
        row.cells = {}
        local cx = 2
        for _, col in ipairs(COLS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetPoint("LEFT", cx, 0)
            fs:SetWidth(col.width)
            fs:SetJustifyH(col.justify)
            fs:SetWordWrap(false)
            row.cells[col.key] = fs
            cx = cx + col.width
        end
        row:SetScript("OnEnter", rowTooltip)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:SetScript("OnClick", function(self) if self.target then GB.ShowHistory(self.target.name) end end)
        f.rows[i] = row
    end

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("CENTER", 0, -10)

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOM", 0, 20)

    f:SetScript("OnShow", function() GB.RefreshBoard() end)
    f:Hide()
    board = f
    GB.ApplyBoardSettings()
    return f
end

function GB.RefreshBoard()
    if GB.RefreshHistory then GB.RefreshHistory() end
    if not board or not board:IsShown() then return end
    local guild = GB.GuildName()
    board.guild:SetText(guild and ("<" .. guild .. ">") or "")

    local list, total = {}, 0
    if guild then list, total = GB.GetTopTargets(GB.TOP_N) end

    for i, row in ipairs(board.rows) do
        local t = list[i]
        row.target = t
        if t then
            row.cells.rank:SetText(i)
            row.cells.name:SetText(GB.ClassColored(t.name, t.class))
            row.cells.kills:SetText(t.kills)
            row.cells.victims:SetText(countKeys(t.victims))
            row.cells.deaths:SetText(t.deaths)
            row:Show()
        else
            row:Hide()
        end
    end

    if not guild then
        board.empty:SetText("Join a guild to use the bounty board.")
    elseif total == 0 then
        board.empty:SetText("No bounties yet. Stay safe out there.")
    else
        board.empty:SetText("")
    end
    board.footer:SetText(total > 0 and string.format("%d player(s) on the board  -  hover for details, click for history", total) or "")
end

function GB.ToggleBoard()
    board = board or create()
    board:SetShown(not board:IsShown())
end

---------------------------------------------------------------------------
-- History: every kill involving one bounty target, with date and levels
---------------------------------------------------------------------------
local function lvl(n)
    if not n or n == 0 then return "?" end
    if n < 0 then return "??" end
    return tostring(n)
end

-- Returns date string, description ("Zug (60) killed Bob (58)").
function GB.FormatLogEntry(t, e)
    local target = GB.ClassColored(t.name, t.class) .. " (" .. lvl(e.tl) .. ")"
    local names = {}
    for _, m in ipairs(e.members) do
        names[#names + 1] = GB.ShortName(m.name) .. " (" .. lvl(m.level) .. ")"
    end
    local members = table.concat(names, ", ")
    local when = date("%Y-%m-%d %H:%M", e.ts)
    if e.kind == "K" then
        return when, target .. " |cffff5555killed|r " .. members .. ((e.c or 1) > 1 and (" x" .. e.c) or "")
    end
    return when, members .. " |cff55ff55killed|r " .. target
end

local history
local LINE_H = 18

local function createHistory()
    local f = CreateFrame("Frame", "GuildBountyHistoryFrame", UIParent, "BackdropTemplate")
    f:SetSize(540, 400)
    f:SetPoint("CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    tinsert(UISpecialFrames, "GuildBountyHistoryFrame")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -18)
    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.summary:SetPoint("TOP", f.title, "BOTTOM", 0, -4)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    -- Hide directly: the template default routes through HideUIPanel, which is
    -- blocked in combat lockdown. These frames are not secure, so Hide() is safe.
    close:SetScript("OnClick", function() f:Hide() end)

    local hDate = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hDate:SetPoint("TOPLEFT", 24, -62)
    hDate:SetText("Date")
    local hWhat = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hWhat:SetPoint("TOPLEFT", 140, -62)
    hWhat:SetText("Who killed who (level)")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -78)
    scroll:SetPoint("BOTTOMRIGHT", -38, 20)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(480, 1)
    scroll:SetScrollChild(content)
    f.content, f.lines = content, {}

    f:Hide()
    return f
end

local function line(i)
    local l = history.lines[i]
    if not l then
        l = {}
        l.date = history.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        l.date:SetPoint("TOPLEFT", 4, -(i - 1) * LINE_H)
        l.date:SetWidth(112)
        l.date:SetJustifyH("LEFT")
        l.text = history.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l.text:SetPoint("TOPLEFT", 120, -(i - 1) * LINE_H)
        l.text:SetWidth(356)
        l.text:SetJustifyH("LEFT")
        l.text:SetWordWrap(false)
        history.lines[i] = l
    end
    return l
end

function GB.RefreshHistory()
    if not history or not history:IsShown() then return end
    local t = GB.GetTarget(history.targetName)
    local log = t and t.log or {}
    history.title:SetText("History: " .. (t and GB.ClassColored(t.name, t.class) or GB.ShortName(history.targetName)))
    history.summary:SetText(t and string.format("Killed guild members %d time(s)  -  slain by the guild %d time(s)",
        t.kills, t.deaths) or "Not on the board.")
    for i, e in ipairs(log) do
        local l = line(i)
        local when, text = GB.FormatLogEntry(t, e)
        l.date:SetText(when)
        l.text:SetText(text)
        l.date:Show(); l.text:Show()
    end
    for i = #log + 1, #history.lines do
        history.lines[i].date:Hide(); history.lines[i].text:Hide()
    end
    history.content:SetHeight(math.max(1, #log * LINE_H))
end

function GB.ShowHistory(name)
    history = history or createHistory()
    history.targetName = name
    history:Show()
    GB.RefreshHistory()
end
