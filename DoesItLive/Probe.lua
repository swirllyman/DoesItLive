-- DoesItLive probe
-- Answers, before any real feature is built: what can addon code read about HEALING on friendly units in
-- WoW Forever, in and out of combat? Everything goes to a log saved in SavedVariables (DoesItLiveDB.log,
-- written on /reload or logout). Every API call is wrapped in pcall, so a blocked or missing API is logged,
-- never fatal. See CLAUDE.md for the list of questions and how to read the answers.

local ADDON, ns = ...
local PREFIX = "DoesItLive"
local MAX_LOG_LINES = 2000
local AUTO_SNAPSHOT_DELAY = 4
local PER_FIGHT_LIMIT = 25 -- per event kind, so a long fight doesn't flood the log
local METER_TRIES, METER_RETRY_SECONDS = 20, 0.5

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
    if toChat or echo or (db and db.echo) then DEFAULT_CHAT_FRAME:AddMessage("|cff66ff99DIL|r " .. msg) end
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

-- For Tracking.lua and Display.lua (loaded after this file).
ns.isSecret, ns.probe, ns.call, ns.out = isSecret, probe, call, out
function ns.print(msg) out(msg, true) end -- (Frames.lua, from DoesItDie, uses these two)
ns.trace = out
function ns.db() return db end

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
ns.inCombat = inCombat

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
    local unit = ns.tracking.findUnit(name) or unitByName(name) or "player"
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
    -- Group channels only. A whisper to yourself goes to UnitName("player"), which on Forever leaves out the
    -- surname ("Joe" for "Joe Gg"), so the server printed "No player named 'Joe' is currently playing." on every pull.
    local channel
    if IsInRaid and IsInRaid() then channel = "RAID"
    elseif IsInGroup and IsInGroup() then channel = "PARTY" end
    if not channel then
        out("ADDONMSG " .. why .. ": not in a group, nothing sent")
        return
    end
    local text = string.format("probe %s combat=%s t=%.1f", why, tostring(inCombat()), GetTime())
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, channel)
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
-- Events
---------------------------------------------------------------------------

local f = CreateFrame("Frame")
local registrations = {}
for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGOUT", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
    "UNIT_COMBAT", "UNIT_HEALTH", "UNIT_AURA", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED",
    "CHAT_MSG_ADDON", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "GROUP_ROSTER_UPDATE",
}) do
    local ok, err = pcall(f.RegisterEvent, f, event)
    registrations[#registrations + 1] = event .. "=" .. (ok and "ok" or ("ERROR " .. tostring(err)))
end

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        DoesItLiveDB = DoesItLiveDB or {}
        db = DoesItLiveDB
        ns.applyDefaults(db)
        log = db.log or log
        db.log = log
        echo = db.echo or false
        out("Loaded (v7, bar options). /dil for settings, /dil help for commands.", true)
        out("Event registrations: " .. table.concat(registrations, " "))
        local optionsOK, optionsErr = pcall(ns.registerOptions)
        if not optionsOK then out("Options > AddOns page ERROR " .. tostring(optionsErr)) end
        ns.display.settingsChanged()
        C_Timer.After(5, function() pcall(ns.display.logAddonFrames) end) -- once their frames exist
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
        ns.tracking.onUnitCombat(...)
        onUnitCombat(...)

    elseif event == "UNIT_HEALTH" then
        onUnitHealth((...))

    elseif event == "UNIT_AURA" then
        onUnitAura(...)

    elseif event == "UNIT_SPELLCAST_SENT" then
        local unit, target, castGUID, spellID = ...
        if unit == "player" and castGUID and not isSecret(castGUID) then sentTarget[castGUID] = target end
        if unit == "player" then ns.tracking.onCastSent(target, castGUID, spellID) end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" then
            ns.tracking.onCastSucceeded(castGUID, spellID)
            onOwnCast(castGUID, spellID)
        elseif type(unit) == "string" and (unit:find("^party") or unit:find("^raid")) then
            onOtherCast(unit, spellID)
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        ns.display.onTargetChanged()

    elseif event == "PLAYER_FOCUS_CHANGED" then
        ns.display.onFocusChanged()

    elseif event == "GROUP_ROSTER_UPDATE" then
        ns.display.onRosterChanged()

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        ns.display.onPlateAdded((...))

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        ns.display.onPlateRemoved((...))

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
    if cmd == "" or cmd == "options" or cmd == "config" then
        ns.openOptions()
    elseif cmd == "probe" then
        snapshot("manual")
    elseif cmd == "bar" then
        ns.display.setTestBar(tonumber(arg))
    elseif cmd == "plates" then
        ns.display.togglePlates()
    elseif cmd == "hots" then
        local lines = ns.tracking.list()
        if #lines == 0 then out("No HoTs tracked.", true) end
        for _, line in ipairs(lines) do out(line, true) end
    elseif cmd == "msg" then
        sendTestMessage("manual")
    elseif cmd == "meter" then
        readMeter(0)
    elseif cmd == "echo" then
        echo = not (echo or (db and db.echo))
        if db then db.echo = echo end
        out("Echo to chat " .. (echo and "ON" or "OFF") .. ".", true)
    elseif cmd == "clear" then
        wipe(log)
        out("Log cleared.", true)
    else
        out("/dil - settings. DoesItLive shows your HoTs by itself. Everything is logged to SavedVariables\\DoesItLive.lua on /reload or logout.", true)
        out("/dil probe - snapshot of health, heal prediction and auras on you, your target and party", true)
        out("/dil hots - list your HoTs as tracked; /dil bar <n> - show a fixed n instead (/dil bar to go back)", true)
        out("/dil plates - turn the heal bar on friendly nameplates on or off", true)
        out("/dil msg - send a test addon message; /dil meter - read the damage meter's healing now", true)
        out("/dil echo - also print every log line to chat; /dil clear - clear the log", true)
    end
end
