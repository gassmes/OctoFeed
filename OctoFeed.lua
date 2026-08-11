--[[---------------------------------------------------------------------------
  OctoFeed - death & level feed card under the minimap
  Vanilla 1.12 client (Lua 5.0). No libraries.

  Shows a card under the minimap when the server announces someone's death or
  level-up: class icon, name in class colour, level, what killed them, zone,
  challenge badge — plus three reaction buttons that post GZ / LOL / FK to the
  World channel and count how many people said the same thing in chat.

  Message formats are parsed from real captured lines. Anything the parser does
  not recognise is stored in SavedVariables (/octo log) so the patterns can be
  extended instead of guessed at.
-----------------------------------------------------------------------------]]

local ADDON_NAME = "OctoFeed"
local VERSION    = "0.8"
local DB_VERSION = 1

local format, floor, min   = string.format, math.floor, math.min
local mod                  = math.mod
local strfind, strlower    = string.find, string.lower
local strsub, strlen       = string.sub, string.len
local strupper             = string.upper
local gsub                 = string.gsub
local tgetn, tinsert       = table.getn, table.insert

-- Vertical layout. Rows are computed per card in LayoutCard() because three
-- things come and go: the challenge badges, the zone line, and nothing else
-- should leave a hole behind when it is absent.
local ROW_NAME    = 6
local ROW_H       = 14   -- height of one text row
local BULLET      = "- "  -- vanilla fonts have no bullet glyph
local BUTTON_SIZE = 22
local PAD_BOTTOM  = 6
local PAD_LEFT    = 8

local FONT   = "Fonts\\FRIZQT__.TTF"
local WHITE  = "Interface\\Buttons\\WHITE8X8"
local PATH   = "Interface\\AddOns\\OctoFeed\\"
-- No class icon any more: the name itself carries the class colour. The class
-- is still looked up, because that colour is the only thing telling you at a
-- glance who died.
local CLASS_LIST = {
    "WARRIOR", "MAGE", "ROGUE", "DRUID", "HUNTER",
    "SHAMAN", "PRIEST", "WARLOCK", "PALADIN",
}

-- The realm is hardcore, so "Hardcore" on a card says nothing anyone does not
-- already know. Only challenges that actually distinguish a player are listed.
local IMPLIED_CHALLENGE = {
    ["Hardcore"]      = true,
    ["Hardcore Mode"] = true,
    ["HC"]            = true,
    [""]              = true,
}

-- Challenges are shown as words, not icons: the server names them in the
-- announcement, and inventing a placeholder picture for a challenge nobody has
-- seen yet would only be a guess wearing an icon.
-- Roster of the realm's challenges, used by /octo chal.
local KNOWN_CHALLENGES = {
    "Slow & Steady", "Together Forever", "Hardcore Mode", "War Mode",
    "Exhaustion", "Traveling Craftmaster", "Way of the Samurai",
    "Vagrant's Endeavor", "Brewmaster", "Trial of Heroism",
    "Boaring Adventure", "Lunatic",
}

local REACTIONS = {
    {
        key   = "pos",
        send  = { death = "F",          level = "GZ" },
        icon  = { death = PATH .. "f",  level = PATH .. "gz" },
        tip   = { death = "Pay respects", level = "Congratulate" },
        words = {
            death = { "f", "rip", "press f", "respect", "gg" },
            level = { "gz", "grats", "gratz", "congrats", "gj" },
        },
    },
    { key = "lol", send = "LOL", icon = PATH .. "lol", tip = "Laugh",
      words = { "lol", "kek", "lmao", "xd", "ahaha" } },
    { key = "fk",  send = "FK",  icon = PATH .. "fk",  tip = "Rage",
      words = { "fk" } },
}

--- Pick the death/level variant of a reaction field, or the field itself.
local function PerKind(v, kind)
    if type(v) == "table" and (v.death ~= nil or v.level ~= nil) then
        return v[kind] or v.level or v.death
    end
    return v
end

local defaults = {
    dbVersion    = DB_VERSION,
    anchorPoint  = "TOPRIGHT",
    anchorRel    = "BOTTOMRIGHT",
    anchorX      = 0,
    anchorY      = -8,
    width        = 230,
    duration     = 60,      -- seconds the card stays up
    maxHistory   = 25,
    reactWindow  = 600,     -- seconds an event keeps counting named reactions
    bareWindow   = 90,      -- seconds a bare "gz" is attributed to the newest event
    channel      = "World",
    minLevel     = 1,
    bgAlpha      = 0.6,     -- card background opacity
    adEvery      = 5,       -- append "(OctoFeed)" to every Nth sent reaction; 0 = never
    adCount      = 0,       -- how many reactions have been sent, for the counter
    showDeaths   = true,
    showLevels   = true,
    whoLookup    = true,
    sound        = true,
    classCache   = {},
    ownChallenges  = {},
    unparsed     = {},
    capture      = true,    -- keep recording raw announcements
    raw          = {},
}

-- Lines that are certainly not announcements. Everything else is kept, so a
-- wording nobody has seen yet cannot slip through unrecorded.
local RAW_NOISE = {
    "^Experience gained", "^Quest accepted", "^Received", "^You ", "^Your ",
    "^Welcome to", "^There is no such command", "XP gain is", "player total",
    "^%[", "^|Hplayer:", " completed%.$", "^Loot", "^Auto%-loot",
}

-- Words that smell like a milestone we have not captured yet. A line carrying
-- one of these that the parser cannot turn into an event gets shouted about,
-- because that is exactly the sample worth sending.
local RAW_WATCH = {
    "immortal", "immortality", "transcend", "ascend", "eternal",
    "legend", "champion", "glory", "challenge",
}

local db
local events        = {}     -- newest first
local shownIndex    = 1
local hideAt        = 0
local isDragging    = false
local mouseOn       = false
local lastSendAt    = 0
local whoQueue      = {}
local whoBusy       = false
local whoName       = nil
local whoAskedAt    = 0
local lastWhoAt     = 0
local whoPanelWasUp = false   -- was the friends panel already open before we asked
local whoHideUntil  = 0       -- keep shoving the panel back down for a moment

local WireFrameScripts        -- defined after the click handlers exist
local frame, bgTexture, nameText, levelText, chalText, causeText, zoneText
local reactButtons  = {}
local countTexts    = {}
local indexText

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF9900[OctoFeed]|r " .. msg)
end

local function Trim(s)
    return gsub(s or "", "^%s*(.-)%s*$", "%1")
end

-----------------------------------------------------------------------------
-- Parsing
-----------------------------------------------------------------------------

local CLASS_SET = {}
for i = 1, tgetn(CLASS_LIST) do CLASS_SET[CLASS_LIST[i]] = true end

local function IsClassWord(w)
    return w ~= nil and CLASS_SET[strupper(w)] == true
end

--- string.find wrapper that returns only the captures.
local function Cap(text, pat)
    local _, _, a, b, c, d, e, f = strfind(text, pat)
    return a, b, c, d, e, f
end

local function LogUnparsed(text)
    if not db then return end
    for i = 1, tgetn(db.unparsed) do
        if db.unparsed[i] == text then return end   -- already have this shape
    end
    if tgetn(db.unparsed) >= 100 then return end
    tinsert(db.unparsed, text)
end

local function IsNoise(text)
    for i = 1, tgetn(RAW_NOISE) do
        if strfind(text, RAW_NOISE[i]) then return true end
    end
    return false
end

--- Keep the raw text of anything that might be an announcement.
local function CaptureRaw(text)
    if not db or not db.capture or not text then return end
    if IsNoise(text) then return end
    local n = tgetn(db.raw)
    if n >= 400 then
        local kept, m = {}, 0
        for i = 101, n do m = m + 1; kept[m] = db.raw[i] end
        db.raw = kept
        n = m
    end
    db.raw[n + 1] = date("%m-%d %H:%M") .. "  " .. text
end

local function LooksLikeMilestone(text)
    local low = strlower(text)
    for i = 1, tgetn(RAW_WATCH) do
        if strfind(low, RAW_WATCH[i], 1, true) then return true end
    end
    return false
end

--- Render the challenge (or challenges) an announcement named as a bullet
-- list. Only one has ever been seen per line, but "A and B" or "A, B" would
-- split correctly if the server ever names more.
-- @return text, number of lines
local function ChallengeBullets(chal)
    if not chal or IMPLIED_CHALLENGE[chal] then return "", 0 end

    local parts, n = {}, 0
    local rest = chal
    while true do
        local a, b = strfind(rest, ", ")
        if not a then
            local c, d = strfind(rest, " and ")
            if not c then break end
            a, b = c, d
        end
        local piece = Trim(strsub(rest, 1, a - 1))
        if piece ~= "" then n = n + 1; parts[n] = piece end
        rest = strsub(rest, b + 1)
    end
    rest = Trim(rest)
    if rest ~= "" then n = n + 1; parts[n] = rest end
    if n == 0 then return "", 0 end

    local text = ""
    for i = 1, n do
        if i > 1 then text = text .. "\n" end
        text = text .. BULLET .. parts[i]
    end
    return text, n
end

--- Turn a system announcement into an event table, or nil.'
-- Every pattern below is tried in order. The first block is the format that
-- was actually captured on the realm; the rest are tolerant fallbacks.
local function ParseAnnouncement(text)
    if not text then return nil end

    -- ---- deaths -----------------------------------------------------------
    if strfind(text, "tragedy has occurred", 1, true) then
        local chal, name, lvl, killer, klvl, zone

        -- CONFIRMED against a live realm:
        -- "A tragedy has occurred. Hardcore character Poweroffear (level 14)
        --  has fallen to Defias Pillager (level 15) in Alexston Farmstead."
        chal, name, lvl, killer, klvl, zone = Cap(text,
            "occurred%. (.-) character (%S+) %(level (%d+)%) has fallen to (.-) %(level (%d+)%) in (.-)%.")
        if name then
            return { kind = "death", cause = "pve", name = name, level = lvl,
                     killer = killer, killerLevel = klvl, zone = zone, challenge = chal }
        end

        -- PvP, wording not yet captured: two plausible shapes
        chal, name, lvl, killer, zone = Cap(text,
            "occurred%. (.-) character (%S+) %(level (%d+)%) has been slain by (.-) in (.-)%.")
        if name then
            return { kind = "death", cause = "pvp", name = name, level = lvl,
                     killer = killer, zone = zone, challenge = chal }
        end
        chal, name, lvl, killer, zone = Cap(text,
            "occurred%. (.-) character (%S+) %(level (%d+)%) has fallen in PvP to (.-) in (.-)%.")
        if name then
            return { kind = "death", cause = "pvp", name = name, level = lvl,
                     killer = killer, zone = zone, challenge = chal }
        end

        -- environment / natural causes
        chal, name, lvl, killer, zone = Cap(text,
            "occurred%. (.-) character (%S+) %(level (%d+)%) (died[^%.]-) in (.-)%.")
        if name then
            return { kind = "death", cause = "env", name = name, level = lvl,
                     killer = Trim(killer), zone = zone, challenge = chal }
        end

        -- older wording seen on other 1.12 realms, kept for compatibility
        chal, name, killer, klvl, lvl = Cap(text,
            "occurred%. (.-) character (%S+) has fallen to (.-) %(level (%d+)%) at level (%d+)")
        if name then
            return { kind = "death", cause = "pve", name = name, level = lvl,
                     killer = killer, killerLevel = klvl, challenge = chal }
        end

        -- last resort: pull out whatever is there so the card still appears
        name = Cap(text, "character (%S+)")
        lvl  = Cap(text, "%(level (%d+)%)")
        zone = Cap(text, " in ([^%.]+)%.")
        LogUnparsed(text)
        if name then
            return { kind = "death", cause = "unknown", name = name,
                     level = lvl, zone = zone, partial = true }
        end
        return nil
    end

    -- ---- level-ups --------------------------------------------------------
    -- Wording not captured yet, so only lines that clearly belong to the
    -- challenge announcements are accepted. Everything similar is logged.
    local name, lvl, chal

    -- CONFIRMED on a live realm: the class is part of the line, saving a /who
    -- "Paladin Suvi has reached level 20. As they ascend towards immortality..."
    local cls, nm, lv = Cap(text, "^(%a+) (%S+) has reached level (%d+)")
    if IsClassWord(cls) then
        return { kind = "level", name = nm, level = lv, class = cls }
    end
    -- same line without a class prefix
    nm, lv = Cap(text, "^(%S+) has reached level (%d+)")
    if nm then
        return { kind = "level", name = nm, level = lv }
    end

    name, lvl, chal = Cap(text, "^(%S+) .-reached level (%d+) in (.-)[%.!]")
    if name then
        return { kind = "level", name = name, level = lvl, challenge = Trim(chal) }
    end

    name = Cap(text, "^(%S+) has transcended death")
    if name then
        return { kind = "level", name = name, level = "60", milestone = "transcended" }
    end

    name = Cap(text, "^(%S+) has laughed in the face of death")
    if name then
        return { kind = "level", name = name, level = "60", milestone = "inferno" }
    end

    -- Immortality: leaving hardcore for the PvE realm. Possible at any level,
    -- so there is no level to key off - only the wording. Checked after the
    -- level-up patterns because the ding line also says "towards immortality".
    if strfind(strlower(text), "immortal", 1, true) then
        local icls, inm = Cap(text, "^(%a+) (%S+) ")
        local ilvl = Cap(text, "level (%d+)")
        if IsClassWord(icls) then
            return { kind = "immortal", name = inm, class = icls, level = ilvl }
        end
        inm = Cap(text, "^(%S+) ")
        if inm then
            LogUnparsed(text)   -- keep the sample until the wording is confirmed
            return { kind = "immortal", name = inm, level = ilvl, partial = true }
        end
    end

    if strfind(text, "reached level", 1, true)
        or strfind(text, "ascendance", 1, true)
        or strfind(text, "transcended", 1, true) then
        -- looks like an announcement but does not match anything known
        if not strfind(text, "^Experience") and not strfind(text, "^Quest") then
            LogUnparsed(text)
        end
    end

    return nil
end

-----------------------------------------------------------------------------
-- Class lookup: cache first, then a throttled /who
-- Confirmed on the realm: SetWhoToUI(1) makes the answer arrive as
-- WHO_LIST_UPDATE with nothing printed to chat.
-----------------------------------------------------------------------------

local function GetCachedClass(name)
    return db and db.classCache[name]
end

local function QueueClassLookup(name)
    if not db or not db.whoLookup or not name then return end
    if db.classCache[name] then return end
    for i = 1, tgetn(whoQueue) do
        if whoQueue[i] == name then return end
    end
    tinsert(whoQueue, name)
end

local function FinishWho()
    whoBusy = false
    whoName = nil
    if SetWhoToUI then SetWhoToUI(0) end
end

--- SetWhoToUI(1) hands the answer to the interface, and the default handler
-- helpfully pops the friends window open with it. Push it back down - but only
-- if the player did not have it open already, and for a short while, because
-- Blizzard's handler may run a frame after ours.
local function KeepWhoPanelDown()
    if whoHideUntil == 0 or GetTime() > whoHideUntil then return end
    if whoPanelWasUp then return end
    if FriendsFrame and FriendsFrame:IsVisible() then
        if HideUIPanel then HideUIPanel(FriendsFrame) else FriendsFrame:Hide() end
    end
end

local function PumpWho()
    if whoBusy or tgetn(whoQueue) == 0 then return end
    if (GetTime() - lastWhoAt) < 4 then return end     -- be gentle with the server
    local name = whoQueue[1]
    local rest, n = {}, 0
    for i = 2, tgetn(whoQueue) do n = n + 1; rest[n] = whoQueue[i] end
    whoQueue = rest

    whoBusy       = true
    whoName       = name
    whoAskedAt    = GetTime()
    lastWhoAt     = GetTime()
    whoPanelWasUp = (FriendsFrame and FriendsFrame:IsVisible()) and true or false
    whoHideUntil  = GetTime() + 2
    if SetWhoToUI then SetWhoToUI(1) end
    SendWho("n-" .. name)
end

-----------------------------------------------------------------------------
-- Reaction counting
-----------------------------------------------------------------------------

--- Whole-word search without Lua 5.1 frontier patterns.
local function HasWord(low, word)
    local start = 1
    local wl = strlen(word)
    while true do
        local s, e = strfind(low, word, start, true)
        if not s then return false end
        local before = (s > 1) and strsub(low, s - 1, s - 1) or " "
        local after  = strsub(low, e + 1, e + 1)
        if not strfind(before, "%a") and not strfind(after, "%a") then
            return true
        end
        start = s + 1
    end
end

local function NewReactionState()
    local t = {}
    for i = 1, tgetn(REACTIONS) do
        t[REACTIONS[i].key] = { count = 0, senders = {}, sent = false }
    end
    return t
end

--- Attribute a chat reaction to an event.
-- Real chat is a bare "gz" or "f" far more often than "gz Playername", so the
-- event is chosen first - by name if the line names someone, otherwise the
-- newest event while it is still fresh - and only then is the line matched
-- against the words that make sense for that event's kind.
-- One sender counts once per event and kind.
local function CountReaction(sender, msg)
    if not db or not sender or not msg then return false end
    local low     = strlower(msg)
    local nowTime = time()

    local target = nil
    for i = 1, tgetn(events) do
        local ev = events[i]
        if (nowTime - ev.at) > db.reactWindow then break end   -- newest first
        if strfind(low, strlower(ev.name), 1, true) then target = i; break end
    end
    if not target and events[1] and (nowTime - events[1].at) <= db.bareWindow then
        target = 1
    end
    if not target then return false end

    local ev   = events[target]
    local kind = nil
    for r = 1, tgetn(REACTIONS) do
        local words = PerKind(REACTIONS[r].words, ev.kind)
        for w = 1, tgetn(words) do
            if HasWord(low, words[w]) then kind = REACTIONS[r].key; break end
        end
        if kind then break end
    end
    if not kind then return false end

    local st = ev.reactions[kind]
    if st.senders[sender] then return false end
    st.senders[sender] = true
    st.count = st.count + 1
    return target == shownIndex
end

-----------------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------------

local function CreateSolidBorder(parent, r, g, b, a, size)
    local edges = {
        { "TOPLEFT",    -size,  size, "TOPRIGHT",     size,  size, "h" },
        { "BOTTOMLEFT", -size, -size, "BOTTOMRIGHT",  size, -size, "h" },
        { "TOPLEFT",    -size,  0,    "BOTTOMLEFT",  -size,  0,    "v" },
        { "TOPRIGHT",    size,  0,    "BOTTOMRIGHT",  size,  0,    "v" },
    }
    for i = 1, 4 do
        local e   = edges[i]
        local tex = parent:CreateTexture(nil, "BORDER")
        tex:SetTexture(r, g, b, a)
        tex:SetPoint(e[1], parent, e[1], e[2], e[3])
        tex:SetPoint(e[4], parent, e[4], e[5], e[6])
        if e[7] == "h" then tex:SetHeight(size) else tex:SetWidth(size) end
    end
end

local function NewText(parent, size, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size, flags or "")
    return fs
end

local function BuildUI()
    frame = CreateFrame("Frame", "OctoFeedFrame", UIParent)
    frame:SetWidth(230)
    frame:SetHeight(96)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    frame:RegisterForDrag("LeftButton")
    if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end
    frame:Hide()

    bgTexture = frame:CreateTexture(nil, "BACKGROUND")
    bgTexture:SetAllPoints(frame)
    bgTexture:SetTexture(0, 0, 0, 0.6)
    CreateSolidBorder(frame, 0, 0, 0, 1, 1)

    nameText = NewText(frame, 12, "OUTLINE")
    nameText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_LEFT, -ROW_NAME)

    levelText = NewText(frame, 12, "OUTLINE")
    levelText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -7)
    levelText:SetTextColor(1, 0.82, 0)

    -- Rows are pinned to explicit offsets from the top instead of being
    -- chained to each other: chaining let the zone line grow down into the
    -- reaction buttons.
    causeText = NewText(frame, 10)
    causeText:SetJustifyH("LEFT")
    causeText:SetTextColor(1, 0.5, 0.5)

    zoneText = NewText(frame, 10)
    zoneText:SetJustifyH("LEFT")
    zoneText:SetTextColor(0.7, 0.7, 0.7)

    indexText = NewText(frame, 9)
    indexText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -5, 5)
    indexText:SetTextColor(0.5, 0.5, 0.5)

    chalText = NewText(frame, 10)
    chalText:SetJustifyH("LEFT")
    chalText:SetTextColor(0.72, 0.6, 1)

    -- reaction buttons
    for i = 1, tgetn(REACTIONS) do
        local def = REACTIONS[i]
        local b = CreateFrame("Button", "OctoFeedReact" .. def.key, frame)
        b:SetWidth(22)
        b:SetHeight(22)
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_LEFT + (i - 1) * 48, -60)
        local tex = b:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(b)
        tex:SetTexture(PerKind(def.icon, "level"))
        b.tex = tex
        b:SetScript("OnEnter", function()
            local ev   = events[shownIndex]
            local kind = ev and ev.kind or "level"
            GameTooltip:SetOwner(this, "ANCHOR_TOP")
            GameTooltip:AddLine(PerKind(def.tip, kind))
            GameTooltip:AddLine("sends \"" .. PerKind(def.send, kind) .. " " ..
                ((ev and ev.name) or "<name>") .. "\" to " .. (db and db.channel or "World"),
                1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        reactButtons[i] = b

        local c = NewText(frame, 11, "OUTLINE")
        c:SetPoint("LEFT", b, "RIGHT", 3, 0)
        c:SetTextColor(1, 1, 1)
        countTexts[i] = c
    end

    WireFrameScripts()
end

--- Background opacity, adjustable at runtime.
local function ApplyAlpha()
    if bgTexture and db then
        bgTexture:SetTexture(0, 0, 0, db.bgAlpha)
    end
end

local function ApplyPosition()
    frame:ClearAllPoints()
    local parent = Minimap or UIParent
    frame:SetPoint(db.anchorPoint or "TOPRIGHT", parent,
                   db.anchorRel or "BOTTOMRIGHT",
                   db.anchorX or 0, db.anchorY or -8)
    frame:SetWidth(db.width)
end

local function SavePosition()
    local point, _, rel, x, y = frame:GetPoint()
    db.anchorPoint = point
    db.anchorRel   = rel or point
    db.anchorX     = x
    db.anchorY     = y
end

--- Place every row for the card about to be shown and size the frame to it.
-- Absent rows collapse instead of leaving a gap.
local function LayoutCard(chalLines, hasZone)
    local y = ROW_NAME + ROW_H      -- below the name (was a leaked global)

    if chalLines > 0 then
        chalText:ClearAllPoints()
        chalText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_LEFT, -y)
        chalText:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
        y = y + ROW_H * chalLines
    end

    causeText:ClearAllPoints()
    causeText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_LEFT, -y)
    causeText:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    y = y + ROW_H

    if hasZone then
        zoneText:ClearAllPoints()
        zoneText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_LEFT, -y)
        zoneText:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
        y = y + ROW_H
    end

    y = y + 4
    for i = 1, tgetn(reactButtons) do
        reactButtons[i]:ClearAllPoints()
        reactButtons[i]:SetPoint("TOPLEFT", frame, "TOPLEFT",
            PAD_LEFT + (i - 1) * 48, -y)
    end
    frame:SetHeight(y + BUTTON_SIZE + PAD_BOTTOM)
end

local function Refresh()
    local ev = events[shownIndex]
    if not ev then frame:Hide() return end

    local class = GetCachedClass(ev.name)
    local r, g, b = 0.75, 0.75, 0.75          -- unknown class stays grey
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[strupper(class)] then
        local c = RAID_CLASS_COLORS[strupper(class)]
        r, g, b = c.r, c.g, c.b
    end
    nameText:SetText(ev.name)
    nameText:SetTextColor(r, g, b)

    levelText:SetText(ev.level and ("lvl " .. ev.level) or "")

    if ev.kind == "death" then
        if ev.cause == "pve" and ev.killer then
            causeText:SetText("killed by " .. ev.killer ..
                (ev.killerLevel and (" (" .. ev.killerLevel .. ")") or ""))
            causeText:SetTextColor(1, 0.45, 0.45)
        elseif ev.cause == "pvp" and ev.killer then
            causeText:SetText("slain in PvP by " .. ev.killer)
            causeText:SetTextColor(1, 0.3, 0.3)
        elseif ev.cause == "env" then
            causeText:SetText(ev.killer or "died")
            causeText:SetTextColor(1, 0.6, 0.4)
        else
            causeText:SetText("died")
            causeText:SetTextColor(1, 0.5, 0.5)
        end
    elseif ev.kind == "immortal" then
        causeText:SetText("went immortal, moved to PvE")
        causeText:SetTextColor(0.4, 0.85, 1)
    else
        if ev.milestone == "transcended" then
            causeText:SetText("transcended death at 60!")
        elseif ev.milestone == "inferno" then
            causeText:SetText("began the Infernal challenge!")
        else
            causeText:SetText("reached level " .. tostring(ev.level) .. "!")
        end
        causeText:SetTextColor(0.4, 1, 0.4)
    end

    local hasZone = (ev.zone ~= nil and ev.zone ~= "")
    zoneText:SetText(hasZone and ev.zone or "")

    -- challenge lines, one bullet each
    local chalStr, chalLines = ChallengeBullets(ev.challenge)
    chalText:SetText(chalStr)
    LayoutCard(chalLines, hasZone)

    for i = 1, tgetn(REACTIONS) do
        local def = REACTIONS[i]
        local st  = ev.reactions[def.key]
        reactButtons[i].tex:SetTexture(PerKind(def.icon, ev.kind))
        countTexts[i]:SetText(st.count > 0 and tostring(st.count) or "")
        reactButtons[i]:SetAlpha(st.sent and 0.45 or 1)
    end

    indexText:SetText(shownIndex .. "/" .. tgetn(events))
    frame:Show()
end

-----------------------------------------------------------------------------
-- Event intake
-----------------------------------------------------------------------------

local function AddEvent(ev)
    if not db then return end
    if ev.kind == "death" then
        if not db.showDeaths then return end
    elseif not db.showLevels then
        return
    end
    local lvl = tonumber(ev.level or 0) or 0
    if lvl > 0 and lvl < db.minLevel then return end

    ev.at        = time()
    ev.reactions = NewReactionState()
    if ev.class then db.classCache[ev.name] = ev.class end

    local shifted, n = { ev }, 1
    for i = 1, min(tgetn(events), db.maxHistory - 1) do
        n = n + 1
        shifted[n] = events[i]
    end
    events = shifted
    shownIndex = 1

    QueueClassLookup(ev.name)
    hideAt = GetTime() + db.duration
    if db.sound then PlaySound("igQuestListComplete") end
    Refresh()
end

-----------------------------------------------------------------------------
-- Sending a reaction
-----------------------------------------------------------------------------

local function SendReaction(index)
    local ev  = events[shownIndex]
    local def = REACTIONS[index]
    if not ev or not def then return end

    local word = PerKind(def.send, ev.kind)
    local st   = ev.reactions[def.key]
    if st.sent then
        Print("already sent " .. word .. " for " .. ev.name .. ".")
        return
    end
    if (GetTime() - lastSendAt) < 3 then
        Print("slow down a second - the server throttles chat.")
        return
    end

    local id = GetChannelName(db.channel)
    if not id or id == 0 then
        Print("channel \"" .. db.channel .. "\" not joined. /octo channel <name>")
        return
    end

    -- Advertise the addon on every Nth message rather than every one: a tag on
    -- each line reads as spam and gets people muted.
    local text = word .. " " .. ev.name
    db.adCount = (db.adCount or 0) + 1
    if db.adEvery and db.adEvery > 0 and mod(db.adCount, db.adEvery) == 0 then
        text = text .. " (" .. ADDON_NAME .. ")"
    end

    SendChatMessage(text, "CHANNEL", nil, id)
    st.sent    = true
    lastSendAt = GetTime()
    hideAt     = GetTime() + db.duration
    Refresh()
end

-----------------------------------------------------------------------------
-- Own challenges: learn the real icon paths from the spellbook
-----------------------------------------------------------------------------

local function ScanOwnChallenges()
    if not db then return 0 end
    local i, found = 1, 0
    while true do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if rank == "Challenge" then
            db.ownChallenges[name] = true
            found = found + 1
        end
        i = i + 1
    end
    return found
end

-----------------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------------

local function Initialize()
    if db then return end
    if not OctoFeedDB then OctoFeedDB = {} end
    db = OctoFeedDB
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = v end
    end
    if type(db.classCache)     ~= "table" then db.classCache     = {} end
    if type(db.ownChallenges)  ~= "table" then db.ownChallenges  = {} end
    if type(db.unparsed)       ~= "table" then db.unparsed       = {} end

    BuildUI()
    ApplyPosition()
    ApplyAlpha()
    ScanOwnChallenges()
    Print("v" .. VERSION .. " loaded. /octo for commands, /octo demo to see the card.")
end

local function OnWhoResult()
    if not whoBusy then return end
    local num = GetNumWhoResults and GetNumWhoResults() or 0
    for i = 1, num do
        local n, _, _, _, class = GetWhoInfo(i)
        if n and class then
            db.classCache[n] = class
        end
    end
    FinishWho()
    KeepWhoPanelDown()
    Refresh()
end

local driver = CreateFrame("Frame", "OctoFeedDriver", UIParent)
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("VARIABLES_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("CHAT_MSG_SYSTEM")
driver:RegisterEvent("CHAT_MSG_CHANNEL")
driver:RegisterEvent("CHAT_MSG_SAY")
driver:RegisterEvent("CHAT_MSG_YELL")
driver:RegisterEvent("WHO_LIST_UPDATE")

driver:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then Initialize() end

    elseif event == "VARIABLES_LOADED" then
        Initialize()

    elseif event == "PLAYER_ENTERING_WORLD" then
        Initialize()
        ScanOwnChallenges()

    elseif event == "CHAT_MSG_SYSTEM" then
        if db then
            CaptureRaw(arg1)
            local ev = ParseAnnouncement(arg1)
            if ev then
                AddEvent(ev)
                if ev.partial then
                    Print("|cFFFFFF00partly understood announcement - /octo log to see it|r")
                end
            elseif LooksLikeMilestone(arg1) and not IsNoise(arg1) then
                Print("|cFF00FF00NEW ANNOUNCEMENT TYPE CAUGHT|r - please send this line:")
                DEFAULT_CHAT_FRAME:AddMessage("   " .. arg1)
                LogUnparsed(arg1)
            end
        end

    elseif event == "CHAT_MSG_CHANNEL" or event == "CHAT_MSG_SAY"
        or event == "CHAT_MSG_YELL" then
        if db and CountReaction(arg2, arg1) then Refresh() end

    elseif event == "WHO_LIST_UPDATE" then
        OnWhoResult()
    end
end)

driver:SetScript("OnUpdate", function()
    if not db then return end
    PumpWho()
    KeepWhoPanelDown()
    if whoBusy and (GetTime() - whoAskedAt) > 6 then FinishWho() end
    if frame and frame:IsVisible() and hideAt > 0 and GetTime() > hideAt then
        if not MouseIsOver(frame) then
            frame:Hide()
            hideAt = 0
        end
    end
end)

-----------------------------------------------------------------------------
-- Frame scripts that need the frame to exist: wired lazily from BuildUI
-----------------------------------------------------------------------------

WireFrameScripts = function()
    frame:SetScript("OnDragStart", function()
        if IsShiftKeyDown() then isDragging = true; this:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function()
        isDragging = false
        this:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnMouseWheel", function()
        local dir = arg1
        local total = tgetn(events)
        if total == 0 then return end
        if dir > 0 then
            shownIndex = shownIndex - 1
            if shownIndex < 1 then shownIndex = 1 end
        else
            shownIndex = shownIndex + 1
            if shownIndex > total then shownIndex = total end
        end
        hideAt = GetTime() + db.duration
        Refresh()
    end)
    for i = 1, tgetn(REACTIONS) do
        local idx = i
        reactButtons[i]:SetScript("OnClick", function() SendReaction(idx) end)
    end
end

-----------------------------------------------------------------------------
-- Demo
-----------------------------------------------------------------------------

local DEMO_LINES = {
    "A tragedy has occurred. Hardcore character Poweroffear (level 14) has fallen to Defias Pillager (level 15) in Alexston Farmstead. May this sacrifice not be forgotten.",
    "A tragedy has occurred. Hardcore character Squishymage (level 27) has been slain by Gankmaster in Stranglethorn Vale. May this sacrifice not be forgotten.",
    "A tragedy has occurred. Hardcore character Cliffjumper (level 33) died of a fall in Thousand Needles. May this sacrifice not be forgotten.",
    "Paladin Suvi has reached level 20. As they ascend towards immortality, their glory grows! However, so too does the danger they face.",
    "Ironwill has transcended death by reaching level 60 in Hardcore mode!",
}

local function RunDemo()
    for i = 1, tgetn(DEMO_LINES) do
        local ev = ParseAnnouncement(DEMO_LINES[i])
        if ev then
            AddEvent(ev)
        else
            Print("demo line " .. i .. " did not parse: " .. DEMO_LINES[i])
        end
    end
    -- pretend some strangers reacted, so the counters are visible
    CountReaction("Alice",  "f Poweroffear")     -- named, death -> respects
    CountReaction("Bob",    "F POWEROFFEAR")
    CountReaction("Carol",  "lol poweroffear")
    CountReaction("Dave",   "gz")                -- bare, newest event is a ding
    CountReaction("Erin",   "GZ")
    shownIndex = tgetn(events)
    Refresh()
    Print("demo: " .. tgetn(events) .. " events, mouse wheel scrolls the history.")
end

-----------------------------------------------------------------------------
-- Slash commands (two handlers: Lua 5.0 caps a closure at 32 upvalues)
-----------------------------------------------------------------------------

local function SlashLayout(cmd, rest)
    if cmd == "show" then
        if tgetn(events) == 0 then Print("no events yet. /octo demo to see the card.") return true end
        hideAt = GetTime() + db.duration
        Refresh()

    elseif cmd == "hide" then
        frame:Hide()
        hideAt = 0

    elseif cmd == "pos" then
        db.anchorPoint = defaults.anchorPoint
        db.anchorRel   = defaults.anchorRel
        db.anchorX     = defaults.anchorX
        db.anchorY     = defaults.anchorY
        ApplyPosition()
        Print("position reset under the minimap.")

    elseif cmd == "width" then
        local n = tonumber(rest)
        if n then
            if n < 150 then n = 150 end
            if n > 500 then n = 500 end
            db.width = floor(n)
            ApplyPosition()
            Print("width " .. db.width)
        else
            Print("width " .. db.width .. " (usage: /octo width 150-500)")
        end

    elseif cmd == "duration" then
        local n = tonumber(rest)
        if n then
            if n < 3   then n = 3   end
            if n > 300 then n = 300 end
            db.duration = floor(n)
            Print("card stays " .. db.duration .. "s")
        else
            Print("duration " .. db.duration .. "s (usage: /octo duration 3-300)")
        end

    elseif cmd == "channel" then
        if rest ~= "" then
            db.channel = rest
            Print("reactions go to channel \"" .. rest .. "\"")
        else
            local id = GetChannelName(db.channel)
            Print("channel \"" .. db.channel .. "\" -> number " .. tostring(id or 0))
        end

    elseif cmd == "ad" then
        local n = tonumber(rest)
        if n then
            if n < 0  then n = 0  end
            if n > 50 then n = 50 end
            db.adEvery = floor(n)
            if db.adEvery == 0 then
                Print("addon tag off - messages stay clean.")
            else
                Print("addon tag on 1 message in " .. db.adEvery .. ".")
            end
        else
            if (db.adEvery or 0) == 0 then
                Print("addon tag: off (usage: /octo ad 5, or /octo ad 0 to disable)")
            else
                Print("addon tag: 1 message in " .. db.adEvery .. ", " ..
                      (db.adCount or 0) .. " sent so far")
            end
        end

    elseif cmd == "alpha" then
        local n = tonumber(rest)
        if n then
            -- accept both 0.6 and 60, but do not turn a fat-fingered 2 into 0.02
            if n >= 5 then
                n = n / 100
            elseif n > 1 then
                n = 1
            end
            if n < 0.05 then n = 0.05 end
            if n > 1    then n = 1    end
            db.bgAlpha = n
            ApplyAlpha()
            Print(format("background opacity %.2f", db.bgAlpha))
        else
            Print(format("background opacity %.2f (usage: /octo alpha 0.6)", db.bgAlpha))
        end

    elseif cmd == "sound" then
        db.sound = not db.sound
        Print("sound " .. (db.sound and "on" or "off"))

    elseif cmd == "demo" then
        RunDemo()

    else
        return false
    end
    return true
end

local function SlashData(cmd, rest)
    if cmd == "deaths" then
        db.showDeaths = not db.showDeaths
        Print("deaths " .. (db.showDeaths and "shown" or "hidden"))

    elseif cmd == "levels" then
        db.showLevels = not db.showLevels
        Print("level-ups " .. (db.showLevels and "shown" or "hidden"))

    elseif cmd == "minlevel" then
        local n = tonumber(rest)
        if n then
            db.minLevel = floor(n)
            Print("only events from level " .. db.minLevel .. " up")
        else
            Print("minlevel " .. db.minLevel)
        end

    elseif cmd == "who" then
        db.whoLookup = not db.whoLookup
        Print("class lookup via /who " .. (db.whoLookup and "on" or "off"))

    elseif cmd == "chal" or cmd == "challenges" then
        local n = ScanOwnChallenges()
        Print("challenges on this character (" .. n .. "):")
        if n == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("   none")
        else
            for k in pairs(db.ownChallenges) do
                DEFAULT_CHAT_FRAME:AddMessage("   |cFF55FF55" .. BULLET .. k .. "|r")
            end
        end
        Print("every challenge on this realm:")
        for i = 1, tgetn(KNOWN_CHALLENGES) do
            DEFAULT_CHAT_FRAME:AddMessage("   " .. BULLET .. KNOWN_CHALLENGES[i])
        end
        Print("a card lists a challenge only when the server names one; " ..
              "\"Hardcore\" is skipped because the whole realm is.")

    elseif cmd == "log" then
        local n = tgetn(db.unparsed)
        if n == 0 then
            Print("no unrecognised announcements captured. Good.")
        else
            Print(n .. " announcement(s) the parser did not understand:")
            for i = 1, n do
                DEFAULT_CHAT_FRAME:AddMessage("   " .. db.unparsed[i])
            end
            Print("send these to have the patterns extended.")
        end

    elseif cmd == "raw" then
        local n = tgetn(db.raw)
        if n == 0 then
            Print("nothing recorded yet.")
        else
            local from = n - 19
            if from < 1 then from = 1 end
            Print("last " .. (n - from + 1) .. " of " .. n .. " recorded lines:")
            for i = from, n do
                DEFAULT_CHAT_FRAME:AddMessage("   " .. db.raw[i])
            end
            Print("full log is in SavedVariables\\OctoFeed.lua after /reload")
        end

    elseif cmd == "capture" then
        db.capture = not db.capture
        Print("raw announcement capture " .. (db.capture and "on" or "off"))

    elseif cmd == "rawclear" then
        db.raw = {}
        Print("raw log cleared.")

    elseif cmd == "clearlog" then
        db.unparsed = {}
        Print("unparsed log cleared.")

    elseif cmd == "cache" then
        local n = 0
        for _ in pairs(db.classCache) do n = n + 1 end
        Print("class cache: " .. n .. " players")

    elseif cmd == "status" then
        Print("v" .. VERSION .. ", events kept: " .. tgetn(events) ..
              ", unparsed: " .. tgetn(db.unparsed) ..
              ", raw recorded: " .. tgetn(db.raw) ..
              (db.capture and "" or " (capture OFF)"))
        Print("channel " .. db.channel .. " (number " ..
              tostring(GetChannelName(db.channel) or 0) .. "), duration " ..
              db.duration .. "s, minlevel " .. db.minLevel)

    else
        return false
    end
    return true
end

local function ShowHelp()
    Print("v" .. VERSION .. " - commands:")
    local lines = {
        "  Shift + drag  - move the card;  mouse wheel - browse history",
        "  /octo demo      - fake events so you can see and click the card",
        "  first button sends F for a death and GZ for a level-up",
        "  /octo show|hide - force the card",
        "  /octo pos       - put it back under the minimap",
        "  /octo width 230 | /octo duration 60 | /octo alpha 0.6",
        "  /octo channel World  - where reactions are posted",
        "  /octo ad 5      - tag 1 sent message in 5 with the addon name (0 = off)",
        "  /octo deaths | /octo levels  - toggle event types",
        "  /octo minlevel 10    - ignore low level events",
        "  /octo who       - toggle class lookup",
        "  /octo chal      - list every challenge the addon knows and its icon",
        "  /octo log       - announcements the parser did not understand",
        "  /octo raw       - last 20 recorded system lines (hunting the level 60 wording)",
        "  /octo capture   - toggle raw recording;  /octo rawclear - wipe it",
        "  /octo status    - current settings",
    }
    for i = 1, tgetn(lines) do
        DEFAULT_CHAT_FRAME:AddMessage(lines[i])
    end
end

SLASH_OCTOFEED1 = "/octo"
SLASH_OCTOFEED2 = "/octofeed"
SlashCmdList["OCTOFEED"] = function(msg)
    if not db then Print("not ready yet") return end
    local raw = Trim(msg)
    local _, _, rawCmd, rawRest = strfind(raw, "^(%S+)%s*(.*)$")
    local cmd  = strlower(rawCmd or "")
    local rest = Trim(rawRest or "")

    if cmd == "" or cmd == "help" then
        ShowHelp()
    elseif not SlashLayout(cmd, rest) then
        if not SlashData(cmd, rest) then ShowHelp() end
    end
end
