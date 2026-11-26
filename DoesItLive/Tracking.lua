-- DoesItLive tracking: which of your HoTs are on whom, and how much healing each still has to do.
--
-- Heal amounts and predicted heals are secret even out of combat, so HoTs are estimated:
--   * which HoT, on whom, when: your own casts (UNIT_SPELLCAST_SENT names the target, SUCCEEDED confirms the cast)
--   * how much: the spell's tooltip. It already includes bonus healing (checked against the damage meter on
--     2026-11-22: Rejuvenation 214 in the tooltip, 215 healed; Regrowth 313-352 + 300, 624 healed)
--   * when it ticks: every 3 seconds from the cast (Rejuvenation and Regrowth seen in the log; Renew and Riptide
--     assumed). Crits aren't counted.
--   * Wild Growth (unverified): every second, front-loaded (ticks from 1.3x down to 0.7x of the average, summing to
--     the tooltip), on the target and the members of your group it reached. Who it reached isn't told: a group member
--     whose heal ticks about a second after the cast (its first tick, landing on everyone at once) gets it. Heal ticks
--     report school 1, not Nature, so only the timing tells. Out of combat the auras correct it.
--   * corrections: out of combat your auras are readable, so a HoT that's gone is dropped, one that's there with
--     another expiration is moved, and one that was missed (a /reload) is picked up. In combat none of that can be
--     read: a HoT dispelled or cancelled then stays until it would have expired.
--   * besides HoTs on others (Settings.lua's groups): heals on yourself from draining spells, on your pet, from
--     totems and Penance, and bandages, food and anything else of yours whose tooltip heals over time. Channels
--     (Drain Life, Mend Pet, Health Funnel, Penance, bandages) end when the channel does; Healing Stream Totem lasts
--     5 minutes, so only its next 10 seconds show, and it ends with the totem.
-- Loaded after Probe.lua (logging and helpers).

local _, ns = ...

local isSecret, probe, out = ns.isSecret, ns.probe, ns.out

local tracking = {}
ns.tracking = tracking

-- By English spell name; ticks every `interval` seconds.
-- Tooltip readers for the ones that don't say "<n> over <s> sec": total healing, seconds, and seconds per tick.
local function every(pattern)
    return function(desc)
        local amount, interval, seconds = desc:match(pattern)
        amount, interval, seconds = tonumber(amount), tonumber(interval) or 1, tonumber(seconds)
        if not amount or not seconds then return nil end
        return amount * seconds / interval, seconds, interval
    end
end

-- How each known spell heals (by English name):
--   interval: seconds per tick; parse(desc): total, seconds[, interval] when the tooltip isn't "<n> over <s> sec"
--   on: who's healed: the cast's target (default), "player", "pet" or "group" (you and your party)
--   aura = false: there's no buff of yours on whoever's healed, so a missing aura doesn't end it
--   channel: ends when your channel does; allyOnly: only counts cast on a friend; window: ticks shown ahead
local HOTS = {
    ["Rejuvenation"] = { interval = 3 },
    ["Regrowth"] = { interval = 3 },
    ["Renew"] = { interval = 3 },
    ["Riptide"] = { interval = 3 },
    ["Wild Growth"] = { interval = 1, frontLoaded = true, spreads = true },
    -- "Transfers 41 health from the target to the caster every 3 sec. Lasts 30 sec."
    ["Siphon Life"] = { on = "player", aura = false,
        parse = every("Transfers (%d+) health from the target to the caster every (%d+) sec%.%s*Lasts (%d+) sec") },
    -- "Transfers 51 health every 1 second from the target to the caster. Lasts 5 sec."
    ["Drain Life"] = { on = "player", aura = false, channel = true,
        parse = every("Transfers (%d+) health every (%d+) seconds? from the target to the caster%.%s*Lasts (%d+) sec") },
    -- "...causes 848 Shadow damage over 24 sec. Damage caused by the Devouring Plague heals the caster." (rough: what
    -- it heals isn't stated; assumed to be all of its damage, in 3 second ticks)
    ["Devouring Plague"] = { on = "player", aura = false, interval = 3,
        parse = function(desc)
            local total, seconds = desc:match("(%d+) %a+ damage over (%d+) sec")
            if total then return tonumber(total), tonumber(seconds), 3 end
        end },
    -- "Heals your pet 245 health every second while you focus. Lasts 5 sec."
    ["Mend Pet"] = { on = "pet", channel = true, parse = function(desc)
        local amount, seconds = desc:match("Heals your pet (%d+) health every second.-Lasts (%d+) sec")
        if amount then return tonumber(amount) * tonumber(seconds), tonumber(seconds), 1 end
    end },
    -- "Gives 153 health to the caster's pet every second for 10 sec as long as the caster channels."
    ["Health Funnel"] = { on = "pet", aura = false, channel = true,
        parse = function(desc)
            local amount, seconds = desc:match("Gives (%d+) health to the caster's pet every second for (%d+) sec")
            if amount then return tonumber(amount) * tonumber(seconds), tonumber(seconds), 1 end
        end },
    -- "...for 5 min that heals group members within 30 yards for 11 every 2 seconds."
    ["Healing Stream Totem"] = { on = "group", aura = false, window = 5,
        parse = function(desc)
            local minutes = tonumber(desc:match("for (%d+) min"))
            local amount, interval = desc:match("for (%d+) every (%d+) seconds")
            amount, interval = tonumber(amount), tonumber(interval)
            if minutes and amount and interval then return amount * minutes * 60 / interval, minutes * 60, interval end
        end },
    -- "...or 673 healing to an ally, instantly and every 1 sec for 2 sec." The instant hit has landed by the cast
    -- event; the two after it are left.
    ["Penance"] = { aura = false, channel = true, allyOnly = true,
        parse = function(desc)
            local amount, interval, seconds = desc:match("(%d+) healing to an ally, instantly and every (%d+) sec for (%d+) sec")
            amount, interval, seconds = tonumber(amount), tonumber(interval), tonumber(seconds)
            if amount then return amount * seconds / interval, seconds, interval end
        end },
}
-- Ours, but nothing to show: Lightwell (placing it heals no one; clicking it is a renew of its own, caught by the
-- tooltip rule), Contingency Plan (its amounts are "?" and it only starts below 35% health, which is secret), Dark
-- Sacrifice (costs health). Tranquility and the like heal at once per tick.
local IGNORED = { ["Lightwell"] = true, ["Contingency Plan"] = true, ["Dark Sacrifice"] = true }
local UNTRACKED = {} -- known HoTs left out (none at the moment)

-- Anything else of yours whose tooltip heals over time: bandages ("Heals 2000 damage over 8 sec."), food ("Restores
-- 2148 health over 30 sec."), Lightwell's renew. Not damage over time, mana, or a heal at once.
local function healsOverTime(desc)
    if type(desc) ~= "string" or isSecret(desc) then return false end
    return (desc:find("^%s*[Hh]eals") or desc:find("[Rr]estores? %d[%d,]* health")) and desc:find("over %d+ sec") ~= nil
end
local FRONT_FIRST, FRONT_LAST = 1.3, 0.7 -- Wild Growth's first and last tick, in average ticks (assumed)
-- A group member healed this long after a spreading HoT's cast was reached by it (its first tick).
local SPREAD_FROM, SPREAD_TO = 0.5, 1.8
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

-- Tick `tick` of `ticks`, in average ticks: 1, or for a front-loaded HoT a straight line from FRONT_FIRST down to
-- FRONT_LAST (which averages 1, so the ticks still add up to the tooltip).
function tracking.tickWeight(hot, tick)
    if not hot.frontLoaded or hot.ticks < 2 then return 1 end
    return FRONT_FIRST + (FRONT_LAST - FRONT_FIRST) * (tick - 1) / (hot.ticks - 1)
end

local function remainingOf(hot, now)
    if hot.window then return math.min(remainingTicks(hot, now), hot.window) * hot.perTick end
    if not hot.frontLoaded then return remainingTicks(hot, now) * hot.perTick end
    local sum = 0
    for tick = 1, hot.ticks do
        if hot.start + tick * hot.interval > now then sum = sum + hot.perTick * tracking.tickWeight(hot, tick) end
    end
    return sum
end
tracking.remainingOf = remainingOf

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

-- How a spell heals: its HOTS entry, or for a tooltip that heals over time, a plain one (ticks every 3 seconds
-- when the time divides by 3, else every second: bandages tick each second, food every 3). Nil if it doesn't.
local function specFor(name, desc)
    if HOTS[name] then return HOTS[name] end
    if IGNORED[name] or not healsOverTime(desc) then return nil end
    local _, seconds = tracking.parseHot(desc)
    return { interval = seconds and seconds % 3 == 0 and 3 or 1, generic = true }
end
tracking.specFor = specFor

-- A HoT's numbers, or nil (why it can't be tracked, for the log).
local function newHot(spellID, name, desc, who)
    local spec = specFor(name, desc)
    if not spec then return nil end
    local total, seconds, interval
    if spec.parse and type(desc) == "string" and not isSecret(desc) then
        local plainDesc = desc
        for _ = 1, 2 do plainDesc = plainDesc:gsub("(%d),(%d%d%d)%f[^%d]", "%1%2") end
        total, seconds, interval = spec.parse(plainDesc)
    else
        total, seconds = tracking.parseHot(desc)
    end
    if not total then return nil end
    interval = interval or spec.interval or 3
    local ticks = math.max(1, math.floor(seconds / interval + 0.5))
    return { spellID = spellID, name = name, who = who, total = total, duration = seconds, interval = interval,
        ticks = ticks, perTick = total / ticks, start = GetTime(), castAt = GetTime(), frontLoaded = spec.frontLoaded,
        channel = spec.channel, window = spec.window, noAura = spec.aura == false }
end

function tracking.any()
    return hotCount > 0
end

-- Healing your HoTs still have to do on this unit (0 if none), and per HoT: { { name, amount }, ... } in a fixed
-- spell order (so per-HoT colors don't swap places). shown(spell name), if given, leaves out the HoTs it says no to
-- (turned off in the options).
local SPELL_ORDER = {} -- by the options' order of groups and spells
for i, spell in ipairs(ns.SPELLS) do SPELL_ORDER[spell] = i end

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
        table.sort(parts, function(a, b)
            return (SPELL_ORDER[ns.displayGroup(a.name)] or 99) < (SPELL_ORDER[ns.displayGroup(b.name)] or 99)
        end)
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
    return { guidKey = guidKey, nameKey = nameKey, who = who, how = how, at = GetTime(), unit = unit }
end

function tracking.onCastSent(name, castGUID, spellID)
    if not castGUID or isSecret(castGUID) then return end
    local now = GetTime()
    for guid, sent in pairs(sentCasts) do
        if now - sent.at > SENT_SECONDS then sentCasts[guid] = nil end
    end
    local spell, desc = spellInfo(spellID)
    if not spell or not (specFor(spell, desc) or spell == "Swiftmend") then return end
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
    local spec = specFor(spell, desc)
    if not spec then
        local total, seconds = tracking.parseHot(desc)
        if UNTRACKED[spell] or (total and desc:find("[Hh]eal") and not IGNORED[spell]) then
            out(string.format("HOT not tracked: %s id=%s (%s over %s sec): %s", spell, probe(spellID), tostring(total),
                tostring(seconds), desc or "no description"))
        end
        return
    end
    sent = sent or castTarget(nil)
    if spec.allyOnly and not sent.unit then return end -- cast on an enemy: damage, not healing
    -- Who's healed: the target, or for draining spells, pets and totems, yourself, your pet or your group.
    local recipients = {}
    if spec.on == "player" or spec.on == "pet" then
        local guidKey, nameKey = keysOf(spec.on)
        if guidKey or nameKey then
            recipients[1] = { guidKey = guidKey, nameKey = nameKey, who = namesOf(spec.on) or spec.on, how = spec.on }
        end
    elseif spec.on == "group" then
        for _, unit in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
            local guidKey, nameKey = keysOf(unit)
            if (guidKey or nameKey) and canAssist(unit) then
                recipients[#recipients + 1] = { guidKey = guidKey, nameKey = nameKey, who = namesOf(unit) or unit, how = "group" }
            end
        end
    else
        recipients[1] = sent
    end
    if #recipients == 0 then
        out("HOT " .. spell .. ": nobody to put it on (" .. tostring(spec.on or sent.how) .. ")")
        return
    end
    local hot, key, recast
    for i, recipient in ipairs(recipients) do
        hot = newHot(spellID, spell, desc, recipient.who)
        if not hot then
            out("HOT " .. spell .. ": no over-time amount in its description: " .. tostring(desc))
            return
        end
        key = recipient.guidKey or recipient.nameKey
        if not key then
            out("HOT " .. spell .. ": nothing to keep its target under (" .. tostring(recipient.how) .. ")")
            return
        end
        -- A recast replaces it, wherever the old one is kept.
        recast = false
        for _, old in ipairs({ recipient.guidKey or false, recipient.nameKey or false }) do
            if old and hotsByKey[old] and hotsByKey[old][spell] then
                recast = true
                drop(old, spell, "recast")
            end
        end
        put(key, spell, hot)
        if i > 1 then out(string.format("ESTIMATE %s also on %s: %d", spell, recipient.who, remainingOf(hot, GetTime()))) end
        sent = i == 1 and recipient or sent
    end
    hot = hotsByKey[recipients[1].guidKey or recipients[1].nameKey][spell]
    out(string.format("ESTIMATE %s on %s (%s)%s: %d over %.0fs, %d ticks of %.1f every %ds%s%s", spell, sent.who, sent.how,
        recast and " recast" or "", hot.total, hot.duration, hot.ticks, hot.perTick, hot.interval,
        hot.frontLoaded and string.format(" (front-loaded: first %.1f, last %.1f)", hot.perTick * tracking.tickWeight(hot, 1),
            hot.perTick * tracking.tickWeight(hot, hot.ticks)) or "",
        sent.guidKey and "" or " (kept by name)"))
    if spec.spreads then tracking.lastSpread = { spellID = spellID, name = spell, desc = desc, at = hot.castAt,
        start = hot.start, targetKey = key, inGroup = sent.unit == nil or tracking.inGroup(sent.unit) } end
    if ns.display then ns.display.refresh() end
end

-- Whether a unit is in your party or raid (a spreading HoT on it reaches your group).
function tracking.inGroup(unit)
    if unit == "player" or unit:match("^party%d") or unit:match("^raid%d") then return true end
    return plainCall(UnitInParty, unit) == true or plainCall(UnitInRaid, unit) ~= nil
end

-- UNIT_COMBAT: a heal on a group member right after a spreading HoT's cast means it reached them.
function tracking.onUnitCombat(unit, action)
    local spread = tracking.lastSpread
    if not spread or type(unit) ~= "string" or isSecret(unit) or isSecret(action) or action ~= "HEAL" then return end
    local since = GetTime() - spread.at
    if since > SPREAD_TO then
        tracking.lastSpread = nil
        return
    end
    if since < SPREAD_FROM or not spread.inGroup then return end
    if not (unit == "player" or unit:match("^party%d+$") or unit:match("^raid%d+$")) then return end
    local guidKey, nameKey = keysOf(unit)
    local key = guidKey or nameKey
    if not key or key == spread.targetKey then return end
    local old = hotsByKey[key] and hotsByKey[key][spread.name]
    if old and old.castAt == spread.at then return end -- already counted (the same heal comes for several tokens)
    local hot = newHot(spread.spellID, spread.name, spread.desc, namesOf(unit) or unit)
    if not hot then return end
    hot.start, hot.castAt = spread.start, spread.at
    if old then drop(key, spread.name, "recast") end
    put(key, spread.name, hot)
    out(string.format("SPREAD %s reached %s (healed %.1fs after the cast): %d left", spread.name, hot.who, since,
        remainingOf(hot, GetTime())))
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
        if type(name) == "string" then found[name] = { spellID = id, duration = duration, expiration = expiration } end
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
            elseif not hot.noAura and now - hot.castAt > AURA_GRACE_SECONDS then
                drop(key, name, "its aura is gone")
                changed = true
            end
        end
    end
    for name, aura in pairs(auras) do
        if not known[name] and type(aura.expiration) == "number" and aura.expiration > now
            and type(aura.duration) == "number" and aura.duration > 0 then
            local _, desc = spellInfo(aura.spellID)
            local spec = specFor(name, desc)
            -- Pets and draining spells have no aura of theirs to find; a channel's aura can't tell when it stops.
            local hot = spec and spec.aura ~= false and not spec.channel and not spec.on
                and newHot(aura.spellID, name, desc, namesOf(unit) or unit)
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
-- Your channel ended (finished, stopped, or knocked off by damage): its heals stop.
function tracking.onChannelStop(spellID)
    local ended = {}
    for key, hots in pairs(hotsByKey) do
        for name, hot in pairs(hots) do
            -- A channel stop for its spell makes it a channel (bandages come from the tooltip rule, unmarked).
            if (not isSecret(spellID) and spellID ~= nil and hot.spellID == spellID)
                or (hot.channel and (isSecret(spellID) or spellID == nil)) then
                ended[#ended + 1] = { key, name }
            end
        end
    end
    for _, entry in ipairs(ended) do drop(entry[1], entry[2], "channel ended") end
    if #ended > 0 and ns.display then ns.display.refresh() end
end

-- Your Healing Stream Totem is gone (destroyed, replaced or recalled): it heals no more.
function tracking.onTotemUpdate()
    if type(GetTotemInfo) ~= "function" then return end
    for slot = 1, 4 do
        local _, name = plainCall(GetTotemInfo, slot)
        if type(name) == "string" and name:find("Healing Stream") then return end
        if name == nil then
            local ok, raw = pcall(function() return select(2, GetTotemInfo(slot)) end)
            if ok and isSecret(raw) then return end -- can't tell: keep it
        end
    end
    local gone = {}
    for key, hots in pairs(hotsByKey) do
        if hots["Healing Stream Totem"] then gone[#gone + 1] = key end
    end
    for _, key in ipairs(gone) do drop(key, "Healing Stream Totem", "totem gone") end
    if #gone > 0 and ns.display then ns.display.refresh() end
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "UNIT_AURA", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED",
    "UNIT_SPELLCAST_CHANNEL_STOP", "PLAYER_TOTEM_UPDATE", "UNIT_PET" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, unit, ...)
    local args = { ... }
    local ok, err = pcall(function()
        if event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            if unit == "player" then tracking.onChannelStop(args[2]) end
        elseif event == "PLAYER_TOTEM_UPDATE" then
            tracking.onTotemUpdate()
        elseif event == "UNIT_PET" then
            if unit == "player" and plainCall(UnitExists, "pet") then tracking.checkUnit("pet") end
        elseif event == "UNIT_AURA" then
            if type(unit) == "string" and not isSecret(unit) and not ns.inCombat() then tracking.checkUnit(unit) end
        elseif event == "PLAYER_TARGET_CHANGED" then
            if plainCall(UnitExists, "target") then tracking.checkUnit("target") end
        elseif event == "PLAYER_FOCUS_CHANGED" then
            if plainCall(UnitExists, "focus") then tracking.checkUnit("focus") end
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
