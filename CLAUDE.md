# DoesItLive

A World of Warcraft: **Forever** addon, the sister of **DoesItDie** (`swirllyman/DoesItDie`, folder
`..\WillItDie`). DoesItDie shows how much damage the player's DoTs still have to deal on an enemy and whether that
kills it. DoesItLive is the same for the player's **HoTs** on friendly units:

- a **heal segment** on the unit's health bar, starting where the green ends, covering the healing the HoTs still
  have to do; the part that hangs past the full bar is **overheal**, drawn in another color;
- a **tops off icon** at the bar's right end when the HoTs will fill the bar;
- the remaining heal as text (`+830`).

The plan (feasibility, display geometry, tracking, how it stays out of DoesItDie's way, names) is the Claude Doc
"HoT sister addon: investigation and plan": https://claude.ai/artifact/9KteECaoLA27jSYtqEnywS

## Status

**Probe only.** `DoesItLive/Probe.lua` logs what addon code can read about healing on friendly units, in and out of
combat. Nothing is verified in-game yet. The real addon gets built once a probe log is in.

## Why it's built the way it is

Forever runs the modern (Midnight-era) client: many combat values are **secret** (shown, but not compared or used
in math). DoesItDie's CLAUDE.md has the verified table for enemies. The rules that carry over:

- Never compute "does it top off" in Lua. Feed secret values (max health) into `StatusBar` widgets and let the
  geometry answer: a heal bar the health bar's size, `max` = max health, `value` = remaining heal, pinned to the end
  of the green fill (`healthBar:GetStatusBarTexture()`); a clip frame over the bar shows the effective part, a clip
  frame past its right end shows the overheal, and an icon riding the fill's end inside a clip window past the end
  only shows when it tops off.
- Estimate HoTs from casts (`UNIT_SPELLCAST_SENT/SUCCEEDED`, target by the sent name) and tooltips
  (`C_Spell.GetSpellDescription`), plus bonus healing read out of combat (`GetSpellBonusHealing`), corrected by
  observed `UNIT_COMBAT` `HEAL` ticks (out of combat) and the damage meter's healing totals after combat.
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
| 11 | Heal bar geometry on the player frame with secret max health | `/dil bar <n>` | `BAR` |

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
  fires every event and command with plain and secret values).
- **Releasing:** add notes to `CHANGELOG.md`, push a `v*` tag. Add `## X-Curse-Project-ID:` to the .toc once the
  CurseForge project exists, and the `CF_API_KEY` secret to the repo.
- **Gotchas** (from DoesItDie): WoW runs Lua 5.1 (`lupa.lua51` in tests). Bash heredocs collapse backslashes, which
  breaks texture paths like `"Interface\\Buttons\\WHITE8X8"`: edit Lua with file tools and grep `Interface` after
  scripted edits. Lua allows 200 locals per scope.
