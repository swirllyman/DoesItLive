# DoesItLive

## Unreleased

- **Bloom:** with the Restoration talent Bloom, your Rejuvenation and Regrowth count the heal they give as they run
  out (your Spirit) in the healing still to come. Spirit is read out of combat; Swiftmend or a recast ends a HoT without
  it. Turn it off under What to track > Bloom talent.

## v0.1.0

The first release of DoesItLive, the sister addon of DoesItDie: it shows how much healing your HoTs still have to do,
right on the health bar, and whether they'll top the target off.

- **Heal bar:** from the end of the green, the healing your HoTs still have coming, shrinking with every tick. The
  part that would go past full health shows as a thin overheal strip along the bottom, so your real health stays
  readable, and a plus appears at the bar's right end when your HoTs will fill it.
- **Everywhere you heal:** your player frame, the bars under your character (personal resource display), a friendly
  target, your pet's frame, Blizzard's party and raid frames (pet rows too) and friendly nameplates. Friendly players'
  nameplates need their health bars on: untick "show only name" under friendly players in Options > Nameplates.
- **What it tracks**, in groups you can turn on and off: HoTs on others (Rejuvenation, Regrowth, Renew, Riptide, Wild
  Growth), heals on yourself (Siphon Life, Drain Life, Devouring Plague), heals on your pet (Mend Pet, Health Funnel),
  group and placed heals (Healing Stream Totem, a Lightwell's renew, Penance), and bandages, food and anything else
  whose tooltip heals over time. Amounts come from the tooltips, which already include your bonus healing. Wild
  Growth's shrinking ticks, and which party members it reached, are estimated.
- **Settings window** (`/dil`, or Options > AddOns > DoesItLive) with a live preview and presets (Default, Subtle, Per
  HoT, Juicy): where it shows, what it tracks, fill style, one color or a color per HoT, outline, effects (smooth
  motion, flash and spark when a HoT lands, glow, shine, scrolling stripes), the overheal strip, the tops-off icon and
  an optional `+830` text.
- **Works with other addons** like DoesItDie: EllesmereUI's unit frames and nameplates, BetterBlizzFrames' health bars,
  and Platynator, Threat Plates, Plater and other nameplate addons. For any other unit frame addon, pick its health
  bar on the Advanced tab.
- `/dil hots` lists the heals being tracked; `/dil bar 800` shows a fixed amount to try out the look.
