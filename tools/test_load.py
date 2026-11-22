"""Smoke test: loads every file in DoesItLive.toc (Lua 5.1, like WoW) with a fake WoW environment, then fires the
events and slash commands the probe handles, with plain and with secret values. Catches runtime errors, not
visual ones. Usage: pip install lupa; python tools/test_load.py"""

import os
import sys

import lupa.lua51 as lupa51

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "DoesItLive")

FAKE_WOW = r"""
local frames = {}
local function newObject()
    local o = {}
    setmetatable(o, { __index = function(t, k)
        return function(self, ...)
            if k == "GetStatusBarTexture" or k == "CreateTexture" or k == "CreateAnimationGroup" or k == "CreateAnimation" then
                return newObject()
            elseif k == "GetWidth" or k == "GetHeight" then return 100
            elseif k == "GetFrameLevel" then return 3
            elseif k == "GetFrameStrata" then return "MEDIUM"
            elseif k == "GetName" then return nil
            end
        end
    end })
    return o
end
function CreateFrame(kind, name, parent)
    local f = newObject()
    local scripts = {}
    rawset(f, "SetScript", function(self, what, fn) scripts[what] = fn end)
    rawset(f, "RegisterEvent", function(self, e) end)
    rawset(f, "_scripts", scripts)
    frames[#frames + 1] = f
    return f
end
function fireEvent(event, ...)
    for _, f in ipairs(frames) do
        local h = f._scripts.OnEvent
        if h then h(f, event, ...) end
    end
end
function tick(seconds)
    for _, f in ipairs(frames) do
        local h = f._scripts.OnUpdate
        if h then h(f, seconds) end
    end
end

SECRET = setmetatable({}, { __lt = function() error("secret compare") end, __add = function() error("secret math") end,
    __tostring = function() return "SECRET" end })
function issecretvalue(v) return v == SECRET end
function canaccesstable(t) return t ~= SECRET end

inCombat = false
secretHealth = false
chat = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) chat[#chat + 1] = m end }
function date() return "00:00:00" end
function GetTime() return 100 end
function GetBuildInfo() return "1.60.1", "12345", "", 16001 end
function UnitClass() return "Druid", "DRUID" end
function UnitLevel() return 60 end
function UnitAffectingCombat() return inCombat end
function UnitExists(u) return u == "player" or u == "target" or u == "party1" end
function UnitIsUnit(a, b) return a == b end
function UnitCanAssist(_, u) return u ~= "target" end
function UnitCanAttack(_, u) return u == "target" end
function UnitName(u) if u == "player" then return "Joe" elseif u == "party1" then return "Pal" end return "Mob" end
function UnitGUID() return "Player-1-1" end
function UnitHealth() if secretHealth then return SECRET end return 500 end
function UnitHealthMax() if secretHealth then return SECRET end return 1000 end
function UnitGetIncomingHeals() return SECRET end
function GetSpellBonusHealing() return 300 end
function IsInGroup() return true end
function IsInRaid() return false end
function InCombatLockdown() return inCombat end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strlower(s) return string.lower(s) end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
timers = {}
C_Timer = { After = function(d, fn) timers[#timers + 1] = fn end }
function runTimers()
    local list = timers
    timers = {}
    for _, fn in ipairs(list) do fn() end
end
C_Spell = { GetSpellName = function(id) return "Rejuvenation" end,
            GetSpellDescription = function(id) return "Heals the target for 776 over 12 sec." end }
C_UnitAuras = { GetAuraDataByIndex = function(unit, i, filter)
    if i > 1 then return nil end
    if inCombat then return { name = SECRET, spellId = SECRET, duration = SECRET, expirationTime = SECRET, points = SECRET } end
    return { name = "Rejuvenation", spellId = 774, duration = 12, expirationTime = 112, sourceUnit = "player", points = { 65 } }
end }
C_Secrets = { ShouldAurasBeSecret = function() return inCombat end }
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end, SendAddonMessage = function() return 0 end }
Enum = { DamageMeterType = { DamageDone = 0, HealingDone = 2, Absorbs = 3 }, DamageMeterSessionType = { Current = 1 } }
C_DamageMeter = { GetCombatSessionSourceFromType = function(session, t)
    return { totalAmount = 1234, combatSpells = { { spellID = 774, totalAmount = 1000, overkillAmount = 0 } } }
end }
PlayerFrame = { PlayerFrameContent = { PlayerFrameContentMain = { HealthBarsContainer = { HealthBar = CreateFrame("StatusBar") } } } }
SlashCmdList = {}
"""


def main():
    os.environ["LC_ALL"] = "C"
    lua = lupa51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE_WOW)
    toc = open(os.path.join(ROOT, "DoesItLive.toc"), encoding="utf-8").read().splitlines()
    files = [line.strip() for line in toc if line.strip() and not line.startswith("#")]
    ns = lua.eval("{}")
    for name in files:
        code = open(os.path.join(ROOT, name), encoding="utf-8").read()
        lua.execute("return function(...) " + code + "\nend")  # syntax check
        lua.eval("function(code, name, ns) local fn = assert(loadstring(code, name)); fn('DoesItLive', ns) end")(code, name, ns)

    script = r"""
    fireEvent("ADDON_LOADED", "DoesItLive")
    local cmd = SlashCmdList.DOESITLIVE
    cmd("") cmd("probe") cmd("bar 800") tick(0.2) cmd("bar") cmd("msg") cmd("meter") cmd("echo") cmd("echo")
    fireEvent("UNIT_SPELLCAST_SENT", "player", "Pal", "cast-1", 774)
    fireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 774)
    fireEvent("UNIT_COMBAT", "party1", "HEAL", "", 65, 8)
    fireEvent("UNIT_HEALTH", "party1")
    fireEvent("UNIT_AURA", "party1", { isFullUpdate = false, addedAuras = { { name = "Rejuvenation", spellId = 774 } } })
    fireEvent("UNIT_SPELLCAST_SUCCEEDED", "party1", "cast-2", 139)
    fireEvent("CHAT_MSG_ADDON", "DoesItLive", "probe manual", "PARTY", "Pal")
    runTimers()
    -- In combat: secret amounts, health, auras.
    inCombat = true secretHealth = true
    fireEvent("PLAYER_REGEN_DISABLED")
    fireEvent("UNIT_COMBAT", "player", "HEAL", "", SECRET, 8)
    fireEvent("UNIT_COMBAT", "party1", SECRET, "", SECRET, SECRET)
    fireEvent("UNIT_HEALTH", "player")
    fireEvent("UNIT_AURA", "player", SECRET)
    fireEvent("UNIT_SPELLCAST_SUCCEEDED", "party1", "cast-3", SECRET)
    fireEvent("CHAT_MSG_ADDON", SECRET, SECRET, SECRET, SECRET)
    cmd("bar 300") tick(0.2) cmd("bar")
    runTimers() runTimers()
    inCombat = false secretHealth = false
    fireEvent("PLAYER_REGEN_ENABLED")
    runTimers() runTimers()
    fireEvent("PLAYER_LOGOUT")
    return #DoesItLiveDB.log
    """
    lines = lua.execute(script)
    log = lua.eval("DoesItLiveDB.log")
    text = "\n".join(log[i] for i in range(1, len(log) + 1))
    for needle in ["SNAPSHOT (manual)", "BAR attach", "CAST Rejuvenation", "HEAL CHECK party1", "UNIT_AURA party1",
                   "OTHER CAST", "ADDONMSG received", "METER HealingDone", "<secret>", "Left combat"]:
        if needle not in text:
            print(text)
            print("MISSING in log:", needle)
            sys.exit(1)
    if "ERROR" in text:
        print(text)
        print("ERROR lines in log")
        sys.exit(1)
    if "-v" in sys.argv:
        print(text)
    print(f"OK: {len(files)} file(s) loaded, {lines} log lines, no errors")


if __name__ == "__main__":
    main()
