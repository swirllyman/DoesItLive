"""Smoke test (the tracking itself: test_tracking.py): loads every file in DoesItLive.toc (Lua 5.1, like WoW) with a fake WoW environment, then fires the
events and slash commands the probe handles, with plain and with secret values. Catches runtime errors, not
visual ones. Usage: pip install lupa; python tools/test_load.py"""

import os
import sys

import lupa.lua51 as lupa51

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "DoesItLive")

FAKE_WOW = r"""
local frames = {}
allFrames = frames
UIParent = {}
local function newObject()
    local o = {}
    setmetatable(o, { __index = function(t, k)
        return function(self, ...)
            if k == "GetChildren" then return nil
            elseif k == "GetStatusBarTexture" or k == "CreateTexture" or k == "CreateAnimationGroup" or k == "CreateAnimation"
                or k == "CreateFontString" or k == "CreateMaskTexture" or k == "GetThumbTexture" then
                return newObject()
            elseif k == "GetWidth" or k == "GetHeight" then return 100
            elseif k == "GetFrameLevel" then return 3
            elseif k == "GetFrameStrata" then return "MEDIUM"
            elseif k == "GetName" then return nil
            elseif k == "GetObjectType" then return rawget(self, "_kind") or "Frame"
            elseif k == "GetStringWidth" then return fakeStringWidth or 40
            elseif k == "GetFont" then return "Fonts\\FRIZQT__.TTF", 10
            end
        end
    end })
    return o
end
function CreateFrame(kind, name, parent)
    local f = newObject()
    rawset(f, "_parent", parent) rawset(f, "shown", true) rawset(f, "_kind", kind)
    rawset(f, "Show", function(self) self.shown = true end)
    rawset(f, "Hide", function(self) self.shown = false end)
    rawset(f, "SetShown", function(self, s) self.shown = s and true or false end)
    rawset(f, "SetFrameLevel", function(self, l) self.level = l end)
    rawset(f, "SetFrameStrata", function(self, s) self.strata = s end)
    rawset(f, "SetAllPoints", function(self, to) self.over = to end)
    local scripts = {}
    rawset(f, "SetScript", function(self, what, fn) scripts[what] = fn end)
    rawset(f, "RegisterEvent", function(self, e) end)
    rawset(f, "_scripts", scripts)
    frames[#frames + 1] = f
    if name then _G[name] = f end
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
function UnitExists(u) return u == "player" or u == "target" or u == "party1" or (plates and plates[u] ~= nil) or u == "nameplate3" or u == "focus" end
function UnitIsUnit(a, b) return a == b end
friendlyTarget, friendlyFocus = false, false
function UnitCanAssist(_, u)
    if friendlyTarget == "secret" then return SECRET end
    if u == "nameplate2" then return false end
    if u == "focus" then return friendlyFocus end
    return u ~= "target" or friendlyTarget
end
function UnitCanAttack(_, u) return u == "target" end
function UnitName(u) if u == "player" then return "Joe" elseif u == "party1" then return "Pal" end return "Mob" end
function UnitGUID(u) return "GUID-" .. u end
function UnitHealth() if secretHealth then return SECRET end return 500 end
function UnitHealthMax() if secretHealth then return SECRET end return 1000 end
function UnitGetIncomingHeals() return SECRET end
function UnitHealthMissing() if secretHealth then return SECRET end return 500 end
function GetSpellBonusHealing() return 300 end
function IsInGroup() return true end
function IsInRaid() return false end
function InCombatLockdown() return inCombat end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strlower(s) return string.lower(s) end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
timers = {}
tickers = {}
C_Timer = { After = function(d, fn) timers[#timers + 1] = fn end,
            NewTicker = function(d, fn)
                local ticker = { fn = fn, Cancel = function(self) self.cancelled = true end }
                tickers[#tickers + 1] = ticker
                return ticker
            end }
function runTickers(times)
    for _ = 1, times do
        for _, ticker in ipairs(tickers) do if not ticker.cancelled then ticker.fn() end end
    end
end
UISpecialFrames = {}
GameTooltip = CreateFrame("Frame")
SettingsPanel = CreateFrame("Frame")
categories = {}
Settings = { RegisterCanvasLayoutCategory = function(panel, name) return { panel = panel, name = name } end,
             RegisterAddOnCategory = function(category) categories[#categories + 1] = category end }
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
    return { name = "Mark of the Wild", spellId = 1126, duration = 12, expirationTime = 112, sourceUnit = "player", points = { 65 } }
end }
C_Secrets = { ShouldAurasBeSecret = function() return inCombat end }
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end, SendAddonMessage = function() return 0 end }
Enum = { DamageMeterType = { DamageDone = 0, HealingDone = 2, Absorbs = 3 }, DamageMeterSessionType = { Current = 1 } }
C_DamageMeter = { GetCombatSessionSourceFromType = function(session, t)
    return { totalAmount = 1234, combatSpells = { { spellID = 774, totalAmount = 1000, overkillAmount = 0 } } }
end }
PetFrameHealthBar, PetFrame = CreateFrame("StatusBar"), {}
PlayerFrame = { PlayerFrameContent = { PlayerFrameContentMain = { HealthBarsContainer = { HealthBar = CreateFrame("StatusBar") } } } }
-- The target frame: its own level is secret, a child sits at MEDIUM/1001 (what Forever does).
local function layered(strata, level, children)
    return { GetFrameStrata = function() return strata end, GetFrameLevel = function() return level end,
             GetChildren = function() return unpack(children or {}) end }
end
TargetFrame = layered(SECRET, SECRET, { layered("LOW", 5000),
    setmetatable({}, { __index = function() error("forbidden frame") end }), layered("MEDIUM", 1001) })
for k, v in pairs({ TargetFrameContent = { TargetFrameContentMain = { HealthBarsContainer = { HealthBar = CreateFrame("StatusBar") } } } }) do TargetFrame[k] = v end
-- The focus frame: built from the target frame's template.
FocusFrame = layered("LOW", 10, { layered("MEDIUM", 1001) })
FocusFrame.TargetFrameContent = { TargetFrameContentMain = { HealthBarsContainer = { HealthBar = CreateFrame("StatusBar") } } }
PersonalResourceDisplayFrame = { HealthBarsContainer = { healthBar = CreateFrame("StatusBar") } }
for k, v in pairs(layered("LOW", 20)) do PlayerFrame[k] = v end
for k, v in pairs(layered("LOW", 40)) do PersonalResourceDisplayFrame[k] = v end
plates = {
    nameplate1 = { UnitFrame = { healthBar = CreateFrame("StatusBar") }, GetFrameStrata = function() return "LOW" end },
    nameplate2 = { UnitFrame = { healthBar = CreateFrame("StatusBar") } },
    nameplate4 = { IsForbidden = function() return true end },
    nameplate5 = { UnitFrame = {} },
}
C_NamePlate = { GetNamePlateForUnit = function(unit, includeForbidden)
    if unit == "nameplate3" and includeForbidden then return {} end
    return plates[unit]
end }
function IsInInstance() return false, "none" end
SlashCmdList = {}
"""


def toc_files():
    toc = open(os.path.join(ROOT, "DoesItLive.toc"), encoding="utf-8").read().splitlines()
    return [line.strip() for line in toc if line.strip() and not line.startswith("#")]


def load_addon(lua):
    """Loads the .toc's files in order, sharing one addon table like WoW does; returns that table."""
    ns = lua.eval("{}")
    load = lua.eval("function(code, name, ns) local fn = assert(loadstring(code, name)); fn('DoesItLive', ns) end")
    for name in toc_files():
        load(open(os.path.join(ROOT, name), encoding="utf-8").read(), "@" + name, ns)
    return ns


def main():
    os.environ["LC_ALL"] = "C"
    lua = lupa51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE_WOW)
    files = toc_files()
    ns = load_addon(lua)
    lua.globals().NS_optionsTabsFit = ns.optionsTabsFit

    script = r"""
    fireEvent("ADDON_LOADED", "DoesItLive")
    local cmd = SlashCmdList.DOESITLIVE
    cmd("help") cmd("probe") cmd("bar 800") tick(0.2) tick(1.1) runTimers() cmd("bar") cmd("bar 0") cmd("msg") cmd("meter") cmd("echo") cmd("echo")
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
    -- The target's bar follows whether the target is friendly.
    local targetArea = TargetFrame.TargetFrameContent.TargetFrameContentMain.HealthBarsContainer
    local function targetRoot()
        for _, f in ipairs(allFrames) do
            if f.over == targetArea and f._parent == UIParent then return f end
        end
        error("no target widget")
    end
    local function targetShown()
        return targetRoot().shown
    end
    cmd("bar 300") assert(targetShown() == false, "shown on an enemy")
    assert(targetRoot().strata == "MEDIUM" and targetRoot().level > 1001, "not above the target frame")
    local levels, seen = 0, {}
    for _, f in ipairs(allFrames) do
        if rawget(f, "strata") and rawget(f, "level") and f.strata ~= "LOW" then
            assert(f.strata == "MEDIUM" and f.level > 1001, "below the unit frames: " .. tostring(f.strata) .. "/" .. tostring(f.level))
            seen[f.level] = (seen[f.level] or 0) + 1
        end
    end
    for level, count in pairs(seen) do
        assert(count == 5, "level " .. level .. " used " .. count .. " times") levels = levels + 1 -- once per unit frame widget
    end
    assert(levels == 11, "layers: " .. levels)
    friendlyTarget = true fireEvent("PLAYER_TARGET_CHANGED") assert(targetShown() == true, "hidden on a friend")
    friendlyTarget = "secret" tick(0.2) assert(targetShown() == false, "shown on an unreadable target")
    friendlyTarget = true tick(0.2) assert(targetShown() == true, "not shown again")
    friendlyTarget = false fireEvent("PLAYER_TARGET_CHANGED") assert(targetShown() == false, "still on an enemy")
    cmd("bar") assert(targetShown() == false, "not hidden by /dil bar")
    -- The focus frame's bar follows whether the focus is friendly, and its setting.
    local focusArea = FocusFrame.TargetFrameContent.TargetFrameContentMain.HealthBarsContainer
    local function focusShown()
        for _, f in ipairs(allFrames) do
            if f.over == focusArea and f._parent == UIParent then return f.shown end
        end
        error("no focus widget")
    end
    cmd("bar 300") assert(focusShown() == false, "shown on an enemy focus")
    friendlyFocus = true fireEvent("PLAYER_FOCUS_CHANGED") assert(focusShown() == true, "hidden on a friendly focus")
    DoesItLiveDB.showFocus = false tick(0.2) assert(focusShown() == false, "shown with the focus frame turned off")
    DoesItLiveDB.showFocus = true tick(0.2) assert(focusShown() == true, "not shown again on the focus")
    friendlyFocus = false fireEvent("PLAYER_FOCUS_CHANGED") assert(focusShown() == false, "still on an enemy focus")
    cmd("bar")
    cmd("bar 300") tick(0.2) cmd("bar")
    -- Friendly nameplates: 1 friendly, 2 enemy, 3 hidden by the client, 4 forbidden, 5 without a bar.
    local function root()
        for _, f in ipairs(allFrames) do
            if f._parent == plates.nameplate1 and rawget(f, "over") == plates.nameplate1.UnitFrame.healthBar then return f end
        end
    end
    local function plateRoots(plate)
        local n = 0
        for _, f in ipairs(allFrames) do if rawget(f, "_parent") == plate then n = n + 1 end end
        return n
    end
    assert(root() and root().shown == false, "plate drawn while the test bar is off")
    cmd("bar 300") assert(root() and root().shown == true, "friendly plate not drawn")
    assert(root().level > 3, "plate bar not above its health bar")
    assert(plateRoots(plates.nameplate2) == 0, "enemy plate drawn")
    assert(plateRoots(plates.nameplate4) == 0, "forbidden plate touched")
    tick(0.2) tick(1.1) runTimers()
    fireEvent("NAME_PLATE_UNIT_REMOVED", "nameplate1") assert(root().shown == false, "removed plate still drawn")
    fireEvent("NAME_PLATE_UNIT_ADDED", "nameplate1") assert(root().shown == true, "plate not drawn again")
    assert(plateRoots(plates.nameplate1) == 1, "plate widget made twice")
    cmd("plates") assert(root().shown == false, "plates off, still drawn") tick(0.2) assert(root().shown == false)
    cmd("plates") assert(root().shown == true, "plates on, not drawn")
    cmd("bar") assert(root().shown == false, "not hidden by /dil bar")
    fireEvent("NAME_PLATE_UNIT_ADDED", "nameplate1") assert(root().shown == false, "drawn while the test bar is off")
    local prd = PersonalResourceDisplayFrame
    PersonalResourceDisplayFrame = nil
    cmd("bar 300") tick(1.1) tick(1.1) cmd("bar")
    PersonalResourceDisplayFrame = prd
    runTimers() runTimers()
    inCombat = false secretHealth = false
    fireEvent("PLAYER_REGEN_ENABLED")
    runTimers() runTimers()
    -- The options window: open it, press every button, slider and menu entry in it, simulate, close it.
    assert(#categories == 1 and categories[1].name == "DoesItLive", "no Options > AddOns page")
    local before = #allFrames
    cmd("")
    assert(_G.DoesItLiveOptions, "no options window")
    assert(#allFrames > before + 50, "window has few frames: " .. (#allFrames - before))
    local pressed = {}
    for _ = 1, 3 do -- menus make new buttons: go round again
        local list = {}
        for i = before + 1, #allFrames do list[#list + 1] = allFrames[i] end
        for _, f in ipairs(list) do
            if not pressed[f] then
                pressed[f] = true
                local s = f._scripts
                if s.OnClick then s.OnClick(f, "LeftButton") end
                if s.OnValueChanged then s.OnValueChanged(f, 37) end
                if s.OnMouseWheel then s.OnMouseWheel(f, 1) end
                if s.OnEnter then s.OnEnter(f) s.OnLeave(f) end
            end
        end
    end
    runTickers(12) runTimers()
    tick(0.2) tick(1.1)
    local fits, rows = NS_optionsTabsFit()
    assert(fits == true and rows == 1, "tabs at 40px text: " .. tostring(fits) .. " " .. tostring(rows))
    cmd("") -- closes it
    cmd("help")
    fireEvent("PLAYER_LOGOUT")
    return #DoesItLiveDB.log
    """
    lines = lua.execute(script)
    log = lua.eval("DoesItLiveDB.log")
    text = "\n".join(log[i] for i in range(1, len(log) + 1))
    for needle in ["SNAPSHOT (manual)", "BAR attach player to", "BAR attach personal to", "BAR attach target to", "BAR target layer: above MEDIUM/1001", "BAR player layer: above MEDIUM/1001 (found LOW/20", "BAR player iconWindow: ",
                   "BAR target state: hidden, unit not friendly", "All settings reset.",
                   "Juicy preset applied.", "Per HoT preset applied.", "Heal bar on friendly nameplates OFF", "BAR target state: shown",
                   "PLATE nameplate1 plate ok, bar UnitFrame.healthBar", "PLATE nameplate3 plate not reachable (forbidden)",
                   "PLATE nameplate4 plate forbidden", "PLATE nameplate5 plate ok, bar not reachable",
                   "friendly nameplates OFF", "friendly nameplates ON",
                   "BAR personal health bar not found", "CAST Rejuvenation", "HEAL CHECK party1", "UNIT_AURA party1",
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
    # Wide tab names (a bigger font, another language): a fresh load whose window has to wrap its tabs.
    wide = lupa51.LuaRuntime(unpack_returned_tuples=True)
    wide.execute(FAKE_WOW)
    wide_ns = load_addon(wide)
    wide.execute('fakeStringWidth = 95 fireEvent("ADDON_LOADED", "DoesItLive") SlashCmdList.DOESITLIVE("")')
    fits, rows = wide_ns.optionsTabsFit()
    if fits is not True or rows < 2:
        print("tabs with wide names: fits", fits, "rows", rows)
        sys.exit(1)
    print(f"OK: {len(files)} file(s) loaded, {lines} log lines, no errors, tabs fit in 1 row (wide names: {rows} rows)")


if __name__ == "__main__":
    main()
