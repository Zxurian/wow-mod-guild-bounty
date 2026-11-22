-- Guild Bounty: core namespace, saved variables, helpers and event dispatch.
local ADDON_NAME, GB = ...
_G.GuildBounty = GB

GB.PREFIX = "GuildBounty"          -- addon message prefix (max 16 chars)
GB.VERSION = "1.0.2"
GB.TOP_N = 10

local DEFAULTS = {
    board   = { point = nil, scale = 1.0, locked = false },
    alert   = { point = nil, enabled = true, duration = 5 },
    sound   = { enabled = true, choice = 1 },
    minimap = { angle = 220, hide = false },
    chat    = { enabled = true },     -- chat-frame notices for guild bounty activity
}

-- Sounds offered in the config screen. Entries whose SOUNDKIT key is missing in
-- the running client are skipped automatically.
GB.SOUNDS = {
    { label = "Raid Warning", kit = "RAID_WARNING",          fallback = 8959 },
    { label = "Ready Check",  kit = "READY_CHECK",           fallback = 8960 },
    { label = "Alarm Clock",  kit = "ALARM_CLOCK_WARNING_3", fallback = 12889 },
    { label = "PvP Flag",     kit = "PVP_THROUGH_QUEUE",     fallback = 8458 },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function copyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            copyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function GB.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[Guild Bounty]|r " .. tostring(msg))
end

function GB.Notice(msg)
    if GB.db.settings.chat.enabled then GB.Print(msg) end
end

function GB.RealmName()
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName() or ""):gsub("[%s%-]", "")
end

-- Always returns "Name-Realm" so names from the combat log, roster and addon
-- messages all compare equal.
function GB.FullName(name)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. GB.RealmName()
end

-- Display-only: strips the realm suffix. Stored keys stay "Name-Realm".
function GB.ShortName(name)
    if not name then return "?" end
    return name:match("^([^%-]+)%-") or name
end

function GB.PlayerName()
    return GB.FullName(UnitName("player"))
end

function GB.ClassColored(name, class)
    local display = GB.ShortName(name)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color and color.colorStr then
        return "|c" .. color.colorStr .. display .. "|r"
    end
    return display
end

-- Guild name of the player, or nil when unguilded.
function GB.GuildName()
    if not IsInGuild() then return nil end
    local name = GetGuildInfo("player")
    return name
end

function GB.PlaySound()
    local s = GB.db.settings.sound
    if not s.enabled then return end
    local entry = GB.SOUNDS[s.choice] or GB.SOUNDS[1]
    local id = (SOUNDKIT and SOUNDKIT[entry.kit]) or entry.fallback
    PlaySound(id, "Master")
end

-- Coalesces UI redraws: a sync can apply hundreds of events per minute, but
-- the board is redrawn at most twice a second.
local refreshPending = false
function GB.RequestRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.5, function()
        refreshPending = false
        if GB.RefreshBoard then GB.RefreshBoard() end
    end)
end

---------------------------------------------------------------------------
-- Event dispatch
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
GB.eventFrame = frame
local handlers = {}

-- Registers a handler; returns false when the client does not know the event
-- (e.g. combat log access removed in a newer client).
function GB.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        local ok = pcall(frame.RegisterEvent, frame, event)
        if not ok then
            handlers[event] = nil
            return false
        end
    end
    table.insert(handlers[event], fn)
    return true
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then geterrorhandler()(err) end
    end
end)

GB.On("ADDON_LOADED", function(name)
    if name ~= ADDON_NAME then return end

    GuildBountyDB = GuildBountyDB or {}
    GuildBountyDB.settings = GuildBountyDB.settings or {}
    GuildBountyDB.guilds = GuildBountyDB.guilds or {}
    copyDefaults(DEFAULTS, GuildBountyDB.settings)
    GuildBountyCharDB = GuildBountyCharDB or {}
    GuildBountyCharDB.killers = GuildBountyCharDB.killers or {}

    GB.db = GuildBountyDB
    GB.charDB = GuildBountyCharDB

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(GB.PREFIX)
    end

    for _, init in ipairs(GB.initializers or {}) do init() end
end)

-- Modules call this to run code once saved variables are available.
function GB.OnInit(fn)
    GB.initializers = GB.initializers or {}
    table.insert(GB.initializers, fn)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_GUILDBOUNTY1 = "/gb"
SLASH_GUILDBOUNTY2 = "/bounty"
SlashCmdList.GUILDBOUNTY = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "config" or msg == "options" then
        GB.ToggleConfig()
    elseif msg == "sync" then
        GB.RequestSync(true)
    elseif msg == "minimap" then
        GB.db.settings.minimap.hide = not GB.db.settings.minimap.hide
        GB.UpdateMinimapButton()
    elseif msg == "help" then
        GB.Print("/gb - toggle the bounty board")
        GB.Print("/gb config - open configuration")
        GB.Print("/gb sync - request board data from guildmates")
        GB.Print("/gb minimap - show/hide the minimap button")
    else
        GB.ToggleBoard()
    end
end

function GuildBounty_OnAddonCompartmentClick(_, button)
    if button == "RightButton" then GB.ToggleConfig() else GB.ToggleBoard() end
end
