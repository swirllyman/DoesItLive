# Changelog

## Unreleased

- Diagnostic probe (`/dil`): logs what the game lets addons read about healing on friendly units.
- Shows what your Rejuvenation, Regrowth, Renew and Riptide still have to heal, on you, a friendly target and friendly
  nameplates. `/dil hots` lists them.
- Options window (`/dil`, or Options > AddOns > DoesItLive) with a live preview: where it shows, which HoTs count,
  colors, overheal strip, tops-off icon, heal text (`+830`) and presets.
- Bar options like DoesItDie's: fill style (flat, health bar, raid bar, stripes, fade), a color per HoT with
  dividers, outline (solid or dashed, thickness, color, opacity, pulse), smooth motion, flash and spark when a HoT
  lands, glow, shine sweep, scrolling stripes.
- Tracks every heal over time, in groups you can turn on and off ("What to track"): HoTs on others (now with Wild
  Growth), heals on yourself (Siphon Life, Drain Life, Devouring Plague), on your pet (Mend Pet, Health Funnel, on the
  pet frame), group and placed (Healing Stream Totem, Lightwell's renew, Penance), and bandages, food and anything else
  whose tooltip heals over time. A color per spell on the "HoT colors" tab.
- Also on Blizzard's party and raid frames (pet rows too), and on your pet's frame.
- Works with EllesmereUI's unit frames and nameplates, BetterBlizzFrames' health bars, and Platynator, Threat Plates,
  Plater and other nameplate addons (DoesItDie's support). Advanced tab: custom health bars with Pick, for others.
- `/dil bar <n>` test heal bar: fits inside the health bar, and also shows on the personal resource display, a friendly target's frame and friendly nameplates (`/dil plates` turns those off).
