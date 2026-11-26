# DoesItLive

A World of Warcraft: **Forever** addon, the sister of **DoesItDie** (`swirllyman/DoesItDie`, folder
`..\WillItDie`). DoesItDie shows how much damage the player's DoTs still have to deal on an enemy and whether that
kills it. DoesItLive is the same for the player's **HoTs** on friendly units:

- a **heal segment** on the unit's health bar, starting where the green ends, covering the healing the HoTs still
  have to do; **overheal** is drawn in another color over the end of the green (nothing hangs past the bar);
- a **tops off icon** inside the bar's right end when the HoTs will fill the bar;
- the remaining heal as text (`+830`).

The plan (feasibility, display geometry, tracking, how it stays out of DoesItDie's way, names) is the Claude Doc
"HoT sister addon: investigation and plan": https://claude.ai/artifact/9KteECaoLA27jSYtqEnywS

## Status

The bars follow your HoTs (Rejuvenation, Regrowth, Renew, Riptide), with an options window (`/dil`). The Bloom
talent (Forever, Restoration, 1 rank: Rejuvenation and Regrowth heal for 100% of your Spirit when they run their full
duration, 50% when dispelled) adds Spirit to each one's remaining heal until it ends (`tracking.updateBloom`: talent
from `GetTalentInfo`, else `IsPlayerSpell` on the spell found by name; Spirit from `UnitStat` out of combat, cached for
combat; `BLOOM` log line). Unverified in-game: the talent lookup and that the bloom heals exactly your Spirit. Verified
in-game: the bars on the player frame, friendly target frame and personal resource display, and the tracking (Joe,
2026-11-22: "looks like it's working"). **Not** yet verified in-game: friendly nameplates (name-only plates have no
bar to draw on: `nameplateShowOnlyNameForFriendlyPlayerUnits`), the options window and the bar options (fill
styles, a color per HoT, outline, effects). Missing: Wild Growth, other
players' HoTs, custom health bars (DoesItDie's Frames.lua and Pick mode).

| File | What |
|---|---|
| `DoesItLive/Probe.lua` | Log, helpers shared through the addon table (`ns.out`, `ns.isSecret`...), the probe, all events and `/dil`. Loaded first |
| `DoesItLive/Settings.lua` | `ns.DEFAULTS` (filled into `DoesItLiveDB` on load), the options' choice lists, `ns.setting(key)` |
| `DoesItLive/Tracking.lua` | HoTs per unit (kept by GUID, else by name): casts, tooltips, timing, corrections from auras out of combat. `ns.tracking.remaining(unit)` |
| `DoesItLive/Display.lua` | The bars and which frames they sit on (player, personal bar, target, pet, friendly nameplates, and Blizzard's party/raid CompactUnitFrames: scanned by name once a second and on GROUP_ROSTER_UPDATE, widgets only for frames whose unit has heals), in the settings' look; also on the options preview's mock bars (`display.setPreview`). `ns.display`; `display.settingsChanged()` after any setting change |
| `DoesItLive/Options.lua` | The options window (`/dil`), built like DoesItDie's: live preview (mock player frame and nameplate drawn by Display.lua, two sample HoTs), tabs (Show on, Bar, Outline, Effects, Overheal & icon, Text, Advanced), presets, hand-built controls; plus a page in Options > AddOns that opens it. One look for every place (DoesItDie splits nameplates because enemy plates are red; friendly ones are green like the frames) |
| `DoesItLive/Frames.lua` | From DoesItDie: frame paths (`ns.resolveFramePath`, `ns.framePath`), Pick mode, `ns.betterBlizzHealthBar`. Display.lua finds each bar in order: the Advanced tab's custom path, EllesmereUI's frame (`EllesmereUIUnitFrames_<Player|Target|Pet>.Health`; player and pet names unverified, `ADDON EllesmereUI frames:` in the log lists what exists), BetterBlizzFrames' bar, Blizzard's. Nameplates in DoesItDie's order (custom keys, EllesmereUI's plate, Platynator, Threat Plates, Blizzard's, automatic search). Bars that fill right to left aren't supported. Third-party raid frames (ElvUI, Cell, VuhDo, Grid2) aren't either |
| `DoesItLive/Textures/`, `tools/make_textures.py` | Dash, stripes, spark and shine textures, made by the script (adapted from DoesItDie's). New files need a full client restart |

## What the probe found (Forever 1.60.1, druid 35, 2026-11-22)

- Current and missing health, `UnitGetIncomingHeals` and `UNIT_COMBAT` heal amounts are secret in **and out** of
  combat for the player; max health is readable for yourself (secret for the nameplates seen). So ticks can't be
  measured, and `HEAL CHECK` (question 5) never runs.
- `UNIT_COMBAT` heals do fire per tick, with a readable action and flag (`CRITICAL`), also for target and nameplates.
- Own casts: spell, target name and tooltip are readable in combat. The name includes the surname ("Joe Gg") where
  `UnitName` returns "Joe", "Gg".
- Auras and `GetSpellBonusHealing` are readable out of combat only.
- The damage meter's healing totals are readable after combat, and match the **tooltips**, which already include
  bonus healing (13 then): don't add it again. Rejuvenation 214: meter 53 for one tick, 215 for four, 241 with a crit
  (HoTs crit, 1.5x). Regrowth 313-352 + 300: 624.

## Why it's built the way it is

Forever runs the modern (Midnight-era) client: many combat values are **secret** (shown, but not compared or used
in math). DoesItDie's CLAUDE.md has the verified table for enemies. The rules that carry over:

- Never compute "does it top off" in Lua. Feed secret values (max health) into `StatusBar` widgets and let the
  geometry answer: a heal bar the health bar's size, `max` = max health, `value` = remaining heal, pinned to the end
  of the green fill (`healthBar:GetStatusBarTexture()`) and clipped to the bar, is the effective part (a color
  per HoT: running-total bars, each segment from the end of the one before, as DoesItDie's per-DoT colors). A
  reverse-filled bar over the host spans its last `heal`; its overlap with the green is the overheal, drawn as a
  strip along the bottom so the end of the green stays readable. The icon rides
  a 10000px fill of `heal` out of `UnitHealthMissing` (from -1, so full health isn't an empty range), which stops at
  full width once it tops off. Effects around the heal (outline, glow, flash,
  spark, shine, stripes) sit inside the bar's clip, so the glow fades inward; every texture in it gets the mask. Don't chain health + heal bars for the icon: that end keeps moving with overheal and
  the icon slides out of its window.
- Forever's player health bar is 20 tall but masked to its 15 tall `HealthBarsContainer`: clip to the container and
  add its `HealthBarMask` to our textures. The bars under the character are
  `PersonalResourceDisplayFrame.HealthBarsContainer.healthBar` (Blizzard_PersonalResourceDisplay, with its own
  scale). Layer above the whole unit frame's highest readable strata/level (rechecked every second) and never below
  MEDIUM/1001 (verified in-game: above LOW/1001, the player frame's whole tree, it didn't show), never the bar's own
  level plus something, and give each of our frames its own level. Blizzard's Forever UI source: the `forever` branch of `Gethe/wow-ui-source`.
- Estimate HoTs from casts (`UNIT_SPELLCAST_SENT/SUCCEEDED`, target by the sent name, decided at SENT) and tooltips
  (`C_Spell.GetSpellDescription`, nothing added), corrected from auras out of combat. Right after a recast the aura
  list can still hold the old aura: don't move a HoT back on that.
- Registering `COMBAT_LOG_EVENT_UNFILTERED` is forbidden (blocked action popup).
- Guard every value that might be secret with `isSecret()` before comparing or indexing with it.

## Probe questions (`/dil`)

| # | Question | Where in `Probe.lua` | Log lines |
|---|---|---|---|
| 1 | Friendly health / max health / `UnitHealthMissing` / `UnitHealthPercent` secret in and out of combat? | `probeUnit` | `UnitHealth=` |
| 2 | Does `UnitGetIncomingHeals` exist, is it secret, does it count HoTs? | `probeUnit`, `onOwnCast` (+0.3 s, +3.5 s) | `PREDICT` |
| 3 | Friendly auras readable (caster, id, expiry, points)? | `probeAuras` | `[HELPFUL...]` |
| 4 | `GetSpellBonusHealing` in and out of combat | `snapshot` | `GetSpellBonusHealing=` |
| 5 | `UNIT_COMBAT` `HEAL` on player/party/raid: amount, school; does the amount include overheal? | `onUnitCombat`, `onUnitHealth` | `UNIT_COMBAT`, `HEAL CHECK` |
| 6 | Own HoT cast: spell, target, tooltip | `onOwnCast` | `CAST` |
| 7 | Party/raid members' casts readable in combat (others' HoTs)? | `onOtherCast` | `OTHER CAST` |
| 8 | `UNIT_AURA` payloads on friendly units | `onUnitAura` | `UNIT_AURA` |
| 9 | Addon messages in combat (HealComm-style sharing)? | `sendTestMessage` | `ADDONMSG` |
| 10 | Damage meter healing / absorb totals after combat, and the row fields (overheal?) | `readMeter` | `METER` |
| 11 | Heal bar geometry on the player frame, personal resource display, friendly target frame and friendly nameplates (`/dil plates`; `PLATE` lines log which plates are reachable, in and out of instances) | `/dil bar <n>` | `BAR` |

Suggested session: a druid or priest in a party. `/dil probe` out of combat, `/dil bar 800` at partial health, cast
Rejuvenation/Renew on yourself and a party member out of combat (heal check), then a few pulls healing with HoTs.
`/reload`, then read `WTF\Account\<account>\SavedVariables\DoesItLive.lua`.

## Living alongside DoesItDie

Never draw on the same unit at the same time: DoesItDie only on units you can attack, DoesItLive only on units you
can assist. DoesItLive's icon goes at the bar's right end (never the portrait), its default icon is a plus (never
DoesItDie's skull, X, checkmark or sunglasses), its colors are teal (effective) and pale blue (overheal), never red,
gold or white stripes. Own names everywhere: `/dil`, `DoesItLive*` globals, `DoesItLiveDB`, own textures.

## Working on it

- **Game install:** `C:\Program Files (x86)\World of Warcraft\_forever_\`. Junction
  `Interface\AddOns\DoesItLive` to this repo's `DoesItLive/` so edits are live (`/reload`; new files need a restart).
- **Tests:** `pip install lupa`, then `python tools/test_load.py` (loads the .toc in Lua 5.1 with a fake WoW API,
  fires every event and command with plain and secret values, opens the options window and presses every control) and `python tools/test_tracking.py` (scripted
  casts, auras and time, and Forever's HoT tooltips from DoesItDie's `tools/data/forever_spellbook.json`).
- **Releasing:** add notes to `CHANGELOG.md`, push a `v*` tag. Add `## X-Curse-Project-ID:` to the .toc once the
  CurseForge project exists, and the `CF_API_KEY` secret to the repo.
- **Gotchas** (from DoesItDie): WoW runs Lua 5.1 (`lupa.lua51` in tests). Bash heredocs collapse backslashes, which
  breaks texture paths like `"Interface\\Buttons\\WHITE8X8"`: edit Lua with file tools and grep `Interface` after
  scripted edits. Lua allows 200 locals per scope.
