-- Guild Bounty: data model.
--
-- The bounty board is derived from an append-only log of kill events shared
-- with the guild. Every event has a globally unique id, so receiving the same
-- event twice never double counts.
--
-- Event fields (saved):
--   id  "<m>.<suffix>" - the creator is always the guild member m; suffix is a
--       4-char random epoch per character install + base36 sequence number, so
--       wiping SavedVariables can never reuse an id
--   t   "K" = target killed guild member, "B" = guild member killed target
--   k   target (bounty) full name "Name-Realm"
--   m   guild member full name
--   cl  target class token ("" if unknown)
--   ts  server time of the kill
--   tl  target level at the time (0 unknown, -1 "??")
--   ml  member level at the time (0 unknown)
--
-- Everything else (board totals, kill log, sync digests) is an in-memory index
-- built once per session and then updated incrementally per event.
local _, GB = ...

local MOD = 2147483647
local DAY = 86400
local MONTH_DAYS = 32        -- sync "months" are fixed 32-day blocks
local MERGE_WINDOW = 20      -- seconds; kill reports closer than this are the same kill

---------------------------------------------------------------------------
-- Hashing / encoding helpers
---------------------------------------------------------------------------
function GB.Hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % MOD end
    return h
end

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
function GB.B36(n)
    n = math.floor(n)
    if n == 0 then return "0" end
    local neg = n < 0
    if neg then n = -n end
    local s = ""
    while n > 0 do
        local d = n % 36
        s = B36:sub(d + 1, d + 1) .. s
        n = (n - d) / 36
    end
    return neg and ("-" .. s) or s
end

function GB.DayOf(ts) return math.floor(ts / DAY) end
function GB.MonthOfDay(day) return math.floor(day / MONTH_DAYS) end

-- Short per-event fingerprint used when comparing a single day.
function GB.Fingerprint(id)
    return GB.B36(GB.Hash(id) % 60466176)   -- < 36^5: at most 5 chars
end

---------------------------------------------------------------------------
-- Store + index
---------------------------------------------------------------------------
-- index = {
--   guild,
--   root    = { n, h },
--   months  = { [month] = { n, h, days = { [day] = true } } },
--   days    = { [day] = { n, h, ids = { [id] = true } } },
--   board   = { [target] = targetRecord },
--   orphanB = { [target] = { events } }   -- B events whose target has no K yet
-- }
-- n = number of events, h = sum of event-id hashes (order independent, so it
-- can be updated incrementally).
local index

function GB.Store()
    local guild = GB.GuildName()
    if not guild then return nil end
    local s = GB.db.guilds[guild]
    if not s then
        s = { events = {} }
        GB.db.guilds[guild] = s
    end
    return s
end

local function newTarget(name, ts)
    return {
        name = name, kills = 0, deaths = 0, victims = {}, slayers = {},
        added = ts, lastKill = 0, lastDeath = 0,
        kLog = {}, bEvents = {}, log = {}, dirty = true,
    }
end

local function indexEvent(ev)
    local h = GB.Hash(ev.id)
    local day = GB.DayOf(ev.ts)
    local month = GB.MonthOfDay(day)

    index.root.n = index.root.n + 1
    index.root.h = (index.root.h + h) % MOD
    local m = index.months[month]
    if not m then m = { n = 0, h = 0, days = {} }; index.months[month] = m end
    m.n, m.h = m.n + 1, (m.h + h) % MOD
    m.days[day] = true
    local d = index.days[day]
    if not d then d = { n = 0, h = 0, ids = {} }; index.days[day] = d end
    d.n, d.h = d.n + 1, (d.h + h) % MOD
    d.ids[ev.id] = true

    local board = index.board
    if ev.t == "K" then
        local t = board[ev.k]
        if not t then
            t = newTarget(ev.k, ev.ts)
            board[ev.k] = t
            local orphans = index.orphanB[ev.k]
            if orphans then
                for _, b in ipairs(orphans) do t.bEvents[#t.bEvents + 1] = b end
                index.orphanB[ev.k] = nil
            end
        end
        if ev.cl ~= "" then t.class = ev.cl end
        t.kills = t.kills + 1
        t.victims[ev.m] = (t.victims[ev.m] or 0) + 1
        if ev.ts < t.added then t.added = ev.ts end
        if ev.ts > t.lastKill then t.lastKill = ev.ts end
        t.kLog[#t.kLog + 1] = { ts = ev.ts, kind = "K", tl = ev.tl, c = 1,
                                members = { { name = ev.m, level = ev.ml } } }
        t.dirty = true
    else
        local t = board[ev.k]
        if t then
            t.bEvents[#t.bEvents + 1] = ev
            t.dirty = true
        else
            local list = index.orphanB[ev.k] or {}
            index.orphanB[ev.k] = list
            list[#list + 1] = ev
        end
    end
end

local function validEvent(ev)
    return type(ev) == "table"
        and (ev.t == "K" or ev.t == "B")
        and type(ev.k) == "string" and ev.k:find("^[^%-]+%-[^%-]+$") ~= nil
        and type(ev.m) == "string" and ev.m:find("^[^%-]+%-[^%-]+$") ~= nil
        and type(ev.id) == "string" and ev.id:sub(1, #ev.m + 1) == ev.m .. "."
        and ev.id:find("^%w+$", #ev.m + 2) ~= nil
        and type(ev.ts) == "number" and ev.ts > 1e9 and ev.ts < GetServerTime() + DAY
        and type(ev.tl) == "number" and ev.tl >= -1 and ev.tl <= 1000
        and type(ev.ml) == "number" and ev.ml >= 0 and ev.ml <= 1000
        and type(ev.cl) == "string"
end

local function ensureIndex()
    local guild = GB.GuildName()
    if not guild then return nil end
    if index and index.guild == guild then return index end
    index = { guild = guild, root = { n = 0, h = 0 }, months = {}, days = {}, board = {}, orphanB = {} }
    local events = GB.Store().events
    for id, ev in pairs(events) do
        -- Drop anything malformed (e.g. saved by a pre-release build) so it
        -- can't make digests disagree with peers forever.
        if ev.id == id and validEvent(ev) then indexEvent(ev) else events[id] = nil end
    end
    return index
end

function GB.MarkDirty()            -- guild changed or data reset: rebuild lazily
    index = nil
end

-- Recomputes the parts of a target that depend on B-event clustering. Several
-- members can report the same kill (everyone in the group gets the honorable
-- kill), so reports within MERGE_WINDOW seconds are one death that credits
-- every reporting member. Only runs for targets that changed.
local function finalize(t)
    if not t.dirty then return t end
    t.dirty = false
    table.sort(t.bEvents, function(a, b)
        if a.ts ~= b.ts then return a.ts < b.ts end
        return a.id < b.id
    end)
    t.deaths, t.slayers, t.lastDeath = 0, {}, 0
    local log = {}
    for i = 1, #t.kLog do log[i] = t.kLog[i] end
    local clusterStart, credited, entry
    for _, ev in ipairs(t.bEvents) do
        if not clusterStart or ev.ts - clusterStart > MERGE_WINDOW then
            clusterStart, credited = ev.ts, {}
            t.deaths = t.deaths + 1
            entry = { ts = ev.ts, kind = "B", tl = ev.tl, c = 1, members = {} }
            log[#log + 1] = entry
        end
        if not credited[ev.m] then
            credited[ev.m] = true
            t.slayers[ev.m] = (t.slayers[ev.m] or 0) + 1
            entry.members[#entry.members + 1] = { name = ev.m, level = ev.ml }
        end
        if (entry.tl or 0) == 0 and ev.tl ~= 0 then entry.tl = ev.tl end
        if ev.ts > t.lastDeath then t.lastDeath = ev.ts end
        if not t.class and ev.cl ~= "" then t.class = ev.cl end
    end
    table.sort(log, function(a, b) return a.ts > b.ts end)
    t.log = log
    return t
end

---------------------------------------------------------------------------
-- Board queries
---------------------------------------------------------------------------
function GB.GetTarget(name)
    local idx = ensureIndex()
    local t = idx and name and idx.board[name]
    return t and finalize(t) or nil
end

function GB.IsOnBoard(name)
    local idx = ensureIndex()
    return (idx and name and idx.board[name]) ~= nil
end

function GB.GetTopTargets(n)
    local idx = ensureIndex()
    local list = {}
    if idx then for _, t in pairs(idx.board) do list[#list + 1] = finalize(t) end end
    table.sort(list, function(a, b)
        if a.kills ~= b.kills then return a.kills > b.kills end
        if a.deaths ~= b.deaths then return a.deaths < b.deaths end
        return a.name < b.name
    end)
    local total = #list
    if n then for i = #list, n + 1, -1 do list[i] = nil end end
    return list, total
end

---------------------------------------------------------------------------
-- Sync digests (see Comm.lua). All O(1) or O(items in one bucket).
---------------------------------------------------------------------------
function GB.RootDigest()
    local idx = ensureIndex()
    if not idx then return 0, 0 end
    return idx.root.n, idx.root.h
end

function GB.MonthDigests()          -- { [month] = { n, h } }
    local idx = ensureIndex()
    return idx and idx.months or {}
end

function GB.MonthDigest(month)
    local idx = ensureIndex()
    local m = idx and idx.months[month]
    return m and m.n or 0, m and m.h or 0
end

function GB.DayDigests(month)       -- { [day] = { n, h } }
    local idx = ensureIndex()
    local out = {}
    local m = idx and idx.months[month]
    if m then for day in pairs(m.days) do out[day] = idx.days[day] end end
    return out
end

function GB.DayDigest(day)
    local idx = ensureIndex()
    local d = idx and idx.days[day]
    return d and d.n or 0, d and d.h or 0
end

function GB.DayEvents(day)          -- events of one day, oldest first
    local idx = ensureIndex()
    local d = idx and idx.days[day]
    local list, store = {}, GB.Store()
    if d then for id in pairs(d.ids) do list[#list + 1] = store.events[id] end end
    table.sort(list, function(a, b) return a.ts < b.ts end)
    return list
end

---------------------------------------------------------------------------
-- Applying events
---------------------------------------------------------------------------

-- Adds an event to the current guild's log. Returns true if it was new.
function GB.ApplyEvent(ev)
    if not validEvent(ev) then return false end
    if not ensureIndex() then return false end
    local store = GB.Store()
    if store.events[ev.id] then return false end
    store.events[ev.id] = ev
    indexEvent(ev)
    return true
end

function GB.NewEventId()
    local c = GB.charDB
    if not c.epoch then c.epoch = GB.B36(math.random(46656, 1679615)) end   -- always 4 chars
    c.seq = (c.seq or 0) + 1
    return GB.PlayerName() .. "." .. c.epoch .. GB.B36(c.seq)
end

---------------------------------------------------------------------------
-- Personal history: every time a player killed this character
---------------------------------------------------------------------------
local MAX_PERSONAL = 200
function GB.RecordPersonalDeath(killer, class, killerLevel, myLevel)
    local k = GB.charDB.killers[killer]
    if not k then
        k = { count = 0, deaths = {} }
        GB.charDB.killers[killer] = k
    end
    local death = { ts = GetServerTime(), tl = killerLevel or 0, ml = myLevel or 0 }
    table.insert(k.deaths, death)
    if #k.deaths > MAX_PERSONAL then table.remove(k.deaths, 1) end
    k.count = k.count + 1
    k.last = death.ts
    if class then k.class = class end
    return k.count, death
end

function GB.PersonalDeaths(killer)
    local k = GB.charDB.killers[killer]
    return k and k.deaths or {}
end

function GB.PersonalKillCount(killer)
    local k = GB.charDB.killers[killer]
    return k and k.count or 0
end

-- Wipes everything this addon has stored on this account + character.
function GB.ResetAllData()
    wipe(GB.db.guilds)
    wipe(GB.charDB.killers)
    index = nil
    GB.RequestRefresh()
    GB.Print("All bounty data has been reset.")
end
