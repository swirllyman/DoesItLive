-- DoesItLive tracking: which of your HoTs are on whom, and how much healing each still has to do.
--
-- Heal amounts and predicted heals are secret even out of combat, so HoTs are estimated:
--   * which HoT, on whom, when: your own casts (UNIT_SPELLCAST_SENT names the target, SUCCEEDED confirms the cast)
--   * how much: the spell's tooltip. It already includes bonus healing (checked against the damage meter on
--     2026-11-22: Rejuvenation 214 in the tooltip, 215 healed; Regrowth 313-352 + 300, 624 healed)
--   * when it ticks: every 3 seconds from the cast (Rejuvenation and Regrowth seen in the log; Renew and Riptide
--     assumed). Crits aren't counted.
--   * corrections: out of combat your auras are readable, so a HoT that's gone is dropped, one that's there with
--     another expiration is moved, and one that was missed (a /reload) is picked up. In combat none of that can be
--     read: a HoT dispelled or cancelled then stays until it would have expired.
-- Loaded after Probe.lua (logging and helpers).

local _, ns = ...

local isSecret, probe, out = ns.isSecret, ns.probe, ns.out

local tracking = {}
ns.tracking = tracking

-- By English spell name; ticks every `interval` seconds.
local HOTS = {
    ["Rejuvenation"] = { interval = 3 },
    ["Regrowth"] = { interval = 3 },
    ["Renew"] = { interval = 3 },
    ["Riptide"] = { interval = 3 },
}
-- Known HoTs left out for now: uneven ticks, on the whole party.
local UNTRACKED = { ["Wild Growth"] = true }
-- Swiftmend uses up one of these on its target. (Unverified on Forever.)
local SWIFTMEND_USES = { ["Rejuvenation"] = true, ["Regrowth"] = true }

local SENT_SECONDS = 15        -- how long a sent cast waits for its SUCCEEDED
local AURA_GRACE_SECONDS = 1.5 -- a new HoT's aura may show up this much later than its cast
local EXPIRY_TOLERANCE = 0.5   -- an aura's expiration this far off moves the HoT
local MAX_AURAS = 40

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------

-- The over-time part of a HoT's tooltip: total healing and seconds, or nil. Direct heals before it are left out
-- ("Heals a friendly target for 965 to 1077 and another 994 over 21 sec."). Renew's says "830 damage over 15 sec".
function tracking.parseHot(desc)
    if type(desc) ~= "string" or isSecret(desc) then return nil end
    for _ = 1, 2 do desc = desc:gsub("(%d),(%d%d%d)%f[^%d]", "%1%2") end
    local total, seconds = desc:match("(%d+)%s+over%s+(%d+%.?%d*)%s+sec")
    if not total then total, seconds = desc:match("(%d+)%s+%a+%s+over%s+(%d+%.?%d*)%s+sec") end
    total, seconds = tonumber(total), tonumber(seconds)
    if not total or not seconds or total <= 0 or seconds <= 0 then return nil end
    return total, seconds
end

local function spellInfo(spellID)
    if isSecret(spellID) or type(spellID) ~= "number" then return nil end
    local okName, name = pcall(function()
        if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellID) end
        return (GetSpellInfo(spellID))
    end)
    local okDesc, desc = pcall(function()
        return ((C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription)(spellID)
    end)
    if not okName or isSecret(name) or type(name) ~= "string" then return nil end
    if not okDesc or isSecret(desc) then desc = nil end
    return name, desc
end

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------

local function plainCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    if isSecret(a) then a = nil end
    if isSecret(b) then b = nil end
    return a, b
end

-- Names this unit may go by. Forever has surnames: UnitName gives "Joe", "Gg" where the cast says "Joe Gg".
local function namesOf(unit)
    local first, second = plainCall(UnitName, unit)
    if type(first) ~= "string" or first == "" then return nil end
    if type(second) ~= "string" or second == "" then return first end
    return first .. " " .. second, first .. "-" .. second, first
end

-- The short name alone only matches when the unit has no second name: "Joe" mustn't match "Joe Gg".
local function unitHasName(unit, name)
    local full, dashed = namesOf(unit)
    return full ~= nil and (full == name or dashed == name)
end

local function allUnits()
    local units = { "player", "target", "focus", "mouseover", "softfriend", "pet" }
    for i = 1, 4 do
        units[#units + 1] = "party" .. i
        units[#units + 1] = "partypet" .. i
    end
    if IsInRaid and plainCall(IsInRaid) then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    end
    for i = 1, 40 do units[#units + 1] = "nameplate" .. i end
    return units
end

local function canAssist(unit)
    return plainCall(UnitCanAssist, "player", unit) == true
end

local function findUnit(name)
    if type(name) ~= "string" or isSecret(name) or name == "" then return nil end
    for _, unit in ipairs(allUnits()) do
        if plainCall(UnitExists, unit) and unitHasName(unit, name) and canAssist(unit) then return unit end
    end
end
tracking.findUnit = findUnit

-- What a unit's HoTs are kept under: its GUID, else its name.
local function keysOf(unit)
    if not plainCall(UnitExists, unit) then return nil end
    local guid = plainCall(UnitGUID, unit)
    local full = namesOf(unit)
    return type(guid) == "string" and guid or nil, full and ("name:" .. full) or nil
end

---------------------------------------------------------------------------
-- HoTs
---------------------------------------------------------------------------

local hotsByKey = {} -- key -> { spell name -> hot }
local hotCount = 0

local function remainingTicks(hot, now)
    local left = 0
    for tick = 1, hot.ticks do
        if hot.start + tick * hot.interval > now then left = left + 1 end
    end
    return left
end

local function remainingOf(hot, now)
    return remainingTicks(hot, now) * hot.perTick
end

local function drop(key, name, why)
    local hots = hotsByKey[key]
    local hot = hots and hots[name]
    if not hot then return end
    hots[name] = nil
    if next(hots) == nil then hotsByKey[key] = nil end
    hotCount = hotCount - 1
    out(string.format("DROP %s on %s: %s (%d left by the estimate)", name, hot.who, why, remainingOf(hot, GetTime())))
end

local function put(key, name, hot)
    hotsByKey[key] = hotsByKey[key] or {}
    if not hotsByKey[key][name] then hotCount = hotCount + 1 end
    hotsByKey[key][name] = hot
end

-- A HoT's numbers, or nil (why it can't be tracked, for the log).
local function newHot(spellID, name, desc, who)
    local total, seconds = tracking.parseHot(desc)
    if not total then return nil end
    local interval = HOTS[name].interval
    local ticks = math.max(1, math.floor(seconds / interval + 0.5))
    return { spellID = spellID, name = name, who = who, total = total, duration = seconds, interval = interval,
        ticks = ticks, perTick = total / ticks, start = GetTime(), castAt = GetTime() }
end

function tracking.any()
    return hotCount > 0
end

-- Healing your HoTs still have to do on this unit (0 if none), and per HoT: { { name, amount }, ... } in a fixed
-- spell order (so per-HoT colors don't swap places). shown(spell name), if given, leaves out the HoTs it says no to
-- (turned off in the options).
local SPELL_ORDER = { Rejuvenation = 1, Regrowth = 2, Renew = 3, Riptide = 4 }

function tracking.breakdown(unit, shown)
    if hotCount == 0 then return 0, nil end
    local guidKey, nameKey = keysOf(unit)
    local now, sum, parts = GetTime(), 0, nil
    for _, key in ipairs({ guidKey or false, nameKey or false }) do
        for name, hot in pairs(key and hotsByKey[key] or {}) do
            if not shown or shown(name) then
                local amount = remainingOf(hot, now)
                if amount > 0 then
                    sum = sum + amount
                    parts = parts or {}
                    parts[#parts + 1] = { name = name, amount = amount }
                end
            end
        end
    end
    if parts then
        table.sort(parts, function(a, b) return (SPELL_ORDER[a.name] or 9) < (SPELL_ORDER[b.name] or 9) end)
    end
    return sum, parts
end

function tracking.remaining(unit, shown)
    return (tracking.breakdown(unit, shown))
end

function tracking.list()
    local lines, now = {}, GetTime()
    for _, hots in pairs(hotsByKey) do
        for name, hot in pairs(hots) do
            lines[#lines + 1] = string.format("%s on %s: %d left (%d of %d ticks of %.1f), %.1fs", name, hot.who,
                remainingOf(hot, now), remainingTicks(hot, now), hot.ticks, hot.perTick, hot.start + hot.duration - now)
        end
    end
    table.sort(lines)
    return lines
end

---------------------------------------------------------------------------
-- Casts
---------------------------------------------------------------------------

local sentCasts = {} -- cast GUID -> { guidKey, nameKey, who, how, at }

-- Who a cast goes to, decided when it's sent (the target can change before it lands).
local function castTarget(name)
    local unit, how
    if isSecret(name) then
        -- The name can't be read: a friendly target takes it, else it's a self-cast.
        unit = canAssist("target") and "target" or "player"
        how = "secret name, guessed"
    elseif type(name) ~= "string" or name == "" then
        unit, how = "player", "no name"
    else
        unit = findUnit(name)
        how = unit or "no unit with that name"
    end
    local guidKey, nameKey, who
    if unit then
        guidKey, nameKey = keysOf(unit)
        who = namesOf(unit) or unit
    else
        nameKey, who = "name:" .. name, name
    end
    return { guidKey = guidKey, nameKey = nameKey, who = who, how = how, at = GetTime() }
end

function tracking.onCastSent(name, castGUID, spellID)
    if not castGUID or isSecret(castGUID) then return end
    local now = GetTime()
    for guid, sent in pairs(sentCasts) do
        if now - sent.at > SENT_SECONDS then sentCasts[guid] = nil end
    end
    local spell = spellInfo(spellID)
    if not spell or not (HOTS[spell] or spell == "Swiftmend") then return end
    sentCasts[castGUID] = castTarget(name)
end

local function onSwiftmend(sent)
    local now, key, best = GetTime(), nil, nil
    for _, candidate in ipairs({ sent.guidKey or false, sent.nameKey or false }) do
        for name, hot in pairs(candidate and hotsByKey[candidate] or {}) do
            if SWIFTMEND_USES[name] and (not best or hot.start + hot.duration < best.start + best.duration) then
                key, best = candidate, hot
            end
        end
    end
    if best then
        drop(key, best.name, "used by Swiftmend")
    else
        out("CAST Swiftmend on " .. sent.who .. ": no HoT known there at " .. string.format("%.1f", now))
    end
end

function tracking.onCastSucceeded(castGUID, spellID)
    local spell, desc = spellInfo(spellID)
    if not spell then return end
    local sent = castGUID and not isSecret(castGUID) and sentCasts[castGUID] or nil
    if sent then sentCasts[castGUID] = nil end
    if spell == "Swiftmend" then
        onSwiftmend(sent or castTarget(nil))
        return
    end
    if not HOTS[spell] then
        local total, seconds = tracking.parseHot(desc)
        if UNTRACKED[spell] or (total and desc:find("[Hh]eal")) then
            out(string.format("HOT not tracked: %s id=%s (%s over %s sec): %s", spell, probe(spellID), tostring(total),
                tostring(seconds), desc or "no description"))
        end
        return
    end
    sent = sent or castTarget(nil)
    local hot = newHot(spellID, spell, desc, sent.who)
    if not hot then
        out("HOT " .. spell .. ": no over-time amount in its description: " .. tostring(desc))
        return
    end
    local key = sent.guidKey or sent.nameKey
    if not key then
        out("HOT " .. spell .. ": nothing to keep its target under (" .. sent.how .. ")")
        return
    end
    -- A recast replaces it, wherever the old one is kept.
    local recast = false
    for _, old in ipairs({ sent.guidKey or false, sent.nameKey or false }) do
        if old and hotsByKey[old] and hotsByKey[old][spell] then
            recast = true
            drop(old, spell, "recast")
        end
    end
    put(key, spell, hot)
    out(string.format("ESTIMATE %s on %s (%s)%s: %d over %.0fs, %d ticks of %.1f every %ds%s", spell, sent.who, sent.how,
        recast and " recast" or "", hot.total, hot.duration, hot.ticks, hot.perTick, hot.interval,
        sent.guidKey and "" or " (kept by name)"))
    if ns.display then ns.display.refresh() end
end

---------------------------------------------------------------------------
-- Corrections
---------------------------------------------------------------------------

-- Your HoTs among the unit's auras: spell name -> { spellID, duration, expiration }. Nil when they can't be trusted
-- (combat, secret, or a unit too far away to be told about).
local function readAuras(unit)
    if ns.inCombat() or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    if C_Secrets and plainCall(C_Secrets.ShouldAurasBeSecret) ~= false then return nil end
    if unit ~= "player" and plainCall(UnitIsVisible, unit) ~= true then return nil end
    local found = {}
    for i = 1, MAX_AURAS do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL|PLAYER")
        if not ok or isSecret(aura) then return nil end
        if aura == nil then return found end
        local name, id, duration, expiration = aura.name, aura.spellId, aura.duration, aura.expirationTime
        if isSecret(name) or isSecret(id) or isSecret(duration) or isSecret(expiration) then return nil end
        if type(name) == "string" and HOTS[name] then
            found[name] = { spellID = id, duration = duration, expiration = expiration }
        end
    end
    return found
end

-- Compares what's tracked on a unit with its auras, when they're readable.
function tracking.checkUnit(unit)
    if not canAssist(unit) then return end
    local guidKey, nameKey = keysOf(unit)
    if not guidKey and not nameKey then return end
    local now, changed = GetTime(), false
    if plainCall(UnitIsDeadOrGhost, unit) == true then
        for _, key in ipairs({ guidKey or false, nameKey or false }) do
            local names = {}
            for name in pairs(key and hotsByKey[key] or {}) do names[#names + 1] = name end
            for _, name in ipairs(names) do drop(key, name, "died") changed = true end
        end
        if changed and ns.display then ns.display.refresh() end
        return
    end
    local auras = readAuras(unit)
    if not auras then return end
    local known = {}
    for _, key in ipairs({ guidKey or false, nameKey or false }) do
        local names = {}
        for name in pairs(key and hotsByKey[key] or {}) do names[#names + 1] = name end
        for _, name in ipairs(names) do
            local hot, aura = hotsByKey[key][name], auras[name]
            if aura then
                known[name] = true
                local expiration, duration = aura.expiration, aura.duration
                if type(expiration) == "number" and expiration > 0 and type(duration) == "number" and duration > 0 then
                    local off = expiration - (hot.start + hot.duration)
                    -- Right after a recast the aura may still be the old one, ending sooner.
                    local stale = off < 0 and now - hot.castAt < AURA_GRACE_SECONDS
                    if math.abs(off) > EXPIRY_TOLERANCE and not stale then
                        if math.abs(duration - hot.duration) > EXPIRY_TOLERANCE then
                            hot.ticks = math.max(1, math.floor(duration / hot.interval + 0.5))
                            hot.duration = duration -- more time is more ticks, of the same size
                        end
                        hot.start = expiration - duration
                        changed = true
                        out(string.format("MOVE %s on %s: its aura ends %+.1fs from the estimate", name, hot.who, off))
                    end
                end
            elseif now - hot.start > AURA_GRACE_SECONDS then
                drop(key, name, "its aura is gone")
                changed = true
            end
        end
    end
    for name, aura in pairs(auras) do
        if not known[name] and type(aura.expiration) == "number" and aura.expiration > now
            and type(aura.duration) == "number" and aura.duration > 0 then
            local _, desc = spellInfo(aura.spellID)
            local hot = newHot(aura.spellID, name, desc, namesOf(unit) or unit)
            if hot then
                if math.abs(aura.duration - hot.duration) > EXPIRY_TOLERANCE then
                    hot.ticks = math.max(1, math.floor(aura.duration / hot.interval + 0.5))
                    hot.duration = aura.duration
                end
                hot.start = aura.expiration - aura.duration
                put(guidKey or nameKey, name, hot)
                changed = true
                out(string.format("FOUND %s on %s from its aura: %d left", name, hot.who, remainingOf(hot, now)))
            end
        end
    end
    if changed and ns.display then ns.display.refresh() end
end

-- Once a second: drop what ran out, and check the units we can see.
function tracking.housekeep()
    local now = GetTime()
    local expired = {}
    for key, hots in pairs(hotsByKey) do
        for name, hot in pairs(hots) do
            if now >= hot.start + hot.duration + 0.2 then expired[#expired + 1] = { key, name } end
        end
    end
    for _, entry in ipairs(expired) do drop(entry[1], entry[2], "ran out") end
    if hotCount == 0 then return end
    local seen = {}
    for _, unit in ipairs(allUnits()) do
        local guidKey, nameKey = keysOf(unit)
        if (guidKey and hotsByKey[guidKey]) or (nameKey and hotsByKey[nameKey]) then
            local id = guidKey or nameKey
            if not seen[id] then
                seen[id] = true
                tracking.checkUnit(unit)
            end
        end
    end
end

local ticker = CreateFrame("Frame")
local sinceHousekeep = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    if hotCount == 0 then return end
    sinceHousekeep = sinceHousekeep + elapsed
    if sinceHousekeep < 1 then return end
    sinceHousekeep = 0
    tracking.housekeep()
end)

-- UNIT_AURA can't be compared in combat; checkUnit finds that out itself.
local events = CreateFrame("Frame")
for _, event in ipairs({ "UNIT_AURA", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, unit)
    local ok, err = pcall(function()
        if event == "UNIT_AURA" then
            if type(unit) == "string" and not isSecret(unit) and not ns.inCombat() then tracking.checkUnit(unit) end
        elseif event == "PLAYER_TARGET_CHANGED" then
            if plainCall(UnitExists, "target") then tracking.checkUnit("target") end
        else
            tracking.checkUnit("player")
            tracking.housekeep()
        end
    end)
    if not ok and not tracking.errorLogged then
        tracking.errorLogged = true
        out("TRACKING " .. event .. " ERROR " .. tostring(err), true)
    end
end)
