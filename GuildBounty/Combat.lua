-- Guild Bounty: PvP death / kill detection for WoW: Forever.
--
-- Forever applies Midnight's addon restrictions: the combat log is not
-- available to addons and some unit data is returned as "secret" values that
-- can't be compared or stored. So:
--   * Deaths: on PLAYER_DEAD we read Blizzard's Death Recap
--     (C_DeathRecap.GetRecapEvents), whose sourceName is a normal string.
--   * Kills:  honorable-kill chat messages, plus a bounty target in your
--     target/focus dying while you are in combat. Several guildmates may
--     report the same kill; Data.lua merges reports that are close in time.
local _, GB = ...

local isSecret = issecretvalue or function() return false end
local function usable(v, kind) return type(v) == kind and not isSecret(v) end

local RECAP_RETRIES = 6           -- recap may not be filled the instant we die
local RECAP_INTERVAL = 0.5
local CREDIT_COOLDOWN = 20        -- don't report the same victim twice within this many seconds
local COMBAT_WINDOW = 10

local seenEnemies = {}            -- [fullName] = { class, level }  hostile players we've seen
local seenCount = 0
local lastCredit = {}             -- [victim] = GetTime()
local lastCombat = 0

---------------------------------------------------------------------------
-- Hostile player cache (lets us tell a player killer from an NPC in the recap)
---------------------------------------------------------------------------
local function noteUnit(unit)
    local ok = pcall(function()
        if not UnitExists(unit) then return end
        local isPlayer, isEnemy = UnitIsPlayer(unit), UnitIsEnemy("player", unit)
        if not usable(isPlayer, "boolean") or not usable(isEnemy, "boolean") then return end
        if not (isPlayer and isEnemy) then return end
        local name, realm = UnitName(unit)
        if not usable(name, "string") or name == "" then return end
        if realm ~= nil and not usable(realm, "string") then return end
        local full = (realm and realm ~= "") and (name .. "-" .. realm) or GB.FullName(name)
        local _, class = UnitClass(unit)
        local level = UnitLevel(unit)
        local e = seenEnemies[full]
        if not e then
            e = {}
            seenEnemies[full] = e
            seenCount = seenCount + 1
        end
        if usable(class, "string") then e.class = class end
        if usable(level, "number") then e.level = level end   -- -1 means "??"
        if seenCount > 1000 then wipe(seenEnemies); seenCount = 0 end
    end)
    return ok
end

local function enemyInfo(name)
    local e = name and seenEnemies[name]
    if e then return e.class, e.level end
end

local function myLevel()
    local l = UnitLevel("player")
    return usable(l, "number") and l or 0
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
StaticPopupDialogs["GUILDBOUNTY_ADD"] = {
    text = "%s has killed you %d |4time:times;.\n\nAdd them to the Guild Bounty Board?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data) GB.AddToBoard(data.killer, data.class) end,  -- data = { killer, class }
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- "Yes" on the popup: every one of our deaths to this player that isn't on the
-- board yet becomes its own board entry, with its original date and levels.
-- (If someone else added the target while the popup was open, deaths already
-- credited are skipped.)
function GB.AddToBoard(killer, class)
    if not GB.GuildName() then return GB.Print("You must be in a guild to use the bounty board.") end
    local wasOnBoard = GB.IsOnBoard(killer)
    local batch = {}
    for _, d in ipairs(GB.PersonalDeaths(killer)) do
        if not d.credited then
            batch[#batch + 1] = GB.CreateEvent("K", killer, 1, class,
                { ts = d.ts, tl = d.tl, ml = d.ml, noSend = true })
            d.credited = true
        end
    end
    if #batch == 0 then   -- no history kept (shouldn't happen): record one kill now
        batch[1] = GB.CreateEvent("K", killer, 1, class, { tl = select(2, enemyInfo(killer)), ml = myLevel(), noSend = true })
    end
    GB.BroadcastEvents(batch)
    GB.Print(string.format("%s %s on the Guild Bounty Board.",
        wasOnBoard and "Updated" or "Added", GB.ClassColored(killer, class)))
end

function GB.OnKilledBy(killer, class, level)
    local count, death = GB.RecordPersonalDeath(killer, class, level, myLevel())
    local colored = GB.ClassColored(killer, class)

    if not GB.GuildName() then
        return GB.Print(string.format("%s has killed you %d time(s).", colored, count))
    end

    if GB.IsOnBoard(killer) then
        GB.CreateEvent("K", killer, 1, class, { ts = death.ts, tl = death.tl, ml = death.ml })
        death.credited = true
        local t = GB.GetTarget(killer)
        GB.ShowAlert(string.format("Killed by bounty target %s!", colored),
            string.format("They have killed you %d time(s) and the guild %d time(s).", count, t.kills))
        GB.Print(string.format("You were killed by bounty target %s (killed you %d time(s), guild %d time(s)).",
            colored, count, t.kills))
    else
        GB.Print(string.format("%s has killed you %d time(s).", colored, count))
        StaticPopup_Show("GUILDBOUNTY_ADD", colored, count, { killer = killer, class = class })
    end
end

function GB.OnKilledPlayer(victim, class, level)
    if not victim or victim == GB.PlayerName() then return end
    local cClass, cLevel = enemyInfo(victim)
    class, level = class or cClass, level or cLevel
    if not (GB.GuildName() and GB.IsOnBoard(victim)) then return end
    local now = GetTime()
    if lastCredit[victim] and now - lastCredit[victim] < CREDIT_COOLDOWN then return end
    lastCredit[victim] = now
    GB.CreateEvent("B", victim, 1, class, { tl = level, ml = myLevel() })   -- alert + broadcast in ProcessEvent
end

---------------------------------------------------------------------------
-- Deaths: Death Recap
---------------------------------------------------------------------------
local function recapKiller()
    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then return nil, "noapi" end
    local ok, events = pcall(C_DeathRecap.GetRecapEvents)
    if not ok or type(events) ~= "table" or #events == 0 then return nil end

    local best, bestTime
    for i, ev in ipairs(events) do
        if type(ev) == "table" then
            local overkill = usable(ev.overkill, "number") and ev.overkill or -1
            if overkill >= 0 then best = ev; break end
            local t = usable(ev.timestamp, "number") and ev.timestamp or i
            if not bestTime or t >= bestTime then best, bestTime = ev, t end
        end
    end
    if not best or not usable(best.sourceName, "string") or best.sourceName == "" then return nil, "done" end
    return best, "done"
end

-- Decide whether the recap source was an enemy player; returns fullName, class, level.
local function asPlayer(ev)
    local name = GB.FullName(ev.sourceName)
    local guid = usable(ev.sourceGUID, "string") and ev.sourceGUID or nil
    if guid then
        if not guid:find("^Player%-") then return nil end          -- NPC, pet, object
        local class
        if GetPlayerInfoByGUID then
            local ok, _, englishClass = pcall(GetPlayerInfoByGUID, guid)
            if ok and usable(englishClass, "string") then class = englishClass end
        end
        local cClass, cLevel = enemyInfo(name)
        return name, class or cClass, cLevel
    end
    -- No GUID: accept only names we know belong to players.
    local cClass, cLevel = enemyInfo(name)
    if seenEnemies[name] then return name, cClass, cLevel end
    if GB.charDB.killers[name] then return name, GB.charDB.killers[name].class, nil end
    local t = GB.GetTarget(name)
    if t then return name, t.class, nil end
    if ev.sourceName:find("-", 1, true) then return name, nil, nil end  -- cross-realm => player
    return nil
end

local function onPlayerDead()
    local attempts = 0
    local function try()
        attempts = attempts + 1
        local ev, state = recapKiller()
        if ev then
            local killer, class, level = asPlayer(ev)
            if killer and killer ~= GB.PlayerName() then GB.OnKilledBy(killer, class, level) end
        elseif state ~= "noapi" and state ~= "done" and attempts < RECAP_RETRIES then
            C_Timer.After(RECAP_INTERVAL, try)
        end
    end
    C_Timer.After(RECAP_INTERVAL, try)
end

---------------------------------------------------------------------------
-- Kills
---------------------------------------------------------------------------
local honorPatterns
local function buildPatterns()
    honorPatterns = {}
    for _, fmt in ipairs({ COMBATLOG_HONORGAIN, COMBATLOG_HONORGAIN_NO_RANK, COMBATLOG_HONORGAIN_EXHAUSTION1 }) do
        if type(fmt) == "string" then
            local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
            p = p:gsub("%%s", "(.-)"):gsub("%%d", "%%d+")
            honorPatterns[#honorPatterns + 1] = "^" .. p .. "$"
        end
    end
end

local function onHonorGain(msg)
    if not usable(msg, "string") then return end
    if not honorPatterns then buildPatterns() end
    for _, pattern in ipairs(honorPatterns) do
        local victim = msg:match(pattern)
        if victim and victim ~= "" then
            local full = GB.FullName(victim)
            return GB.OnKilledPlayer(full)
        end
    end
end

-- A bounty target in your target/focus dies while you're fighting.
local deadState = {}
local function checkUnitDeath(unit)
    pcall(function()
        if not UnitExists(unit) then return end
        local name, realm = UnitName(unit)
        if not usable(name, "string") then return end
        if realm ~= nil and not usable(realm, "string") then return end
        local full = (realm and realm ~= "") and (name .. "-" .. realm) or GB.FullName(name)
        if not GB.IsOnBoard(full) then return end
        local dead = UnitIsDeadOrGhost(unit)
        if not usable(dead, "boolean") then return end
        local inCombat = UnitAffectingCombat("player")
        inCombat = usable(inCombat, "boolean") and inCombat
        if dead and not deadState[full] and (inCombat or GetTime() - lastCombat <= COMBAT_WINDOW) then
            local _, class = UnitClass(unit)
            local level = UnitLevel(unit)
            GB.OnKilledPlayer(full, usable(class, "string") and class or nil,
                usable(level, "number") and level or nil)
        end
        deadState[full] = dead
    end)
end

GB.OnInit(function()
    GB.On("PLAYER_DEAD", onPlayerDead)
    GB.On("CHAT_MSG_COMBAT_HONOR_GAIN", onHonorGain)

    GB.On("PLAYER_TARGET_CHANGED", function() noteUnit("target"); checkUnitDeath("target") end)
    GB.On("UPDATE_MOUSEOVER_UNIT", function() noteUnit("mouseover") end)
    GB.On("NAME_PLATE_UNIT_ADDED", function(unit) noteUnit(unit) end)
    GB.On("PLAYER_REGEN_DISABLED", function() lastCombat = GetTime() end)
    GB.On("PLAYER_REGEN_ENABLED", function() lastCombat = GetTime() end)
    GB.On("UNIT_HEALTH", function(unit)
        if unit == "target" or unit == "focus" then checkUnitDeath(unit) end
    end)
    GB.On("UNIT_FLAGS", function(unit)
        if unit == "target" or unit == "focus" then checkUnitDeath(unit) end
    end)

    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then
        C_Timer.After(10, function()
            GB.Print("Death Recap API not found on this client - deaths can't be detected automatically.")
        end)
    end
end)
