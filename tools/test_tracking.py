"""Drives the HoT tracking with scripted casts, auras and a clock (the fake WoW from test_load.py), and runs Forever's
real tooltips through the parser. Usage: pip install lupa; python tools/test_tracking.py"""

import os
import sys

import lupa.lua51 as lupa51

import test_load

SETUP = r"""
clock = 1000
function GetTime() return clock end
names = { player = { "Joe", "Gg" }, party1 = { "Pal", "Smith" }, target = { "Mob" }, nameplate1 = { "Pal", "Smith" } }
guids = { player = "Player-1", party1 = "Player-2", target = "Creature-9", nameplate1 = "Player-2" }
dead, visible, secretNames = {}, { player = true, party1 = true, nameplate1 = true }, false
function UnitExists(u) return names[u] ~= nil end
function UnitName(u)
    if secretNames then return SECRET, SECRET end
    local n = names[u]
    if n then return n[1], n[2] end
end
function UnitGUID(u) if secretGuids then return SECRET end return guids[u] end
function UnitIsUnit(a, b) return guids[a] == guids[b] end
function UnitCanAssist(_, u) return u ~= "target" or friendlyTarget == true end
function UnitIsDeadOrGhost(u) return dead[u] == true end
function UnitIsVisible(u) return visible[u] == true end
spells = {
    [774] = { "Rejuvenation", "Heals the target for 214 over 12 sec." },
    [139] = { "Renew", "Heals the target of 830 damage over 15 sec." },
    [8936] = { "Regrowth", "Heals a friendly target for 313 to 352 and another 300 over 21 sec." },
    [18562] = { "Swiftmend", "Consumes a Rejuvenation or Regrowth effect on a friendly target to instantly heal them." },
    [48438] = { "Wild Growth", "Heals the target and their party for 679 over 7 sec." },
    [1822] = { "Rake", "Rake the target for 42 damage and an additional 85 damage over 9 sec." },
}
C_Spell = { GetSpellName = function(id) return spells[id] and spells[id][1] end,
            GetSpellDescription = function(id) return spells[id] and spells[id][2] end }
auras = {}  -- unit -> list
C_UnitAuras = { GetAuraDataByIndex = function(unit, i)
    if inCombat then error("Auras cannot be accessed when secret") end
    return (auras[unit] or {})[i]
end }
plates = { nameplate1 = { UnitFrame = { healthBar = CreateFrame("StatusBar") }, GetFrameStrata = function() return "LOW" end } }
local casts = 0
function cast(id, name)
    casts = casts + 1
    fireEvent("UNIT_SPELLCAST_SENT", "player", name, "guid-" .. casts, id)
    fireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid-" .. casts, id)
end
-- A buff list that matches what was just cast (out of combat only).
function aura(unit, id, duration, expiration)
    auras[unit] = auras[unit] or {}
    table.insert(auras[unit], { name = spells[id][1], spellId = id, duration = duration, expirationTime = expiration })
end
function wait(seconds)
    for _ = 1, math.floor(seconds * 10 + 0.5) do clock = clock + 0.1 tick(0.1) end
end
"""

SCENARIO = r"""
local function left(unit) return math.floor(T.remaining(unit) + 0.5) end
local function expect(what, got, wanted) if got ~= wanted then error(what .. ": got " .. tostring(got) .. ", wanted " .. tostring(wanted), 2) end end
local function logged(text)
    for _, line in ipairs(DoesItLiveDB.log) do if line:find(text, 1, true) then return true end end
    return false
end
local function clear() inCombat = false auras = {} clock = clock + 60 T.housekeep() expect("cleared", T.any(), false) end

-- Rejuvenation on yourself in combat: 4 ticks of 53.5, 3 seconds apart.
inCombat = true
cast(774, "Joe Gg")
expect("fresh", left("player"), 214)
expect("not on others", left("party1"), 0)
wait(2.5) expect("before the first tick", left("player"), 214)
wait(1) expect("after one tick", left("player"), 161)
wait(3) expect("after two ticks", left("player"), 107)
-- A recast starts over.
cast(774, "Joe Gg") expect("recast", left("player"), 214)
wait(13.5) expect("ran out", left("player"), 0)
expect("nothing tracked", T.any(), false)
assert(logged("DROP Rejuvenation on Joe Gg: ran out"), "expiry not logged")
assert(logged("ESTIMATE Rejuvenation on Joe Gg (player) recast"), "recast not logged")

-- Two HoTs add up; an empty target is a self-cast; a direct heal isn't counted.
cast(8936, "") cast(774, nil)
expect("Regrowth + Rejuvenation", left("player"), 514)
clear()

-- A party member, by surname, shows on their nameplate too; with the target an enemy of another name.
inCombat = true
cast(139, "Pal Smith")
expect("Renew on the party member", left("party1"), 830)
expect("on their nameplate", left("nameplate1"), 830)
expect("not on you", left("player"), 0)
expect("not on the enemy", left("target"), 0)
wait(3.5) expect("Renew after a tick (5 of 166)", left("party1"), 664)
clear()

-- "Pal" alone isn't "Pal Smith"; a name nobody here has waits for its unit.
inCombat = true
cast(774, "Pal") expect("not the party member", left("party1"), 0)
cast(774, "Far Away") expect("not you", left("player"), 0)
names.party2, guids.party2 = { "Far", "Away" }, "Player-3"
expect("found by name later", left("party2"), 214)
names.party2, guids.party2 = nil, nil
clear()

-- The target is decided when the cast is sent.
inCombat = true
friendlyTarget, names.target, guids.target = true, { "Pal", "Smith" }, "Player-2"
fireEvent("UNIT_SPELLCAST_SENT", "player", "Pal Smith", "late", 774)
names.target, guids.target = { "Mob" }, "Creature-9"
friendlyTarget = false
fireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "late", 774)
expect("sent target", left("party1"), 214)
clear()

-- Secret names: a friendly target takes it, else you do. Secret GUIDs: kept by name.
inCombat, secretNames = true, true
cast(774, SECRET) expect("secret name, enemy target", left("player"), 214)
secretNames = false
clear()
inCombat, secretGuids = true, true
cast(774, "Pal Smith") expect("secret GUID", left("party1"), 214) expect("secret GUID, not you", left("player"), 0)
secretGuids = false
clear()

-- Swiftmend uses the one ending first.
inCombat = true
cast(8936, "Pal Smith") cast(774, "Pal Smith")
expect("before Swiftmend", left("party1"), 514)
cast(18562, "Pal Smith")
expect("after Swiftmend", left("party1"), 300)
assert(logged("DROP Rejuvenation on Pal Smith: used by Swiftmend"), "Swiftmend not logged")
cast(18562, "Joe Gg") expect("Swiftmend elsewhere", left("party1"), 300)
clear()

-- Not HoTs of ours.
inCombat = true
cast(1822, "Mob") cast(48438, "Joe Gg")
expect("Rake and Wild Growth", T.any(), false)
assert(logged("HOT not tracked: Wild Growth"), "Wild Growth not logged")
assert(not logged("HOT not tracked: Rake"), "Rake logged as a HoT")

-- In combat auras can't be read: the HoT stays. Out of combat a HoT whose aura is gone is dropped.
cast(774, "Joe Gg") wait(3.5) expect("unreadable auras keep it", left("player"), 161)
inCombat = false
fireEvent("PLAYER_REGEN_ENABLED")
expect("aura gone", left("player"), 0)
assert(logged("its aura is gone"), "gone aura not logged")

-- A brand-new HoT's aura may be late, and a recast's may still be the old one.
cast(774, "Joe Gg") fireEvent("UNIT_AURA", "player", {}) expect("aura not there yet", left("player"), 214)
aura("player", 774, 12, clock + 12)
wait(6.5) expect("two ticks in", left("player"), 107)
cast(774, "Joe Gg") fireEvent("UNIT_AURA", "player", {})
expect("stale aura doesn't move a recast back", left("player"), 214)
auras = {} aura("player", 774, 12, clock + 12) fireEvent("UNIT_AURA", "player", {}) expect("refreshed", left("player"), 214)

-- An aura ending later than thought moves it; a longer one has more ticks.
auras = {} wait(2) aura("player", 774, 15, clock + 14)
fireEvent("UNIT_AURA", "player", {})
expect("longer aura: 5 ticks", left("player"), 268)
clear()

-- Picked up from its aura (after a /reload), only with a readable expiration.
aura("party1", 139, 15, clock + 9.5)
fireEvent("UNIT_AURA", "party1", {})
expect("found, 4 of 5 ticks left", left("party1"), 664)
assert(logged("FOUND Renew on Pal Smith"), "pickup not logged")
-- Too far away to read: keep it.
visible.party1, visible.nameplate1, auras = false, false, {}
wait(3) assert(left("party1") > 0, "out of range dropped it")
visible.party1, visible.nameplate1 = true, true
-- Dead: gone.
aura("party1", 139, 15, clock + 5) dead.party1, dead.nameplate1 = true, true
wait(1.2) expect("dead", left("party1"), 0)
assert(logged("DROP Renew on Pal Smith: died"), "death not logged")
dead = {}
clear()

-- The bars follow the HoTs.
local function rootOver(area, parent)
    for _, f in ipairs(allFrames) do
        if rawget(f, "over") == area and rawget(f, "_parent") == parent then return f end
    end
end
local playerRoot = rootOver(PlayerFrame.PlayerFrameContent.PlayerFrameContentMain.HealthBarsContainer, UIParent)
local personalRoot = rootOver(PersonalResourceDisplayFrame.HealthBarsContainer.healthBar, UIParent)
assert(playerRoot and personalRoot, "bars never attached")
expect("idle", playerRoot.shown, false)
inCombat = true
cast(774, "Joe Gg")
expect("player frame", playerRoot.shown, true) expect("personal bar", personalRoot.shown, true)
wait(13) expect("player frame after", playerRoot.shown, false) expect("personal bar after", personalRoot.shown, false)
cast(139, "Pal Smith")
expect("player frame, HoT on someone else", playerRoot.shown, false)
local plateRoot = rootOver(plates.nameplate1.UnitFrame.healthBar, plates.nameplate1)
expect("nameplate", plateRoot and plateRoot.shown, true)
fireEvent("NAME_PLATE_UNIT_REMOVED", "nameplate1") expect("plate gone", plateRoot.shown, false)
fireEvent("NAME_PLATE_UNIT_ADDED", "nameplate1") expect("plate back", plateRoot.shown, true)
SlashCmdList.DOESITLIVE("plates") wait(0.3) expect("plates off", plateRoot.shown, false)
SlashCmdList.DOESITLIVE("plates") wait(0.3) expect("plates on", plateRoot.shown, true)
-- Settings: a place turned off, a spell left out, then back.
DoesItLiveDB.showPlates = false NS.display.settingsChanged() wait(0.3) expect("plates setting off", plateRoot.shown, false)
DoesItLiveDB.showPlates = true NS.display.settingsChanged() wait(0.3) expect("plates setting on", plateRoot.shown, true)
DoesItLiveDB.spellRenew = false NS.display.settingsChanged() wait(0.3) expect("Renew left out", plateRoot.shown, false)
expect("still tracked", left("party1"), 830)
DoesItLiveDB.spellRenew = true NS.display.settingsChanged() wait(0.3) expect("Renew back", plateRoot.shown, true)
wait(16) expect("nameplate after", plateRoot.shown, false)
-- Every bar option at once, with time moving: a color per HoT, outline, effects, then back to the defaults.
for key, value in pairs({ hotColors = "bySpell", fillTexture = "stripes", scrollStripes = true, outlineStyle = "dashed",
    dashLength = 8, showGlow = true, showShine = true, showSpark = true, pulseOutline = true, showText = true,
    textPosition = "above", topOffIcon = "leaf", iconPulse = true, smoothMotion = true }) do DoesItLiveDB[key] = value end
NS.display.settingsChanged()
cast(774, "Joe Gg") cast(8936, "Joe Gg")
expect("both HoTs", left("player"), 514)
local sum, parts = T.breakdown("player")
expect("breakdown total", math.floor(sum + 0.5), 514)
expect("breakdown order", parts[1].name .. "," .. parts[2].name, "Rejuvenation,Regrowth")
wait(4) expect("per HoT bar", playerRoot.shown, true)
DoesItLiveDB.fillTexture = "gradient" DoesItLiveDB.hotColors = "single" NS.display.settingsChanged() wait(1)
DoesItLiveDB.smoothMotion = false NS.display.settingsChanged() wait(1)
SlashCmdList.DOESITLIVE("bar 300") wait(0.5) SlashCmdList.DOESITLIVE("bar") -- the test bar has no per-HoT parts
for key, value in pairs(NS.DEFAULTS) do DoesItLiveDB[key] = value end
NS.display.settingsChanged()
wait(25) expect("all gone", playerRoot.shown, false)
-- The manual override, and back to the HoTs.
SlashCmdList.DOESITLIVE("bar 800") expect("override", playerRoot.shown, true)
SlashCmdList.DOESITLIVE("bar") expect("override off", playerRoot.shown, false)
cast(774, "Joe Gg") SlashCmdList.DOESITLIVE("hots")
assert(logged("Rejuvenation on Joe Gg: 214 left (4 of 4 ticks of 53.5)"), "/dil hots")
for _, line in ipairs(DoesItLiveDB.log) do assert(not line:find("ERROR", 1, true) or line:find("Auras cannot", 1, true), line) end
"""

TOOLTIPS = [
    ("Heals the target for 776 over 12 sec.", 776, 12),
    ("Heals the target for 214 over 12 sec.", 214, 12),
    ("Heals the target of 830 damage over 15 sec.", 830, 15),
    ("Heals a friendly target for 965 to 1077 and another 994 over 21 sec.", 994, 21),
    ("Heals a friendly target for 313 to 352 and another 300 over 21 sec.", 300, 21),
    ("Heals a friendly target for 799 to 883, an additional 805 over 15 sec, and increases the effectiveness of your "
     "Chain Heal casts directly on that target by 25%.", 805, 15),
    ("Heals the target for 1,776 over 12 sec.", 1776, 12),
    ("Heals the target and their party for 679 over 7 sec. Party members must be within 43.5 yards of target.", 679, 7),
    ("Heals a friendly target for 313 to 352.", None, None),
    ("", None, None),
]


def main():
    lua = lupa51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(test_load.FAKE_WOW)
    lua.execute(SETUP)
    ns = test_load.load_addon(lua)
    lua.globals().T = ns.tracking
    lua.globals().NS = ns
    lua.execute('fireEvent("ADDON_LOADED", "DoesItLive")')
    for desc, total, seconds in TOOLTIPS:
        result = ns.tracking.parseHot(desc)
        got = result if isinstance(result, tuple) else (result, None)
        if got != (total, seconds):
            print(f"PARSE {desc!r}: got {got}, wanted {(total, seconds)}")
            sys.exit(1)
    try:
        lua.execute(SCENARIO)
    except lupa51.LuaError as e:
        log = lua.eval("DoesItLiveDB.log")
        print("\n".join(log[i] for i in range(max(1, len(log) - 25), len(log) + 1)))
        print("FAILED:", str(e).splitlines()[0])
        sys.exit(1)
    print(f"OK: {len(TOOLTIPS)} tooltips and the tracking scenario")


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
