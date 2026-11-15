-- Guild Bounty: on-screen alert banner (movable from the config screen).
local _, GB = ...

local alert

local function savePosition(f)
    local point, _, relPoint, x, y = f:GetPoint()
    GB.db.settings.alert.point = { point, relPoint, x, y }
end

local function applyPosition(f)
    f:ClearAllPoints()
    local p = GB.db.settings.alert.point
    if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else f:SetPoint("TOP", UIParent, "TOP", 0, -160) end
end

local function create()
    local f = CreateFrame("Frame", "GuildBountyAlertFrame", UIParent, "BackdropTemplate")
    f:SetSize(520, 70)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition(self) end)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.15, 0, 0, 0.85)
    f:SetBackdropBorderColor(1, 0.2, 0.2, 1)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(44, 44)
    icon:SetPoint("LEFT", 12, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bone_HumanSkull_01")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
    f.title:SetWidth(440)
    f.title:SetJustifyH("LEFT")

    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
    f.sub:SetWidth(440)
    f.sub:SetJustifyH("LEFT")

    f:SetScript("OnUpdate", function(self, elapsed)
        if self.moving then return end
        self.remaining = (self.remaining or 0) - elapsed
        if self.remaining <= 0 then
            self:Hide()
        elseif self.remaining < 1 then
            self:SetAlpha(self.remaining)
        end
    end)

    applyPosition(f)
    f:EnableMouse(false)
    f:Hide()
    return f
end

function GB.ShowAlert(title, sub)
    local s = GB.db.settings.alert
    if not s.enabled then return end
    alert = alert or create()
    alert.title:SetText(title)
    alert.sub:SetText(sub or "")
    alert.remaining = s.duration or 5
    alert:SetAlpha(1)
    alert:Show()
    GB.PlaySound()
end

-- Shows a placeholder banner that can be dragged until locked again.
function GB.SetAlertMoving(moving)
    alert = alert or create()
    alert.moving = moving
    alert:EnableMouse(moving)
    if moving then
        alert.title:SetText("Guild Bounty alert")
        alert.sub:SetText("Drag me where you want alerts to appear.")
        alert:SetAlpha(1)
        alert:Show()
    else
        alert:Hide()
    end
end

function GB.IsAlertMoving()
    return alert and alert.moving or false
end

function GB.ResetAlertPosition()
    GB.db.settings.alert.point = nil
    if alert then applyPosition(alert) end
end
