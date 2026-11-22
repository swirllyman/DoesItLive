-- DoesItLive probe
-- Answers, before any real feature is built: what can addon code read about HEALING on friendly units in
-- WoW Forever, in and out of combat? Everything goes to a log saved in SavedVariables (DoesItLiveDB.log,
-- written on /reload or logout). Every API call is wrapped in pcall, so a blocked or missing API is logged,
-- never fatal. See CLAUDE.md for the list of questions and how to read the answers.

local ADDON = ...
local PREFIX = "DoesItLive"
local MAX_LOG_LINES = 2000
local AUTO_SNAPSHOT_DELAY = 4
local PER_FIGHT_LIMIT = 25 -- per event kind, so a long fight doesn't flood the log
local METER_TRIES, METER_RETRY_SECONDS = 20, 0.5
local WHITE = "Interface\\Buttons\\WHITE8X8"

local db
local log = {}
local echo = false
local fightCounts = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function out(msg, toChat)
    table.insert(log, date("%H:%M:%S") .. " " .. msg)
    if #log > MAX_LOG_LINES then table.remove(log, 1) end
    if toChat or echo then DEFAULT_CHAT_FRAME:AddMessage("|cff66ff99DIL|r " .. msg) end
end

local function isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r or false
end

-- Describes a value and whether addon code can do maths / comparisons with it.
local function probe(v)
    if v == nil then return "nil" end
    local secret = isSecret(v)
    local shown = "<secret>"
    if not secret then
        local ok, s = pcall(tostring, v)
        shown = ok and s or "<tostring blocked>"
    end
    if type(v) ~= "number" and not secret then return shown end
    local mathOK = pcall(function() return v + 0 end)
    local cmpOK = pcall(function() return v < 1 end)
    return string.format("%s[s=%s m=%s c=%s]", shown, secret and "Y" or "n",
        mathOK and "ok" or "NO", cmpOK and "ok" or "NO")
end

local function exists(fnName)
    return type(_G[fnName]) == "function"
end

-- Calls _G[fnName](...) and returns a description of every result, or why it couldn't.
local function call(fnName, ...)
    local fn = _G[fnName]
    if type(fn) ~= "function" then return "missing" end
    local res = { pcall(fn, ...) }
    if not res[1] then return "ERROR " .. tostring(res[2]) end
    local parts = {}
    for i = 2, math.max(#res, 2) do parts[#parts + 1] = probe(res[i]) end
    return table.concat(parts, ", ")
end

local function readableNumber(v)
    return type(v) == "number" and not isSecret(v)
end

local function limited(kind)
    local n = (fightCounts[kind] or 0) + 1
    fightCounts[kind] = n
    return n <= PER_FIGHT_LIMIT
end

local function inCombat()
    return UnitAffectingCombat("player") and true or false
end

-- Friendly unit tokens worth checking right now.
local function friendlyUnits()
    local units = { "player" }
    for _, u in ipairs({ "target", "focus", "mouseover" }) do
        local ok, assist = pcall(UnitCanAssist, "player", u)
        if UnitExists(u) and ok and assist == true and not UnitIsUnit(u, "player") then units[#units + 1] = u end
    end
    for i = 1, 4 do
        if UnitExists("party" .. i) then units[#units + 1] = "party" .. i end
    end
    if UnitExists("pet") then units[#units + 1] = "pet" end
    if IsInRaid and IsInRaid() then
        for i = 1, 3 do -- a few raid tokens are enough to tell whether they behave like party ones
            if UnitExists("raid" .. i) then units[#units + 1] = "raid" .. i end
        end
    end
    return units
end

-- The unit token showing a friendly player with this name (UNIT_SPELLCAST_SENT gives a name).
local function unitByName(name)
    if type(name) ~= "string" or isSecret(name) or name == "" then return nil end
    local short = name:match("^[^-]+") or name
    for _, u in ipairs(friendlyUnits()) do
        local ok, n = pcall(UnitName, u)
        if ok and not isSecret(n) and n == short then return u end
    end
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do
            local u = "raid" .. i
            local ok, n = pcall(UnitName, u)
            if ok and not isSecret(n) and n == short then return u end
        end
    end
    return nil
end

local function spellName(spellID)
    if isSecret(spellID) then return "<secret id>" end
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, spellID)
        if ok then return probe(n) end
    elseif exists("GetSpellInfo") then
        local ok, n = pcall(GetSpellInfo, spellID)
        if ok then return probe(n) end
    end
    return "?"
end

local function spellDescription(spellID)
    if isSecret(spellID) then return "<secret id>" end
    local fn = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
    if not fn then return "missing" end
    local ok, d = pcall(fn, spellID)
    return ok and probe(d) or ("ERROR " .. tostring(d))
end

---------------------------------------------------------------------------
-- Q1-Q4: health, heal prediction, auras on friendly units
---------------------------------------------------------------------------

local function probeAuras(unit, filter, limit)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
        out("    auras: C_UnitAuras.GetAuraDataByIndex missing")
        return
    end
    for i = 1, limit do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
        if not ok then
            out(string.format("    [%s #%d] ERROR %s", filter, i, tostring(aura)))
            return
        end
        if not aura then
            if i == 1 then out("    [" .. filter .. "] none") end
            return
        end
        if isSecret(aura) then
            out(string.format("    [%s #%d] the aura table itself is secret", filter, i))
            return
        end
        local fok, err = pcall(function()
            local pts = type(aura.points) == "table" and not isSecret(aura.points) and aura.points[1] or nil
            out(string.format("    [%s #%d] %s id=%s dur=%s exp=%s src=%s pts1=%s mine=%s",
                filter, i, probe(aura.name), probe(aura.spellId), probe(aura.duration),
                probe(aura.expirationTime), probe(aura.sourceUnit), probe(pts), probe(aura.isFromPlayerOrPlayerPet)))
        end)
        if not fok then out(string.format("    [%s #%d] field read ERROR %s", filter, i, tostring(err))) end
    end
end

local function probeUnit(unit)
    out(string.format("  -- %s: name=%s assist=%s attack=%s", unit, call("UnitName", unit),
        call("UnitCanAssist", "player", unit), call("UnitCanAttack", "player", unit)))
    out("    UnitHealth=" .. call("UnitHealth", unit) .. "  UnitHealthMax=" .. call("UnitHealthMax", unit))
    out("    UnitHealthMissing=" .. call("UnitHealthMissing", unit) .. "  UnitHealthPercent=" .. call("UnitHealthPercent", unit))
    out("    UnitGetIncomingHeals(all)=" .. call("UnitGetIncomingHeals", unit)
        .. "  (mine)=" .. call("UnitGetIncomingHeals", unit, "player"))
    out("    UnitGetTotalAbsorbs=" .. call("UnitGetTotalAbsorbs", unit)
        .. "  UnitGetTotalHealAbsorbs=" .. call("UnitGetTotalHealAbsorbs", unit))
    if exists("UnitGetDetailedHealPrediction") then
        out("    UnitGetDetailedHealPrediction=" .. call("UnitGetDetailedHealPrediction", unit, "player"))
    end
    probeAuras(unit, "HELPFUL|PLAYER", 8)
    probeAuras(unit, "HELPFUL", 8)
end

local function snapshot(reason)
    out("===== SNAPSHOT (" .. reason .. ") =====", reason == "manual")
    local _, build, _, iface = GetBuildInfo()
    local _, class = UnitClass("player")
    out(string.format("build=%s iface=%s class=%s level=%s inCombat=%s group=%s raid=%s", tostring(build),
        tostring(iface), tostring(class), tostring(UnitLevel("player")), tostring(inCombat()),
        tostring(IsInGroup and IsInGroup()), tostring(IsInRaid and IsInRaid())))
    out("issecretvalue=" .. tostring(exists("issecretvalue")) .. " canaccesstable=" .. tostring(exists("canaccesstable")))
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, r = pcall(C_Secrets.ShouldAurasBeSecret)
        out("C_Secrets.ShouldAurasBeSecret()=" .. (ok and tostring(r) or ("ERROR " .. tostring(r))))
    end
    out("GetSpellBonusHealing=" .. call("GetSpellBonusHealing"))
    for _, fnName in ipairs({ "UnitHealthMissing", "UnitGetIncomingHeals", "UnitGetDetailedHealPrediction",
        "CreateUnitHealPredictionCalculator", "UnitGetTotalAbsorbs", "UnitGetTotalHealAbsorbs" }) do
        out("  exists " .. fnName .. "=" .. tostring(exists(fnName)))
    end
    for _, unit in ipairs(friendlyUnits()) do probeUnit(unit) end
end

---------------------------------------------------------------------------
-- Q5: does a UNIT_COMBAT heal amount include overheal? Out of combat, with readable health, compare the
-- reported amount with the health actually gained (next UNIT_HEALTH for that unit).
---------------------------------------------------------------------------

local pendingHeal = {} -- unit -> { amount, before, max, at }

local function onUnitCombat(unit, action, flag, amount, school)
    local actionText = isSecret(action) and "<secret>" or tostring(action)
    local friendly = false
    local okA, assist = pcall(UnitCanAssist, "player", unit)
    if okA and assist == true then friendly = true end
    if not friendly and actionText ~= "HEAL" then return end
    if not limited("combat:" .. actionText) then return end
    local _, hp = pcall(UnitHealth, unit)
    local _, hpMax = pcall(UnitHealthMax, unit)
    out(string.format("UNIT_COMBAT unit=%s action=%s flag=%s amount=%s school=%s hp=%s/%s combat=%s",
        tostring(unit), actionText, probe(flag), probe(amount), probe(school), probe(hp), probe(hpMax),
        tostring(inCombat())))
    if actionText == "HEAL" and readableNumber(amount) and readableNumber(hp) and readableNumber(hpMax) then
        pendingHeal[unit] = { amount = amount, before = hp, max = hpMax, at = GetTime() }
    end
end

local function onUnitHealth(unit)
    local p = pendingHeal[unit]
    if not p then return end
    pendingHeal[unit] = nil
    if GetTime() - p.at > 1 then return end
    local _, hp = pcall(UnitHealth, unit)
    if not readableNumber(hp) then return end
    -- UNIT_COMBAT may arrive before or after the health changes; log both readings.
    out(string.format("HEAL CHECK %s amount=%d hpAtEvent=%d hpNow=%d max=%d gainedSinceEvent=%d missingAtEvent=%d",
        unit, p.amount, p.before, hp, p.max, hp - p.before, p.max - p.before))
end

---------------------------------------------------------------------------
-- Q6: own HoT casts, and whether heal prediction counts them (snapshots of the cast's target right after)
---------------------------------------------------------------------------

local sentTarget = {} -- castGUID -> target name

local function predictionLine(unit, tag)
    out(string.format("  PREDICT %s %s incoming(all)=%s (mine)=%s hp=%s", tag, unit,
        call("UnitGetIncomingHeals", unit), call("UnitGetIncomingHeals", unit, "player"), call("UnitHealth", unit)))
end

local function onOwnCast(castGUID, spellID)
    local name = sentTarget[castGUID]
    sentTarget[castGUID] = nil
    local unit = unitByName(name) or "player"
    out(string.format("CAST %s id=%s on=%s (%s) desc=%s", spellName(spellID), probe(spellID), probe(name),
        unit, spellDescription(spellID)))
    predictionLine(unit, "+0.0s")
    C_Timer.After(0.3, function() predictionLine(unit, "+0.3s") end)
    C_Timer.After(3.5, function() predictionLine(unit, "+3.5s") end)
end

---------------------------------------------------------------------------
-- Q7: other players' casts (route to tracking others' HoTs without auras)
---------------------------------------------------------------------------

local function onOtherCast(unit, spellID)
    if not limited("othercast") then return end
    out(string.format("OTHER CAST unit=%s id=%s name=%s theirTarget=%s combat=%s", tostring(unit), probe(spellID),
        spellName(spellID), call("UnitName", unit .. "target"), tostring(inCombat())))
end

---------------------------------------------------------------------------
-- Q8: UNIT_AURA payloads on friendly units
---------------------------------------------------------------------------

local function onUnitAura(unit, info)
    local okA, assist = pcall(UnitCanAssist, "player", unit)
    if not (okA and assist == true) then return end
    if not limited("aura") then return end
    if type(info) ~= "table" or isSecret(info) then
        out("UNIT_AURA " .. tostring(unit) .. " info=" .. probe(info))
        return
    end
    local ok, err = pcall(function()
        local added = info.addedAuras
        local first = type(added) == "table" and not isSecret(added) and added[1] or nil
        out(string.format("UNIT_AURA %s full=%s added=%s removed=%s updated=%s first: %s id=%s src=%s exp=%s",
            tostring(unit), probe(info.isFullUpdate), type(added) == "table" and probe(#added) or "0",
            type(info.removedAuraInstanceIDs) == "table" and probe(#info.removedAuraInstanceIDs) or "0",
            type(info.updatedAuraInstanceIDs) == "table" and probe(#info.updatedAuraInstanceIDs) or "0",
            first and probe(first.name) or "-", first and probe(first.spellId) or "-",
            first and probe(first.sourceUnit) or "-", first and probe(first.expirationTime) or "-"))
    end)
    if not ok then out("UNIT_AURA " .. tostring(unit) .. " read ERROR " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Q9: addon messages in and out of combat (HealComm-style sharing between installs)
---------------------------------------------------------------------------

local function sendTestMessage(why)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
        out("ADDONMSG SendAddonMessage missing")
        return
    end
    local channel, target = "WHISPER", UnitName("player")
    if IsInRaid and IsInRaid() then channel, target = "RAID", nil
    elseif IsInGroup and IsInGroup() then channel, target = "PARTY", nil end
    local text = string.format("probe %s combat=%s t=%.1f", why, tostring(inCombat()), GetTime())
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, channel, target)
    out(string.format("ADDONMSG send %s via %s: %s", why, channel, ok and ("result=" .. probe(result)) or ("ERROR " .. tostring(result))))
end

---------------------------------------------------------------------------
-- Q10: the damage meter's healing totals after combat (learning tick sizes, and whether overheal is counted)
---------------------------------------------------------------------------

local function readableTable(v)
    if isSecret(v) or type(v) ~= "table" then return false end
    if type(canaccesstable) ~= "function" then return true end
    local ok, allowed = pcall(canaccesstable, v)
    return ok and allowed == true
end

local function describeRow(row)
    local parts = {}
    for k, v in pairs(row) do
        if type(v) ~= "table" then parts[#parts + 1] = tostring(k) .. "=" .. probe(v) end
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

local function meterTypes()
    local types = {}
    if Enum and type(Enum.DamageMeterType) == "table" then
        for name, value in pairs(Enum.DamageMeterType) do types[#types + 1] = { name = name, value = value } end
    end
    table.sort(types, function(a, b) return tostring(a.value) < tostring(b.value) end)
    return types
end

local function readMeter(triesLeft)
    local DM = C_DamageMeter
    if type(DM) ~= "table" or type(DM.GetCombatSessionSourceFromType) ~= "function" then
        out("METER no C_DamageMeter.GetCombatSessionSourceFromType")
        return
    end
    local current = Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current or 1
    local anyWaiting, lines = false, {}
    for _, t in ipairs(meterTypes()) do
        if t.name:find("Heal") or t.name:find("Absorb") then
            local ok, src = pcall(DM.GetCombatSessionSourceFromType, current, t.value, UnitGUID("player"))
            if not ok then
                lines[#lines + 1] = "METER " .. t.name .. " ERROR " .. tostring(src)
            elseif not readableTable(src) or not readableTable(src.combatSpells) then
                anyWaiting = true
                lines[#lines + 1] = "METER " .. t.name .. " source " .. (src == nil and "nil" or "unreadable")
            else
                lines[#lines + 1] = "METER " .. t.name .. " source: " .. describeRow(src)
                for i, sp in ipairs(src.combatSpells) do
                    if readableTable(sp) then
                        lines[#lines + 1] = string.format("  #%d %s %s", i, spellName(sp.spellID), describeRow(sp))
                    end
                end
            end
        end
    end
    if anyWaiting and triesLeft > 0 then
        C_Timer.After(METER_RETRY_SECONDS, function() readMeter(triesLeft - 1) end)
        return
    end
    for _, line in ipairs(lines) do out(line) end
end

---------------------------------------------------------------------------
-- Q11: the display geometry, on the player frame, the personal resource display (the bars under the character)
-- and the target frame while the target is friendly, and on friendly nameplates (/dil plates). /dil bar <amount>
--
-- Everything stays inside the health bar. Lua never compares health (secret, even out of combat); the widgets do:
--   effective heal (teal): a bar the host's size pinned to the end of the green, clipped to the host
--   overheal (pale blue strip along the bottom, so the green stays readable): a reverse-filled bar spans the last
--     <heal> of the host; where it overlaps the green, that healing has nowhere to go
--   tops off (plus): a fill of <heal> out of the missing health, which stops at its full width once heal >= missing;
--     only the last icon-width of that very long bar is visible (same trick as DoesItDie's skull)
---------------------------------------------------------------------------

local TOPS_OFF_BAR_LENGTH = 10000
local HOST_CHECK_SECONDS = 1
local FALLBACK_WIDTH, FALLBACK_HEIGHT = 124, 15 -- when a host's size can't be read
local MAX_LAYER_FRAMES = 300

local testAmount

-- A plain value from region:method(), or nil if it errors or is secret.
local function plain(region, method, ...)
    if type(region) ~= "table" or type(region[method]) ~= "function" then return nil end
    local ok, value = pcall(region[method], region, ...)
    if not ok or isSecret(value) then return nil end
    return value
end

local function plainSize(region, method)
    local value = plain(region, method)
    return type(value) == "number" and value > 0 and value or nil
end

-- Each finder returns: the health bar, the region its visible part is limited to, its mask (or nil), the path, and
-- the whole unit frame (to layer above).
local function findInContent(main, fallback, frameName, frame)
    local container = main and main.HealthBarsContainer
    if container and container.HealthBar then
        -- Forever's bar is 20 tall in a 15 tall container; a mask hides the rest.
        return container.HealthBar, container, container.HealthBarMask, frameName .. " HealthBarsContainer.HealthBar", frame
    end
    local bar = (main and main.HealthBar) or fallback
    if bar then return bar, bar, nil, frameName .. " (older layout)", frame end
end

local function findPlayerBar()
    local content = PlayerFrame and PlayerFrame.PlayerFrameContent
    return findInContent(content and content.PlayerFrameContentMain, PlayerFrameHealthBar, "PlayerFrame", PlayerFrame)
end

local function findTargetBar()
    local content = TargetFrame and TargetFrame.TargetFrameContent
    return findInContent(content and content.TargetFrameContentMain, TargetFrameHealthBar, "TargetFrame", TargetFrame)
end

local function findPersonalBar()
    local prd = PersonalResourceDisplayFrame
    local container = prd and prd.HealthBarsContainer
    local bar = (container and (container.healthBar or container.healthbar)) or (prd and prd.healthbar)
    if bar then return bar, bar, nil, "PersonalResourceDisplayFrame health bar", prd end
    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "player")
        local unitFrame = ok and type(plate) == "table" and plate.UnitFrame
        bar = unitFrame and (unitFrame.healthBar or unitFrame.HealthBar)
        if bar then return bar, bar, nil, "player nameplate UnitFrame.healthBar", plate end
    end
end

local function makeInvisibleBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0, 0, 0, 0)
    return bar, bar:GetStatusBarTexture()
end

-- parent: the nameplate, whose scale, fading and visibility the widget then follows; nil for the unit frames.
local function createWidget(name, unit, find, parent)
    local w = { name = name, unit = unit, find = find, plate = parent }

    w.root = CreateFrame("Frame", nil, parent or UIParent)
    w.root:Hide()
    w.clip = CreateFrame("Frame", nil, w.root) -- the host's visible area
    w.clip:SetClipsChildren(true)

    w.healBar, w.healFill = makeInvisibleBar(w.clip)
    w.healTex = w.healBar:CreateTexture(nil, "ARTWORK")
    w.healTex:SetColorTexture(0.3, 1, 0.8, 0.6)
    w.healTex:SetPoint("TOPLEFT", w.healFill, "TOPLEFT")
    w.healTex:SetPoint("BOTTOMRIGHT", w.healFill, "BOTTOMRIGHT")

    w.strip = CreateFrame("Frame", nil, w.clip) -- the bottom of the visible area, for the overheal
    w.strip:SetClipsChildren(true)
    w.overBar, w.overFill = makeInvisibleBar(w.strip)
    w.overBar:SetReverseFill(true)
    w.overClip = CreateFrame("Frame", nil, w.overBar)
    w.overClip:SetPoint("TOPLEFT", w.overFill, "TOPLEFT")
    w.overClip:SetPoint("BOTTOMRIGHT", w.overFill, "BOTTOMRIGHT")
    w.overClip:SetClipsChildren(true)
    w.overTex = w.overClip:CreateTexture(nil, "ARTWORK")
    w.overTex:SetColorTexture(0.65, 0.85, 1, 0.95)

    w.iconWindow = CreateFrame("Frame", nil, w.clip)
    w.iconWindow:SetClipsChildren(true)
    w.iconBar, w.iconFill = makeInvisibleBar(w.iconWindow)
    w.iconBar:SetPoint("RIGHT", w.iconWindow, "RIGHT")
    -- The plus: a dark cross behind a light one, centered half an icon left of the fill's end.
    w.plus = {}
    for i = 1, 4 do
        local texture = w.iconBar:CreateTexture(nil, "OVERLAY", nil, i <= 2 and 1 or 2)
        if i <= 2 then texture:SetColorTexture(0, 0.15, 0.1, 1) else texture:SetColorTexture(0.85, 1, 0.95, 1) end
        w.plus[i] = texture
    end
    -- Bottom to top. Levels are set one by one: siblings at equal depth would otherwise share a level, and the
    -- overheal drew over the plus.
    w.layers = { w.root, w.clip, w.healBar, w.strip, w.overBar, w.overClip, w.iconWindow, w.iconBar }
    return w
end

local widgets = {
    createWidget("player", "player", findPlayerBar),
    createWidget("personal", "player", findPersonalBar),
    createWidget("target", "target", findTargetBar),
}

local function sizeIcon(w, size)
    w.iconWindow:SetSize(size, size)
    w.iconBar:SetSize(TOPS_OFF_BAR_LENGTH, size)
    local long, thick = size - 4, math.max(2, math.floor(size / 5 + 0.5))
    local dims = { { long + 2, thick + 2 }, { thick + 2, long + 2 }, { long, thick }, { thick, long } }
    for i, texture in ipairs(w.plus) do
        texture:SetSize(dims[i][1], dims[i][2])
        texture:ClearAllPoints()
        texture:SetPoint("CENTER", w.iconFill, "RIGHT", -size / 2, 0)
    end
end

local STRATA_RANK = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

-- The highest strata and level anywhere in a unit frame (DoesItDie's way). The health bar's own level isn't enough:
-- it can be secret, Edit Mode re-layers the frames after addons load, and a click raises them.
local function topLayer(frame)
    local topStrata, topRank, level, visited, unreadable = "BACKGROUND", 1, 0, 0, 0
    local function visit(f, depth)
        visited = visited + 1
        if visited > MAX_LAYER_FRAMES then return end
        local s, l = plain(f, "GetFrameStrata"), plain(f, "GetFrameLevel")
        if STRATA_RANK[s or ""] and type(l) == "number" then
            local rank = STRATA_RANK[s]
            if rank > topRank then
                topStrata, topRank, level = s, rank, l
            elseif rank == topRank and l > level then
                level = l
            end
        else
            unreadable = unreadable + 1
        end
        if depth < 6 and type(f.GetChildren) == "function" then
            local children = { pcall(f.GetChildren, f) } -- [1] is whether it worked
            for i = 2, children[1] and #children or 1 do
                if visited > MAX_LAYER_FRAMES then break end
                -- One frame that can't be walked mustn't lose the rest.
                if type(children[i]) == "table" then pcall(visit, children[i], depth + 1) end
            end
        end
    end
    visit(frame, 0)
    return topStrata, level, visited, unreadable
end

local function updateLayer(w, frame)
    local ok, err = pcall(function()
        if w.plate then -- as in DoesItDie: the plate's strata, above its health bar
            local strata, level = plain(w.plate, "GetFrameStrata"), plain(w.bar, "GetFrameLevel")
            for i, layer in ipairs(w.layers) do
                if strata then layer:SetFrameStrata(strata) end
                if type(level) == "number" then layer:SetFrameLevel(math.min(level + 20 + i, 9999)) end
            end
            return
        end
        local strata, level, visited, unreadable = topLayer(frame)
        -- Being above the frame's own tree isn't enough: at LOW/1001, above every (readable) frame in PlayerFrame,
        -- the bar didn't show in-game (why is unknown); at MEDIUM it does. Never go below MEDIUM/1001.
        local found = strata .. "/" .. level
        if STRATA_RANK[strata] < STRATA_RANK.MEDIUM then
            strata, level = "MEDIUM", 1001
        elseif strata == "MEDIUM" then
            level = math.max(level, 1001)
        end
        level = math.min(level, 9900)
        for i, layer in ipairs(w.layers) do
            layer:SetFrameStrata(strata)
            layer:SetFrameLevel(level + i)
        end
        local signature = strata .. "/" .. level
        if signature ~= w.layerSignature then
            w.layerSignature = signature
            out(string.format("BAR %s layer: above %s (found %s, %d frames, %d unreadable; the bar itself: %s/%s)", w.name,
                signature, found, visited, unreadable, tostring(plain(w.bar, "GetFrameStrata") or "unreadable"),
                tostring(plain(w.bar, "GetFrameLevel") or "unreadable")))
        end
    end)
    if not ok and not w.layerErrorLogged then
        w.layerErrorLogged = true
        out("BAR " .. w.name .. " layer ERROR " .. tostring(err), true)
    end
end

-- Lays the widget over its host. Runs again whenever the host or its size or scale changes.
local function attach(w, bar, area, mask, path)
    local readWidth, readHeight = plainSize(bar, "GetWidth"), plainSize(bar, "GetHeight")
    local width = readWidth or w.lastWidth or FALLBACK_WIDTH
    local height = readHeight or w.lastHeight or FALLBACK_HEIGHT
    w.lastWidth, w.lastHeight = width, height
    local areaHeight = plainSize(area, "GetHeight") or height
    local stripHeight = math.max(3, math.floor(areaHeight * 0.3 + 0.5))
    local scale = plainSize(bar, "GetEffectiveScale") or 1
    local uiScale = plainSize(w.plate or UIParent, "GetEffectiveScale") or 1
    local signature = table.concat({ path, width, height, areaHeight, scale, uiScale }, "|")
    if w.bar == bar and w.signature == signature then return true end
    local ok, err = pcall(function()
        local green = bar:GetStatusBarTexture()
        w.root:SetScale(scale / uiScale) -- the host's units (the personal bars have their own size setting)
        w.root:ClearAllPoints()
        w.root:SetAllPoints(area)
        w.clip:ClearAllPoints()
        w.clip:SetAllPoints(area)

        w.healBar:ClearAllPoints()
        w.healBar:SetPoint("TOPLEFT", green, "TOPRIGHT")
        w.healBar:SetPoint("BOTTOMLEFT", green, "BOTTOMRIGHT")
        w.healBar:SetWidth(width)

        w.strip:ClearAllPoints()
        w.strip:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT")
        w.strip:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT")
        w.strip:SetHeight(stripHeight + (mask and 1 or 0)) -- the mask hides about the bottom pixel
        w.overBar:ClearAllPoints()
        w.overBar:SetAllPoints(bar)
        w.overTex:ClearAllPoints()
        w.overTex:SetPoint("TOPLEFT", bar, "TOPLEFT")
        w.overTex:SetPoint("BOTTOMRIGHT", green, "BOTTOMRIGHT")

        w.iconWindow:ClearAllPoints()
        w.iconWindow:SetPoint("RIGHT", area, "RIGHT", -1, 0)
        sizeIcon(w, math.max(8, math.floor(math.min(areaHeight, 18))))
    end)
    if ok and w.mask ~= mask then
        local maskOK, maskErr = pcall(function()
            for _, texture in ipairs({ w.healTex, w.overTex }) do
                if w.mask then texture:RemoveMaskTexture(w.mask) end
                if mask then texture:AddMaskTexture(mask) end
            end
        end)
        w.mask = mask
        if not maskOK then out("BAR " .. w.name .. " mask ERROR " .. tostring(maskErr), true) end
    end
    w.bar, w.area, w.signature = bar, area, signature
    if w.quiet and ok then return ok end
    out(string.format("BAR attach %s to %s %.1fx%.1f (size read %s, visible height %.1f, scale %.2f, mask %s): %s", w.name,
        path, width, height, readWidth and readHeight and "yes" or "NO", areaHeight, scale, mask and "yes" or "no",
        ok and "ok" or ("ERROR " .. tostring(err))), not ok)
    return ok
end

local function childKeys(frame)
    local keys = {}
    for k, v in pairs(frame) do
        if type(k) == "string" and type(v) == "table" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return table.concat(keys, ",")
end

local function logNotFound(w)
    if w.missingLogged then return end
    w.missingLogged = true
    local detail = ""
    if w.name == "personal" then
        pcall(function()
            if PersonalResourceDisplayFrame then
                detail = " PersonalResourceDisplayFrame keys: " .. childKeys(PersonalResourceDisplayFrame)
            end
        end)
    end
    out("BAR " .. w.name .. " health bar not found." .. detail, true)
end

local function checkHost(w)
    local ok, bar, area, mask, path, frame = pcall(w.find)
    if not ok or not bar then
        w.attached = false
        if not w.quiet then logNotFound(w) end
        return
    end
    w.attached = attach(w, bar, area, mask, path)
    updateLayer(w, frame or bar)
end

-- Only units you can assist: enemies are DoesItDie's.
local function canShow(unit)
    if unit == nil then return false end
    if unit == "player" then return true end
    local ok, assist = pcall(UnitCanAssist, "player", unit)
    return ok and not isSecret(assist) and assist == true
end

-- Why a bar isn't showing goes to the log, once per change.
local function setState(w, state)
    if w.state == state then return end
    w.state = state
    if w.quiet then return end
    out("BAR " .. w.name .. " state: " .. state)
end

local function describeRegion(region)
    local ok, left, bottom, width, height = pcall(region.GetRect, region)
    local rect = "no rect"
    if ok and left ~= nil then
        rect = string.format("%s,%s %sx%s", probe(left), probe(bottom), probe(width), probe(height))
    end
    return string.format("rect %s visible=%s alpha=%s layer=%s/%s", rect,
        tostring(plain(region, "IsVisible")), tostring(plain(region, "GetEffectiveAlpha") or "unreadable"),
        tostring(plain(region, "GetFrameStrata") or "unreadable"), tostring(plain(region, "GetFrameLevel") or "unreadable"))
end

-- Where everything really ended up, a second after a bar starts showing (an empty bar can be hidden, underneath,
-- elsewhere or clipped away, and these tell which).
local function logPlacement(w)
    C_Timer.After(1, function()
        if not testAmount or w.state ~= "shown" then return end
        pcall(function()
            for _, entry in ipairs({ { "host", w.bar }, { "area", w.area }, { "root", w.root }, { "clip", w.clip },
                { "strip", w.strip }, { "overClip", w.overClip }, { "iconWindow", w.iconWindow }, { "iconBar", w.iconBar } }) do
                out("BAR " .. w.name .. " " .. entry[1] .. ": " .. describeRegion(entry[2]))
            end
        end)
    end)
end

local function updateWidget(w)
    local hidden = not w.attached and "hidden, not attached"
        or not canShow(w.unit) and "hidden, unit not friendly"
        or plain(w.bar, "IsVisible") == false and "hidden, its health bar isn't visible"
    if hidden then
        w.root:Hide()
        setState(w, hidden)
        return
    end
    local ok, err = pcall(function()
        local maxHealth = UnitHealthMax(w.unit)
        w.healBar:SetMinMaxValues(0, maxHealth)
        w.healBar:SetValue(testAmount)
        w.overBar:SetMinMaxValues(0, maxHealth)
        w.overBar:SetValue(testAmount)
        -- From -1, so full health (nothing missing) is still a range to fill, and counts as topped off.
        w.iconBar:SetMinMaxValues(-1, UnitHealthMissing(w.unit))
        w.iconBar:SetValue(testAmount)
        if not w.plate then w.root:SetAlpha(plain(w.bar, "GetEffectiveAlpha") or 1) end
    end)
    w.root:SetShown(ok)
    if ok and w.state ~= "shown" then logPlacement(w) end
    setState(w, ok and "shown" or "hidden, update failed")
    if not ok and not w.errorLogged then
        w.errorLogged = true
        out("BAR update " .. w.name .. " ERROR " .. tostring(err), true)
    end
end

-- Friendly nameplates: one widget per plate frame (Blizzard reuses the frames for other units).
local MAX_PLATE_LOG_LINES = 60
local plateWidgets = setmetatable({}, { __mode = "k" }) -- plate frame -> widget
local activePlates = {} -- nameplate unit -> widget
local plateLogLines, platePlacementLogged = 0, false

local function platesWanted()
    return testAmount ~= nil and not (db and db.plates == false)
end

local function plateHealthBar(plate)
    local unitFrame = plate.UnitFrame
    if type(unitFrame) ~= "table" then return nil, "no UnitFrame" end
    local container = unitFrame.HealthBarsContainer
    if unitFrame.healthBar then return unitFrame.healthBar, "UnitFrame.healthBar" end
    if container and container.healthBar then return container.healthBar, "UnitFrame.HealthBarsContainer.healthBar" end
    if unitFrame.HealthBar then return unitFrame.HealthBar, "UnitFrame.HealthBar" end
    return nil, "no health bar in UnitFrame"
end

local function isForbidden(frame)
    local ok, forbidden = pcall(function() return frame.IsForbidden and frame:IsForbidden() end)
    return not ok or (isSecret(forbidden) or forbidden == true)
end

local function logPlate(unit, what)
    plateLogLines = plateLogLines + 1
    if plateLogLines > MAX_PLATE_LOG_LINES then return end
    local inInstance, instanceType = "?", "?"
    if IsInInstance then
        local ok, a, b = pcall(IsInInstance)
        if ok then inInstance, instanceType = probe(a), probe(b) end
    end
    out(string.format("PLATE %s %s assist=%s instance=%s (%s) combat=%s", tostring(unit), what,
        call("UnitCanAssist", "player", unit), inInstance, instanceType, tostring(inCombat())))
end

local function releasePlate(unit)
    local w = activePlates[unit]
    if not w then return end
    activePlates[unit] = nil
    w.unit, w.state = nil, nil
    w.root:Hide()
end

local function addPlate(unit)
    if not platesWanted() or type(unit) ~= "string" then return end
    releasePlate(unit)
    local okSelf, isSelf = pcall(UnitIsUnit, unit, "player")
    if okSelf and not isSecret(isSelf) and isSelf == true then return end -- the personal bars are drawn already
    if not canShow(unit) then return end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or type(plate) ~= "table" then
        -- In instances the client may keep friendly plates from addons entirely.
        local okAll, hiddenPlate = pcall(C_NamePlate.GetNamePlateForUnit, unit, true)
        logPlate(unit, "plate not reachable" .. (okAll and type(hiddenPlate) == "table" and " (forbidden)" or ""))
        return
    end
    if isForbidden(plate) then
        logPlate(unit, "plate forbidden")
        return
    end
    local okBar, bar, path = pcall(plateHealthBar, plate)
    if not okBar or not bar or isForbidden(bar) then
        logPlate(unit, "plate ok, bar not reachable: " .. tostring(okBar and path or bar))
        return
    end
    local w = plateWidgets[plate]
    if not w then
        local created
        created, w = pcall(createWidget, "plate", unit, nil, plate)
        if not created then
            logPlate(unit, "widget ERROR " .. tostring(w))
            return
        end
        w.quiet = true
        w.find = function()
            local found, foundPath = plateHealthBar(plate)
            return found, found, nil, foundPath, plate
        end
        plateWidgets[plate] = w
    end
    w.unit, w.errorLogged, w.layerErrorLogged = unit, false, false
    activePlates[unit] = w
    checkHost(w)
    if not platePlacementLogged then
        platePlacementLogged = true
        w.quiet = false -- the first plate's placement is logged in full
        updateWidget(w)
        w.quiet = true
    else
        w.state = "shown" -- skips the placement log
        updateWidget(w)
    end
    logPlate(unit, string.format("plate ok, bar %s visible=%s drawn=%s", path, tostring(plain(bar, "IsVisible")),
        tostring(w.state)))
end

local function refreshPlates()
    for unit in pairs(activePlates) do releasePlate(unit) end
    if not platesWanted() then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then
        out("PLATE C_NamePlate.GetNamePlateForUnit missing", true)
        return
    end
    for i = 1, 40 do
        if UnitExists("nameplate" .. i) then addPlate("nameplate" .. i) end
    end
end

local driver = CreateFrame("Frame")
driver:Hide()
local sinceUpdate, sinceCheck = 0, 0
driver:SetScript("OnUpdate", function(_, elapsed)
    if not testAmount then return end
    sinceUpdate, sinceCheck = sinceUpdate + elapsed, sinceCheck + elapsed
    if sinceUpdate < 0.1 then return end
    sinceUpdate = 0
    local check = sinceCheck >= HOST_CHECK_SECONDS
    if check then sinceCheck = 0 end
    for _, w in ipairs(widgets) do
        if check then checkHost(w) end
        updateWidget(w)
    end
    for _, w in pairs(activePlates) do
        if check then checkHost(w) end
        updateWidget(w)
    end
end)

local function onTargetChanged()
    if not testAmount then return end
    for _, w in ipairs(widgets) do
        if w.unit == "target" then
            checkHost(w)
            updateWidget(w)
        end
    end
end

local function setTestBar(amount)
    if amount and amount <= 0 then amount = nil end
    testAmount = amount
    driver:SetShown(amount ~= nil)
    for _, w in ipairs(widgets) do
        w.errorLogged, w.missingLogged, w.layerErrorLogged, w.state, w.layerSignature = false, false, false, nil, nil
        if amount then
            checkHost(w)
            updateWidget(w)
        else
            w.root:Hide()
        end
    end
    plateLogLines, platePlacementLogged = 0, false
    refreshPlates()
    if amount then
        out(string.format("Test heal bar: a fixed %d healing on your player frame, personal resource bar, friendly target and friendly nameplates (not your real HoTs yet). Teal = will heal, pale blue strip = overheal, plus = tops off. /dil bar to hide.", amount), true)
    else
        out("Test heal bar hidden.", true)
    end
end

local function togglePlates()
    if not db then return end
    db.plates = db.plates == false
    out("Test heal bar on friendly nameplates " .. (db.plates and "ON" or "OFF") .. ".", true)
    refreshPlates()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local f = CreateFrame("Frame")
local registrations = {}
for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGOUT", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
    "UNIT_COMBAT", "UNIT_HEALTH", "UNIT_AURA", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED",
    "CHAT_MSG_ADDON", "PLAYER_TARGET_CHANGED", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
}) do
    local ok, err = pcall(f.RegisterEvent, f, event)
    registrations[#registrations + 1] = event .. "=" .. (ok and "ok" or ("ERROR " .. tostring(err)))
end

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        DoesItLiveDB = DoesItLiveDB or {}
        db = DoesItLiveDB
        log = db.log or log
        db.log = log
        echo = db.echo or false
        out("Loaded (probe v4). Type /dil for help.", true)
        out("Event registrations: " .. table.concat(registrations, " "))
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            out("ADDONMSG register prefix: " .. probe(select(2, pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX))))
        end

    elseif event == "PLAYER_LOGOUT" then
        if db then db.log = log end

    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        local addon, func = ...
        out(string.format("%s addon=%s function=%s", event, tostring(addon), tostring(func)), true)

    elseif event == "PLAYER_REGEN_DISABLED" then
        wipe(fightCounts)
        out("Entered combat. Auto-snapshot and addon message test in " .. AUTO_SNAPSHOT_DELAY .. "s.")
        C_Timer.After(AUTO_SNAPSHOT_DELAY, function()
            snapshot("auto, in combat")
            sendTestMessage("in combat")
        end)

    elseif event == "PLAYER_REGEN_ENABLED" then
        wipe(fightCounts)
        out("Left combat. Reading the damage meter's healing totals.")
        C_Timer.After(METER_RETRY_SECONDS, function() readMeter(METER_TRIES) end)
        C_Timer.After(2, function() snapshot("auto, after combat") end)

    elseif event == "UNIT_COMBAT" then
        onUnitCombat(...)

    elseif event == "UNIT_HEALTH" then
        onUnitHealth((...))

    elseif event == "UNIT_AURA" then
        onUnitAura(...)

    elseif event == "UNIT_SPELLCAST_SENT" then
        local unit, target, castGUID = ...
        if unit == "player" and castGUID and not isSecret(castGUID) then sentTarget[castGUID] = target end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" then
            onOwnCast(castGUID, spellID)
        elseif type(unit) == "string" and (unit:find("^party") or unit:find("^raid")) then
            onOtherCast(unit, spellID)
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        onTargetChanged()

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        addPlate((...))

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        releasePlate((...))

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, channel, sender = ...
        if isSecret(prefix) or prefix ~= PREFIX then return end
        out(string.format("ADDONMSG received via %s from %s: %s (combat=%s)", probe(channel), probe(sender),
            probe(text), tostring(inCombat())))
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_DOESITLIVE1 = "/dil"
SLASH_DOESITLIVE2 = "/doesitlive"
SlashCmdList.DOESITLIVE = function(msg)
    msg = strlower(strtrim(msg or ""))
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if cmd == "probe" then
        snapshot("manual")
    elseif cmd == "bar" then
        setTestBar(tonumber(arg))
    elseif cmd == "plates" then
        togglePlates()
    elseif cmd == "msg" then
        sendTestMessage("manual")
    elseif cmd == "meter" then
        readMeter(0)
    elseif cmd == "echo" then
        echo = not echo
        if db then db.echo = echo end
        out("Echo to chat " .. (echo and "ON" or "OFF") .. ".", true)
    elseif cmd == "clear" then
        wipe(log)
        out("Log cleared.", true)
    else
        out("DoesItLive probe. Everything is logged to SavedVariables\\DoesItLive.lua on /reload or logout.", true)
        out("/dil probe - snapshot of health, heal prediction and auras on you, your target and party", true)
        out("/dil bar <n> - test heal bar with n healing on you, a friendly target and friendly nameplates (/dil bar to hide)", true)
        out("/dil plates - turn the test heal bar on friendly nameplates on or off", true)
        out("/dil msg - send a test addon message; /dil meter - read the damage meter's healing now", true)
        out("/dil echo - also print every log line to chat; /dil clear - clear the log", true)
    end
end
