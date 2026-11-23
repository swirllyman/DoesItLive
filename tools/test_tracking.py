"""Drives the HoT tracking with scripted casts, auras and a clock (the fake WoW from test_load.py), and runs Forever's
real tooltips through the parser. Usage: pip install lupa; python tools/test_tracking.py"""

import os
import sys

import lupa.lua51 as lupa51

import test_load

SETUP = r"""
clock = 1000
function GetTime() return clock end
names = { player = { "Joe", "Gg" }, party1 = { "Pal", "Smith" }, target = { "Mob" }, nameplate1 = { "Pal", "Smith" },
          pet = { "Wolf" } }
guids = { player = "Player-1", party1 = "Player-2", target = "Creature-9", nameplate1 = "Player-2", pet = "Pet-1" }
dead, visible, secretNames = {}, { player = true, party1 = true, nameplate1 = true, pet = true }, false
totems = {}
function GetTotemInfo(slot) local name = totems[slot] return name ~= nil, name end
PetFrameHealthBar, PetFrame = CreateFrame("StatusBar"), {}
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
function UnitInParty(u) return u == "player" or u == "party1" end
function UnitInRaid() return nil end
spells = {
    [774] = { "Rejuvenation", "Heals the target for 214 over 12 sec." },
    [139] = { "Renew", "Heals the target of 830 damage over 15 sec." },
    [8936] = { "Regrowth", "Heals a friendly target for 313 to 352 and another 300 over 21 sec." },
    [18562] = { "Swiftmend", "Consumes a Rejuvenation or Regrowth effect on a friendly target to instantly heal them." },
    [48438] = { "Wild Growth", "Heals the target and their party for 679 over 7 sec. Party members must be within 43.5 "
        .. "yards of target. The amount healed is applied quickly at first, and slows down as Wild Growth reaches its full duration." },
    [1822] = { "Rake", "Rake the target for 42 damage and an additional 85 damage over 9 sec." },
    [18265] = { "Siphon Life", "Transfers 41 health from the target to the caster every 3 sec. Lasts 30 sec." },
    [689] = { "Drain Life", "Transfers 51 health every 1 second from the target to the caster. Lasts 5 sec." },
    [2944] = { "Devouring Plague", "Afflicts the target with a disease that causes 848 Shadow damage over 24 sec. "
        .. "Damage caused by the Devouring Plague heals the caster." },
    [136] = { "Mend Pet", "Heals your pet 245 health every second while you focus. Lasts 5 sec." },
    [755] = { "Health Funnel", "Gives 153 health to the caster's pet every second for 10 sec as long as the caster channels. "
        .. "Generates reduced threat." },
    [5394] = { "Healing Stream Totem", "Summons a Healing Stream Totem with 5 health at the feet of the caster for 5 min "
        .. "that heals group members within 30 yards for 11 every 2 seconds." },
    [47540] = { "Penance", "Launches a volley of holy light at the target, causing 131 Holy damage to an enemy, or 673 "
        .. "healing to an ally, instantly and every 1 sec for 2 sec." },
    [724] = { "Lightwell", "Creates a holy Lightwell near the priest. Members of your raid or party can click the "
        .. "Lightwell to restore 1600 health over 10 sec. Being attacked cancels the effect." },
    [7001] = { "Lightwell Renew", "Restores 1600 health over 10 sec." },
    [746] = { "First Aid", "Heals 2,000 damage over 8 sec." },
    [433] = { "Food", "Restores 2148 health over 30 sec. Must remain seated while eating." },
    [438] = { "Restore Mana", "Restores 1500 mana over 24 sec." },
    [57946] = { "Contingency Plan", "Place a Holy ward on an ally for 30 sec. The next time this ally takes damage dropping "
        .. "their Health below 35%, they will gain a shield absorbing ? damage and begin healing for ? Health over 6 sec." },
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

-- Not a HoT of ours.
inCombat = true
cast(1822, "Mob")
expect("Rake", T.any(), false)
assert(not logged("HOT not tracked: Rake"), "Rake logged as a HoT")

-- Wild Growth: front-loaded ticks adding up to the tooltip, on you at once and on a party member healed a second later.
cast(48438, "Joe Gg")
expect("Wild Growth on you", left("player"), 679)
assert(logged("front-loaded: first 126.1, last 67.9"), "shape not logged")
expect("not on the party member yet", left("party1"), 0)
wait(0.3) fireEvent("UNIT_COMBAT", "party1", "HEAL", "", SECRET, 1) expect("too early to count", left("party1"), 0)
wait(0.8) fireEvent("UNIT_COMBAT", "party1", "HEAL", "", SECRET, 1)
fireEvent("UNIT_COMBAT", "nameplate1", "HEAL", "", SECRET, 1) -- the same heal through their nameplate
expect("reached the party member after its first tick", left("party1"), 553)
expect("you after the first tick", left("player"), 553)
assert(logged("SPREAD Wild Growth reached Pal Smith"), "spread not logged")
wait(1) expect("second tick (116)", left("player"), 437)
wait(5) expect("gone after 7 ticks", left("player"), 0) expect("party member too", left("party1"), 0)
-- Too late, an enemy target outside your group, a heal on someone outside it: none of them reach anyone.
cast(48438, "Joe Gg") wait(2) fireEvent("UNIT_COMBAT", "party1", "HEAL", "", SECRET, 1) expect("too late", left("party1"), 0)
friendlyTarget, names.target, guids.target = true, { "Far", "Away" }, "Player-3" -- a friend outside your party
cast(48438, "Far Away") wait(1.1) fireEvent("UNIT_COMBAT", "party1", "HEAL", "", SECRET, 1)
expect("outside your group", left("party1"), 0) expect("but on its target", left("target"), 679 - 126)
friendlyTarget, names.target, guids.target = false, { "Mob" }, "Creature-9"
clear()
inCombat = true

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

-- Heals on yourself from draining spells, whoever the target is.
inCombat = true
cast(18265, "Mob") expect("Siphon Life on you", left("player"), 410) expect("not on the mob", left("target"), 0)
cast(2944, "Mob") expect("plus Devouring Plague", left("player"), 1258)
cast(689, "Mob") expect("plus Drain Life", left("player"), 1513)
wait(2.5) fireEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c", 689)
expect("Drain Life stops with the channel (none of the others ticked yet)", left("player"), 1258)
assert(logged("DROP Drain Life on Joe Gg: channel ended"), "channel end not logged")
inCombat = false fireEvent("PLAYER_REGEN_ENABLED")
expect("no aura of theirs on you: kept", left("player"), 1258)
clear()

-- Your pet.
inCombat = true
cast(136, "Wolf") expect("Mend Pet", left("pet"), 1225) expect("not on you", left("player"), 0)
cast(755, "") expect("plus Health Funnel, whatever the target", left("pet"), 2755)
wait(1.5) fireEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c", 755)
expect("Health Funnel stops", left("pet"), 1225 - 245)
clear()

-- The totem: the next 5 ticks, on you and your party, until it's gone.
inCombat = true
totems[3] = "Healing Stream Totem"
cast(5394, "") expect("totem on you", left("player"), 55) expect("totem on the party", left("party1"), 55)
wait(30) expect("still 5 ticks ahead", left("player"), 55)
totems[3] = nil fireEvent("PLAYER_TOTEM_UPDATE") expect("totem gone", left("player"), 0) expect("party too", left("party1"), 0)

-- Penance: only on a friend, the two hits after the first; ends with the channel.
cast(47540, "Mob") expect("Penance on an enemy", T.any(), false)
cast(47540, "Pal Smith") expect("Penance on a friend", left("party1"), 1346)
fireEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c", 47540) expect("Penance ends", left("party1"), 0)

-- Placing a Lightwell heals nobody; its renew does. Contingency Plan and mana aren't tracked.
cast(724, "") cast(57946, "Pal Smith") cast(438, "")
expect("Lightwell, Contingency Plan, mana", T.any(), false)
cast(7001, "") expect("Lightwell's renew", left("player"), 1600)
clear()

-- Bandages and food: from their tooltips. A bandage ends with its channel; food when its buff goes.
inCombat = true
cast(746, "Pal Smith") expect("bandage on a friend", left("party1"), 2000)
assert(logged("ESTIMATE First Aid on Pal Smith (party1): 2000 over 8s, 8 ticks of 250.0 every 1s"), "bandage ticks")
fireEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c", 746) expect("bandage interrupted", left("party1"), 0)
inCombat = false
cast(433, "") expect("eating", left("player"), 2148)
aura("player", 433, 30, clock + 30) wait(4) expect("still eating", left("player"), 2148 - 215)
auras = {} wait(1.2) expect("stood up", left("player"), 0)
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
local petRoot = rootOver(PetFrameHealthBar, UIParent)
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
-- The pet frame, and a group turned off.
wait(16) cast(136, "Wolf") expect("pet frame", petRoot.shown, true) expect("player frame", playerRoot.shown, false)
DoesItLiveDB.catPet = false NS.display.settingsChanged() wait(0.3) expect("pet heals off", petRoot.shown, false)
DoesItLiveDB.catPet = true NS.display.settingsChanged() wait(0.3) expect("pet heals on", petRoot.shown, true)
DoesItLiveDB.spellMendPet = false NS.display.settingsChanged() wait(0.3) expect("Mend Pet off", petRoot.shown, false)
DoesItLiveDB.spellMendPet = true DoesItLiveDB.showPet = false NS.display.settingsChanged() wait(0.3)
expect("pet frame off", petRoot.shown, false)
DoesItLiveDB.showPet = true NS.display.settingsChanged()
fireEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c", 136)
-- Party and raid frames: only frames whose unit has heals get one, and frames handed another unit follow it.
local function compact(unit) return { unit = unit, healthBar = CreateFrame("StatusBar") } end
CompactPartyFrameMember1, CompactPartyFrameMember2, CompactRaidFrame3 = compact("player"), compact("party1"), compact("party2")
local function raidRoot(frame) return rootOver(frame.healthBar, UIParent) end
cast(139, "Pal Smith") wait(1.2)
expect("party member's frame", raidRoot(CompactPartyFrameMember2) and raidRoot(CompactPartyFrameMember2).shown, true)
expect("no frame for you (nothing on you)", raidRoot(CompactPartyFrameMember1), nil)
expect("none for an empty unit", raidRoot(CompactRaidFrame3), nil)
CompactPartyFrameMember2.unit, CompactRaidFrame3.unit = "party2", "party1" -- the group was reordered
fireEvent("GROUP_ROSTER_UPDATE")
expect("old frame let go", raidRoot(CompactPartyFrameMember2).shown, false)
expect("new frame", raidRoot(CompactRaidFrame3) and raidRoot(CompactRaidFrame3).shown, true)
DoesItLiveDB.showRaid = false NS.display.settingsChanged() expect("raid frames off", raidRoot(CompactRaidFrame3).shown, false)
DoesItLiveDB.showRaid = true NS.display.settingsChanged() expect("raid frames on", raidRoot(CompactRaidFrame3).shown, true)
cast(136, "Wolf") CompactPartyFramePet1 = compact("pet") wait(1.2)
expect("pet row", raidRoot(CompactPartyFramePet1) and raidRoot(CompactPartyFramePet1).shown, true)
fireEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c", 136)
wait(16) expect("all gone", raidRoot(CompactRaidFrame3).shown, false)
CompactPartyFrameMember1, CompactPartyFrameMember2, CompactRaidFrame3, CompactPartyFramePet1 = nil, nil, nil, nil

-- More HoTs than segments, with a color per HoT.
DoesItLiveDB.hotColors = "bySpell" NS.display.settingsChanged()
cast(774, "Joe Gg") cast(8936, "Joe Gg") cast(18265, "Mob") cast(2944, "Mob") cast(7001, "") cast(433, "")
cast(746, "Joe Gg") totems[3] = "Healing Stream Totem" cast(5394, "") cast(48438, "Joe Gg")
local _, many = T.breakdown("player")
expect("nine kinds on you", #many, 9)
expect("in the options' order", many[1].name .. "," .. many[9].name, "Rejuvenation,Food")
wait(0.5) expect("drawn", playerRoot.shown, true)
fireEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c", 746) totems[3] = nil fireEvent("PLAYER_TOTEM_UPDATE")
DoesItLiveDB.hotColors = "single" NS.display.settingsChanged()
wait(31)

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
    shape = lua.eval("function(T) local hot = { frontLoaded = true, ticks = 7 } local sum = 0 "
                     "for i = 1, 7 do sum = sum + T.tickWeight(hot, i) end return sum end")(ns.tracking)
    if abs(shape - 7) > 1e-9:
        print("Wild Growth's ticks don't add up:", shape)
        sys.exit(1)
    print(f"OK: {len(TOOLTIPS)} tooltips and the tracking scenario")


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
