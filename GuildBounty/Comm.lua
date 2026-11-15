-- Guild Bounty: guild communication + swarm sync.
--
-- Transport: hidden addon messages (C_ChatInfo.SendAddonMessage, distribution
-- "GUILD", prefix GB.PREFIX). Nothing is ever posted to guild chat. Messages
-- whose guild field differs from ours, or whose sender isn't in our guild
-- roster, are discarded.
--
-- Every client is an equal peer. The event log is compared top-down, so only
-- what actually differs is ever sent:
--
--   RT  root digest (event count + hash of everything)    1 message
--   MO  per-"month" digests (32-day blocks)                ~1 message / 3 years
--   DA  per-day digests inside one month                   ~1-2 messages
--   ID  5-char fingerprints of every event in one day      ~1 message / 40 events
--   SY  the events themselves                               ~4-5 events / message
--
-- Rules (each peer applies them to every digest it hears):
--   * Same digest as mine         -> nothing to do; and if I was about to
--                                    announce that same digest, don't.
--   * Child bucket differs        -> describe my version of that child.
--   * Child bucket they lack      -> push it whole.
--   * Day fingerprints differ     -> push my events whose fingerprint they lack.
--   * After comparing, also describe my own version of the bucket, so they can
--     push what only *they* have.
--   Descriptions that a peer with an identical bucket already broadcast are
--   skipped, so in-sync peers stay silent.
--
-- Pushes are claimed: before pushing, a peer broadcasts a tiny CL message and
-- every other peer drops its pending push of the same thing. The order in which
-- peers try is a hash of (peer, bucket), so different buckets are claimed by
-- different peers and the work - and each client's separate send budget - is
-- spread across everyone online. Peers with a long send queue back off.
local _, GB = ...

local MAX_LEN = 250
local SUPPRESS = 30          -- seconds a heard digest / claim stays relevant
local PERIODIC = 600         -- background root digest interval
local BUSY = 10              -- bulk messages queued before we let others claim first

local roster, rosterLoaded = {}, false
local heard = {}             -- [eventId] = GetTime() it last went over the wire
local heardDesc = {}         -- ["CMD:key:n:h"] = GetTime() somebody broadcast that digest
local claimed = {}           -- [claimKey] = GetTime()
local descTimers = {}        -- ["CMD:key"] = timer
local pushTimers = {}        -- [claimKey] = timer
local partial = {}           -- [sender .. "CMD:key"] = { rnd, items = {} }
local announcedGuild

local B36 = function(n) return GB.B36(n) end
local function fromB36(s) return s and tonumber(s, 36) end

---------------------------------------------------------------------------
-- Compact record encoding
---------------------------------------------------------------------------
-- t,k,m,idSuffix,ts36,tl,ml,classCode - names drop "-Realm" when it is the
-- sender's realm (the receiver re-adds the sender's realm).
local CLASS_CODES = {
    WARRIOR = "a", PALADIN = "b", HUNTER = "c", ROGUE = "d", PRIEST = "e",
    DEATHKNIGHT = "f", SHAMAN = "g", MAGE = "h", WARLOCK = "i", MONK = "j",
    DRUID = "k", DEMONHUNTER = "l", EVOKER = "m",
}
local CLASS_FROM_CODE = {}
for token, code in pairs(CLASS_CODES) do CLASS_FROM_CODE[code] = token end

local function realmOf(full) return full and full:match("%-(.+)$") end

local function shrink(name, realm)
    local short, r = name:match("^(.-)%-(.+)$")
    if r == realm then return short end
    return name
end

local function expand(name, realm)
    if name:find("-", 1, true) then return name end
    return name .. "-" .. realm
end

local function encode(ev, realm)
    return table.concat({
        ev.t, shrink(ev.k, realm), shrink(ev.m, realm), ev.id:sub(#ev.m + 2),
        B36(ev.ts), tostring(ev.tl or 0), tostring(ev.ml or 0), CLASS_CODES[ev.cl] or "",
    }, ",")
end

local function decode(rec, realm)
    local t, k, m, suffix, ts, tl, ml, cc = strsplit(",", rec)
    if not cc or not realm then return nil end
    k, m = expand(k, realm), expand(m, realm)
    return {
        id = m .. "." .. suffix, t = t, k = k, m = m, ts = fromB36(ts),
        tl = tonumber(tl) or 0, ml = tonumber(ml) or 0, cl = CLASS_FROM_CODE[cc] or "",
    }
end
GB._encode, GB._decode = encode, decode

-- Splits items into message bodies that fit after a header of headerLen bytes.
local function chunk(items, headerLen)
    local chunks, cur, len = {}, {}, headerLen
    for _, item in ipairs(items) do
        if #cur > 0 and len + 1 + #item > MAX_LEN then
            chunks[#chunks + 1] = cur
            cur, len = {}, headerLen
        end
        cur[#cur + 1] = item
        len = len + 1 + #item
    end
    if #cur > 0 then chunks[#chunks + 1] = cur end
    return chunks
end

---------------------------------------------------------------------------
-- Send queue: two lanes (small control messages jump ahead of bulk event
-- pushes), one shared rate limit, retry with back-off when throttled/blocked.
---------------------------------------------------------------------------
local control, bulk = {}, {}
local tokens, MAX_TOKENS, REFILL = 8, 8, 1.0
local lastRefill = 0

local function trySend(text)
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, GB.PREFIX, text, "GUILD")
    if not ok then return false end
    if res == nil or res == true or res == 0 then return true end
    local R = Enum and Enum.SendAddonMessageResult
    return R ~= nil and res == R.Success
end

local function pump()
    local now = GetTime()
    if now - lastRefill >= REFILL then
        tokens = math.min(MAX_TOKENS, tokens + math.floor((now - lastRefill) / REFILL))
        lastRefill = now
    end
    while tokens > 0 do
        local lane = (#control > 0) and control or bulk
        local item = lane[1]
        if not item or (item.retryAt and now < item.retryAt) then break end
        if trySend(item.text) then
            table.remove(lane, 1)
            tokens = tokens - 1
        else
            item.tries = (item.tries or 0) + 1
            item.retryAt = now + (item.tries < 5 and 1 or 5)
            if item.tries > 40 then table.remove(lane, 1) end
            break
        end
    end
end

local function sendControl(text) control[#control + 1] = { text = text } end
local function sendBulk(text) bulk[#bulk + 1] = { text = text } end

local function sendEvents(cmd, events, lane)
    local guild = GB.GuildName()
    if not guild or #events == 0 then return end
    local send = lane or sendBulk
    local realm = GB.RealmName()
    local header = cmd .. "^" .. guild
    local now, recs = GetTime(), {}
    for i, ev in ipairs(events) do
        recs[i] = encode(ev, realm)
        heard[ev.id] = now
    end
    for _, group in ipairs(chunk(recs, #header)) do
        send(header .. "~" .. table.concat(group, "~"))
    end
end

-- Sends a digest list in numbered parts: CMD^guild[^key]^rnd^i^n^N^H~items
local function sendList(cmd, keyStr, N, H, items)
    local guild = GB.GuildName()
    if not guild then return end
    local rnd = B36(math.random(1, 1679615))
    local prefix = cmd .. "^" .. guild .. (cmd ~= "MO" and ("^" .. keyStr) or "") .. "^" .. rnd
    local tail = "^" .. B36(N) .. "^" .. B36(H)
    local chunks = chunk(items, #prefix + #tail + 6)
    if #chunks == 0 then chunks = { {} } end
    for i, group in ipairs(chunks) do
        local msg = prefix .. "^" .. i .. "^" .. #chunks .. tail
        if #group > 0 then msg = msg .. "~" .. table.concat(group, "~") end
        sendControl(msg)
    end
    heardDesc[cmd .. ":" .. keyStr .. ":" .. N .. ":" .. H] = GetTime()
end

---------------------------------------------------------------------------
-- Roster (who counts as "same guild")
---------------------------------------------------------------------------
local function refreshRoster()
    local n = GetNumGuildMembers()
    if not n or n == 0 then return end
    wipe(roster)
    for i = 1, n do
        local name = GetGuildRosterInfo(i)
        if name then roster[GB.FullName(name)] = true end
    end
    rosterLoaded = true
end

function GB.IsGuildMember(name)
    return roster[GB.FullName(name)] == true
end

---------------------------------------------------------------------------
-- Event processing (local and remote)
---------------------------------------------------------------------------
-- mode: "local" (we created it), "live" (guildmate's broadcast), "sync" (quiet)
-- quietNotice: skip the chat notice (2nd+ record about one target in a message)
function GB.ProcessEvent(ev, mode, noSend, quietNotice)
    if mode == "sync" then                        -- bulk path: no notices, no lookups
        if not GB.ApplyEvent(ev) then return false end
        GB.RequestRefresh()
        return true
    end
    local before = GB.GetTarget(ev.k)
    local wasOnBoard = before ~= nil
    local deathsBefore = before and before.deaths or 0
    if not GB.ApplyEvent(ev) then return false end

    if mode == "local" and not noSend then sendEvents("EV", { ev }, sendControl) end

    if mode ~= "sync" then
        local target = GB.GetTarget(ev.k)
        local tName = GB.ClassColored(ev.k, target and target.class or ev.cl)
        local mName = GB.ShortName(ev.m)
        if ev.t == "K" and mode == "live" and target and not quietNotice then
            if wasOnBoard then
                GB.Notice(string.format("%s was killed by bounty target %s (%d guild kills).",
                    mName, tName, target.kills))
            else
                GB.Notice(string.format("%s added %s to the Guild Bounty Board.", mName, tName))
            end
        elseif ev.t == "B" and target and target.deaths > deathsBefore then
            -- Only the first report of a kill raises the alert.
            local text = mode == "local"
                and string.format("You have slain bounty target %s!", tName)
                or string.format("%s has slain bounty target %s!", mName, tName)
            GB.ShowAlert(text, string.format("Guild kills: %d   Times slain by guild: %d",
                target.kills, target.deaths))
            GB.Notice(text)
        end
    end

    GB.RequestRefresh()
    return true
end

-- opts: ts (when it happened), tl (target level), ml (our level),
--       noSend (caller broadcasts a batch itself with GB.BroadcastEvents)
function GB.CreateEvent(t, target, _, class, opts)
    opts = opts or {}
    local ev = {
        id = GB.NewEventId(), t = t, k = target, m = GB.PlayerName(),
        cl = class or "", ts = opts.ts or GetServerTime(),
        tl = opts.tl or 0, ml = opts.ml or 0,
    }
    GB.ProcessEvent(ev, "local", opts.noSend)
    return ev
end

function GB.BroadcastEvents(list)
    sendEvents("EV", list, sendControl)
end

---------------------------------------------------------------------------
-- Swarm sync
---------------------------------------------------------------------------
-- Deterministic per-(peer, key) value in [0, 1): decides who goes first.
local function rank(key)
    return (GB.Hash(GB.PlayerName() .. "|" .. key) % 1000) / 1000
end

local function recentlyHeard(tbl, key, window)
    local t = tbl[key]
    return t ~= nil and GetTime() - t < (window or SUPPRESS)
end

-- My digest of a bucket: "MO" = whole log, "DA" = one month, "ID" = one day.
local function myDigest(cmd, key)
    if cmd == "MO" then return GB.RootDigest() end
    if cmd == "DA" then return GB.MonthDigest(key) end
    return GB.DayDigest(key)
end

local function describeNow(cmd, key)
    local N, H = myDigest(cmd, key)
    if cmd ~= "MO" and N == 0 then return end
    local keyStr = key and B36(key) or ""
    if recentlyHeard(heardDesc, cmd .. ":" .. keyStr .. ":" .. N .. ":" .. H) then return end
    local items = {}
    if cmd == "MO" then
        for month, d in pairs(GB.MonthDigests()) do
            items[#items + 1] = B36(month) .. ":" .. B36(d.n) .. ":" .. B36(d.h)
        end
    elseif cmd == "DA" then
        for day, d in pairs(GB.DayDigests(key)) do
            items[#items + 1] = B36(day) .. ":" .. B36(d.n) .. ":" .. B36(d.h)
        end
    else
        for _, ev in ipairs(GB.DayEvents(key)) do items[#items + 1] = GB.Fingerprint(ev.id) end
    end
    sendList(cmd, keyStr, N, H, items)
end

-- Describe my version of a bucket soon, unless an identical one is heard first.
local function describe(cmd, key)
    local tk = cmd .. ":" .. (key and B36(key) or "")
    if descTimers[tk] then return end
    descTimers[tk] = C_Timer.NewTimer(0.5 + rank(tk) * 2.5 + math.random() * 0.5, function()
        descTimers[tk] = nil
        describeNow(cmd, key)
    end)
end

-- Pushes events a peer lacks, under a claim so only one peer does it.
--   claimKey  identifies the bucket + the peer's version of it, so peers
--             lacking the same thing share one claim
--   collect() returns the candidate events
--   theirFps  fingerprints the peer already has (nil = they have none)
local function push(claimKey, collect, theirFps)
    if pushTimers[claimKey] or recentlyHeard(claimed, claimKey) then return end
    local started, rearms = GetTime(), 0
    local function fire()
        pushTimers[claimKey] = nil
        if recentlyHeard(claimed, claimKey) then return end
        if #bulk > BUSY and rearms < 6 then            -- busy: give idle peers a chance
            rearms = rearms + 1
            pushTimers[claimKey] = C_Timer.NewTimer(#bulk * 0.3, fire)
            return
        end
        local list = {}
        for _, ev in ipairs(collect()) do
            if not (theirFps and theirFps[GB.Fingerprint(ev.id)])
                and not (heard[ev.id] and heard[ev.id] >= started) then
                list[#list + 1] = ev
            end
        end
        if #list == 0 then return end
        claimed[claimKey] = GetTime()
        sendControl("CL^" .. GB.GuildName() .. "^" .. claimKey)
        sendEvents("SY", list, sendBulk)
    end
    pushTimers[claimKey] = C_Timer.NewTimer(0.5 + rank(claimKey) * 4 + math.random() * 0.5, fire)
end

local function pushDay(day, theirFps, stateKey)
    push("d" .. B36(day) .. ":" .. stateKey, function() return GB.DayEvents(day) end, theirFps)
end

local function pushMonth(month)   -- the peer has nothing in this month
    push("m" .. B36(month), function()
        local list = {}
        for day in pairs(GB.DayDigests(month)) do
            for _, ev in ipairs(GB.DayEvents(day)) do list[#list + 1] = ev end
        end
        return list
    end, nil)
end

local function parseDigests(items)
    local out = {}
    for _, it in ipairs(items) do
        local k, n, h = strsplit(":", it)
        k, n, h = fromB36(k), fromB36(n), fromB36(h)
        if k and n and h then out[k] = { n = n, h = h } end
    end
    return out
end

-- A complete digest list from a peer whose bucket differs from ours.
local function onList(cmd, key, theirN, theirH, items)
    if cmd == "MO" then
        local theirs = parseDigests(items)
        for month, d in pairs(GB.MonthDigests()) do
            local th = theirs[month]
            if not th then pushMonth(month)
            elseif th.n ~= d.n or th.h ~= d.h then describe("DA", month) end
        end
        describe("MO")

    elseif cmd == "DA" then
        local theirs = parseDigests(items)
        for day, d in pairs(GB.DayDigests(key)) do
            local th = theirs[day]
            if not th then pushDay(day, nil, "0")
            elseif th.n ~= d.n or th.h ~= d.h then describe("ID", day) end
        end
        describe("DA", key)

    elseif cmd == "ID" then
        local theirs = {}
        for _, fp in ipairs(items) do theirs[fp] = true end
        pushDay(key, theirs, B36(theirN) .. ":" .. B36(theirH))
        -- If they hold events we don't, show them our list so they push back.
        local mine = {}
        for _, ev in ipairs(GB.DayEvents(key)) do mine[GB.Fingerprint(ev.id)] = true end
        for fp in pairs(theirs) do
            if not mine[fp] then describe("ID", key); break end
        end
    end
end

-- fields after cmd^guild:  MO -> rnd,i,n,N,H   DA/ID -> key,rnd,i,n,N,H
local function onListPart(sender, cmd, fields, body)
    local keyStr = ""
    if cmd ~= "MO" then keyStr = table.remove(fields, 1) or "" end
    local rnd, i, n = fields[1], tonumber(fields[2]), tonumber(fields[3])
    local N, H = fromB36(fields[4]), fromB36(fields[5])
    if not (rnd and i and n and N and H) then return end
    local key = nil
    if cmd ~= "MO" then
        key = fromB36(keyStr)
        if not key then return end
    end

    local descKey = cmd .. ":" .. keyStr
    heardDesc[descKey .. ":" .. N .. ":" .. H] = GetTime()

    local myN, myH = myDigest(cmd, key)
    if myN == N and myH == H then
        -- Identical bucket: nothing to exchange, and our description is redundant.
        if descTimers[descKey] then descTimers[descKey]:Cancel(); descTimers[descKey] = nil end
        partial[sender .. descKey] = nil
        return
    end

    local pk = sender .. descKey
    local p = partial[pk]
    if not p or p.rnd ~= rnd then p = { rnd = rnd, items = {} }; partial[pk] = p end
    for item in body:gmatch("[^~]+") do p.items[#p.items + 1] = item end
    if i >= n then
        partial[pk] = nil
        onList(cmd, key, N, H, p.items)
    end
end

local function sendRoot(force)
    local guild = GB.GuildName()
    if not guild then return end
    local N, H = GB.RootDigest()
    local k = "RT::" .. N .. ":" .. H
    if not force and recentlyHeard(heardDesc, k, PERIODIC) then return end
    heardDesc[k] = GetTime()
    sendControl("RT^" .. guild .. "^" .. B36(N) .. "^" .. B36(H))
end

function GB.RequestSync(verbose)
    if not GB.GuildName() then
        if verbose then GB.Print("You are not in a guild.") end
        return
    end
    sendRoot(true)
    if verbose then GB.Print("Comparing bounty board with online guildmates...") end
end

local function handleMessage(text, channel, sender)
    if channel ~= "GUILD" then return end
    local header, body = text:match("^([^~]*)(.*)$")
    local fields = { strsplit("^", header) }
    local cmd, guild = fields[1], fields[2]
    local myGuild = GB.GuildName()

    if not myGuild or guild ~= myGuild then return end                 -- other guild: discard
    if rosterLoaded and not GB.IsGuildMember(sender) then return end   -- not a guildmate: discard

    if cmd == "EV" or cmd == "SY" then
        local realm = realmOf(sender)
        local now, noticed = GetTime(), {}
        for rec in body:gmatch("[^~]+") do
            local ev = decode(rec, realm)
            if ev then
                heard[ev.id] = now
                if cmd == "EV" then
                    -- Live events must be reported by the member they're about.
                    if ev.m == sender then
                        GB.ProcessEvent(ev, "live", false, noticed[ev.k])
                        noticed[ev.k] = true
                    end
                else
                    GB.ProcessEvent(ev, "sync")
                end
            end
        end

    elseif cmd == "CL" then
        local claimKey = fields[3]
        if not claimKey then return end
        claimed[claimKey] = GetTime()
        if pushTimers[claimKey] then pushTimers[claimKey]:Cancel(); pushTimers[claimKey] = nil end

    elseif cmd == "RT" then
        local N, H = fromB36(fields[3]), fromB36(fields[4])
        if not (N and H) then return end
        heardDesc["RT::" .. N .. ":" .. H] = GetTime()
        local myN, myH = GB.RootDigest()
        if N ~= myN or H ~= myH then describe("MO") end

    elseif cmd == "MO" or cmd == "DA" or cmd == "ID" then
        onListPart(sender, cmd, { select(3, unpack(fields)) }, body)
    end
end
GB._handleMessage = handleMessage

local function prune()
    local now = GetTime()
    for k, t in pairs(heard) do if now - t > 300 then heard[k] = nil end end
    for k, t in pairs(claimed) do if now - t > 300 then claimed[k] = nil end end
    for k, t in pairs(heardDesc) do if now - t > PERIODIC * 2 then heardDesc[k] = nil end end
end

GB.OnInit(function()
    C_Timer.NewTicker(0.2, pump)
    C_Timer.NewTicker(60, prune)

    -- Background anti-entropy; skipped when a peer with our exact board
    -- already announced it within the interval.
    C_Timer.NewTicker(PERIODIC, function()
        C_Timer.After(math.random() * 60, function() sendRoot(false) end)
    end)

    GB.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
        if prefix ~= GB.PREFIX then return end
        sender = GB.FullName(sender)
        if sender == GB.PlayerName() then return end
        handleMessage(text, channel, sender)
    end)

    GB.On("GUILD_ROSTER_UPDATE", function()
        refreshRoster()
        local guild = GB.GuildName()
        if rosterLoaded and guild and announcedGuild ~= guild then
            announcedGuild = guild
            GB.RequestRefresh()
            -- Jittered so a wave of logins doesn't announce all at once.
            C_Timer.After(5 + math.random() * 25, function() sendRoot(true) end)
        end
    end)

    GB.On("PLAYER_GUILD_UPDATE", function()
        -- (the data index notices a guild change by itself)
        wipe(roster)
        rosterLoaded = false
        GB.RequestRefresh()
        if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
    end)

    GB.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
        if (isLogin or isReload) and IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
    end)
end)
