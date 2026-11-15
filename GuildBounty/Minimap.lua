-- Guild Bounty: minimap button. Left-click = board, right-click = options,
-- drag to move around the minimap.
local _, GB = ...

local button

local function updatePosition()
    local angle = math.rad(GB.db.settings.minimap.angle or 220)
    local radius = (Minimap:GetWidth() / 2) + 10
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function onDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    GB.db.settings.minimap.angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
    updatePosition()
end

local function create()
    local b = CreateFrame("Button", "GuildBountyMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bone_HumanSkull_01")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)

    b:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then GB.ToggleConfig() else GB.ToggleBoard() end
    end)
    b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDragUpdate) end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Guild Bounty")
        GameTooltip:AddLine("|cffffffffLeft-click|r to open the bounty board", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffRight-click|r for options", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffDrag|r to move this button", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

function GB.UpdateMinimapButton()
    button = button or create()
    updatePosition()
    button:SetShown(not GB.db.settings.minimap.hide)
end

GB.OnInit(function() GB.UpdateMinimapButton() end)
