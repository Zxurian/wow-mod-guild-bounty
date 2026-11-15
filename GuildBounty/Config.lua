-- Guild Bounty: configuration window (right-click the minimap button).
local _, GB = ...

local config

StaticPopupDialogs["GUILDBOUNTY_RESET"] = {
    text = "Reset ALL Guild Bounty data?\n\nThis clears the bounty board for every guild and your personal " ..
           "kill history on this character. Guildmates' data is not affected, and your current guild's " ..
           "board will sync back from them unless you have left that guild.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() GB.ResetAllData() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

local function header(parent, text, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 24, y)
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.3)
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    line:SetWidth(math.max(10, 340 - fs:GetStringWidth()))
end

local function checkbox(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", x, y)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.refresh = function() cb:SetChecked(get()) end
    return cb
end

local function button(parent, label, width, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function slider(parent, label, x, y, minV, maxV, step, get, set)
    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetOrientation("HORIZONTAL")
    s:SetSize(180, 16)
    s:SetPoint("TOPLEFT", x, y)
    s:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    local fs = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", s, "RIGHT", 10, 0)
    s:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / step + 0.5) * step
        fs:SetText(string.format("%s: %.0f%%", label, v * 100))
        set(v)
    end)
    s.refresh = function()
        s:SetValue(get())
        fs:SetText(string.format("%s: %.0f%%", label, get() * 100))
    end
    return s
end

local function availableSounds()
    local list = {}
    for i, entry in ipairs(GB.SOUNDS) do
        if not SOUNDKIT or SOUNDKIT[entry.kit] then list[#list + 1] = i end
    end
    return list
end

local function create()
    local S = GB.db.settings
    local f = CreateFrame("Frame", "GuildBountyConfigFrame", UIParent, "BackdropTemplate")
    f:SetSize(400, 450)
    f:SetPoint("CENTER", 0, 40)
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
    tinsert(UISpecialFrames, "GuildBountyConfigFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Guild Bounty Options")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    -- Hide directly: the template default routes through HideUIPanel, which is
    -- blocked in combat lockdown. These frames are not secure, so Hide() is safe.
    close:SetScript("OnClick", function() f:Hide() end)

    local controls = {}
    local function add(c) controls[#controls + 1] = c; return c end

    -- Window placement ------------------------------------------------------
    header(f, "Window placement", -50)
    add(checkbox(f, "Lock bounty board position", 24, -70,
        function() return S.board.locked end,
        function(v) S.board.locked = v end))
    add(slider(f, "Board scale", 30, -106, 0.6, 1.5, 0.05,
        function() return S.board.scale end,
        function(v) S.board.scale = v; GB.ApplyBoardSettings() end))
    button(f, "Reset board position", 160, 24, -132, function()
        S.board.point = nil; GB.ApplyBoardSettings()
    end)
    local moveBtn
    moveBtn = button(f, "Move alert", 100, 192, -132, function()
        local moving = not GB.IsAlertMoving()
        GB.SetAlertMoving(moving)
        moveBtn:SetText(moving and "Done" or "Move alert")
    end)
    button(f, "Reset", 70, 296, -132, function() GB.ResetAlertPosition() end)
    add(checkbox(f, "Show alert banners", 24, -160,
        function() return S.alert.enabled end,
        function(v) S.alert.enabled = v end))
    add(checkbox(f, "Show minimap button", 24, -184,
        function() return not S.minimap.hide end,
        function(v) S.minimap.hide = not v; GB.UpdateMinimapButton() end))
    add(checkbox(f, "Show guild bounty messages in chat", 24, -208,
        function() return S.chat.enabled end,
        function(v) S.chat.enabled = v end))

    -- Sound ------------------------------------------------------------------
    header(f, "Sound", -244)
    add(checkbox(f, "Play a sound with alerts", 24, -264,
        function() return S.sound.enabled end,
        function(v) S.sound.enabled = v end))
    local soundBtn = button(f, "", 180, 30, -294, nil)
    local function soundLabel()
        local e = GB.SOUNDS[S.sound.choice] or GB.SOUNDS[1]
        soundBtn:SetText("Sound: " .. e.label)
    end
    soundBtn:SetScript("OnClick", function()
        local list = availableSounds()
        if #list == 0 then return end
        local idx = 1
        for i, v in ipairs(list) do if v == S.sound.choice then idx = i % #list + 1 end end
        S.sound.choice = list[idx]
        soundLabel()
        GB.PlaySound()
    end)
    add({ refresh = soundLabel })
    button(f, "Test alert", 100, 220, -294, function()
        local was = S.alert.enabled
        S.alert.enabled = true
        GB.ShowAlert("Test: You have slain bounty target |cffc41e3aExample|r!",
            "Guild kills: 12   Times slain by guild: 3")
        S.alert.enabled = was
    end)

    -- Data -------------------------------------------------------------------
    header(f, "Data", -334)
    button(f, "Sync now", 150, 24, -356, function() GB.RequestSync(true) end)
    local reset = button(f, "Reset all data", 150, 200, -356, function()
        StaticPopup_Show("GUILDBOUNTY_RESET")
    end)
    reset:GetFontString():SetTextColor(1, 0.3, 0.3)

    local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 24, -388)
    note:SetWidth(352)
    note:SetJustifyH("LEFT")
    note:SetText("Reset when changing guilds or to start fresh. Data is only shared with, " ..
        "and accepted from, members of your current guild.")

    f:SetScript("OnShow", function() for _, c in ipairs(controls) do c.refresh() end end)
    f:SetScript("OnHide", function()
        if GB.IsAlertMoving() then GB.SetAlertMoving(false); moveBtn:SetText("Move alert") end
    end)
    f:Hide()
    return f
end

function GB.ToggleConfig()
    config = config or create()
    config:SetShown(not config:IsShown())
end
