# DruidKite for RGMercs

DruidKite is an RGMercs user module that turns a solo Druid into a stop and cast kiter. It is a separate module from BardKite. A Druid cannot cast while moving, so instead of running the whole fight, DruidKite runs a circle only until the mob falls behind, stops so RGMercs can cast, and runs again when the mob catches up. RGMercs still picks and casts the spells.

## What DruidKite does

1. Waits paused until you press Start. You also get a PAUSE button, and every pause stops the circle.
2. Pulls the nearest NPC in range and level window with the spell in your chosen gem. Ensnare or a DoT works well.
3. When a mob is on you and within Cast Distance, runs `/circle` around your anchor point through MQ2MoveUtils.
4. When every mob on you is at Cast Distance or farther, stops the circle and stands still so RGMercs can cast DoTs, nukes and snare.
5. When any mob comes within Run Distance, runs again, even mid cast.
6. Pulls more mobs only while you have fewer than DKMaxHaters on you (the train guard).
7. When nothing is on you, stops the circle and waits DKLootWait seconds so a loot tool can loot. Then it walks back to the anchor with `/moveto`.
8. Rests and sits to med before the next pull when HP or mana is below your rest levels.
9. Holds pulls while a GM or a player who is not in your group or friends list is nearby.
10. Pauses itself if you press a movement key, zone, or die, or if RGMercs is paused.

## Using a melee mercenary

A melee DPS mercenary works well with DruidKite. Your DoTs keep the mob on you, so it chases you around the circle while the merc chases it and hits it. There is no time limit on a cast window, so if the merc pulls the mob off you, DruidKite simply stands and casts until a mob heads for you again. A tank merc taunts, so expect it to hold the mob and you to cast more and run less. Mercenaries are not players, so the player check does not hold pulls because of yours.

## What RGMercs still handles

1. Spells: DoTs, nukes, snare, heals and buffs, from the RGMercs Druid class config.
2. Targeting and hater tracking on the extended target window.

While kiting, DruidKite turns off the RGMercs settings that would fight the circle: DoMelee, DoAutoStick, DoAutoNav, FaceTarget, HandleCantSeeTarget, ReturnToCamp, ChaseOn and DoPull. It also raises AssistRange so spells can reach mobs across the circle. These are temporary overrides. Your saved settings come back when you pause.

## Requirements

1. MacroQuest with RGMercs installed and working on your Druid.
2. The MQ2MoveUtils plugin loaded: `/plugin mq2moveutils`.
3. A pull spell memorized in a gem.

## Install

1. Copy `druidkite.lua` to `<MacroQuest folder>/config/rgmercs/modules/druidkite.lua`.
2. In RGMercs, open the UserModules tab, press Refresh, and tick Enabled for DruidKite. Enabling is saved per character and class.
3. A DruidKite tab appears in the RGMercs window.

## RGMercs Druid settings to change

DruidKite checks these when you press Start and lists any that are wrong on its tab. It does not change them for you, because they affect which spells RGMercs memorizes.

1. Mode: Hybrid. The default Heal mode does not run the damage rotation.
2. Use Snares (category Snare): on. It is off by default.
3. Only Dot Named (category Over Time): off. It is on by default, which skips DoTs on normal mobs.
4. The Sun, Wrath and Horde DoTs are on by default. Leave them on.
5. Mana to Dot is a core RGMercs setting, default 30. RGMercs stops casting DoTs below that mana.

## DruidKite settings

All DruidKite settings are in the RGMercs options under General, then Uncategorized, in four sections: Druid Kite Circle, Druid Kite Casting, Druid Kite Pulling and Druid Kite Safety. You can also type Druid Kite in the options search box.

| Setting | Default | Meaning |
|---|---|---|
| DKCircleRadius | 40 | Circle size in feet |
| DKLootWait | 8 | Seconds to wait for looting after the last kill |
| DKCastGap | 70 | Cast Distance: stop and cast when every mob on you is this far or farther |
| DKRunGap | 35 | Run Distance: run again when any mob is this close. Must be less than DKCastGap |
| DKPullGem | 0 | Gem number of your pull spell. 0 turns pulling off |
| DKPullRadius | 150 | How far to look for pulls |
| DKPullZRadius | 40 | Height limit for pulls |
| DKMaxHaters | 1 | Train guard: no new pulls at this many mobs on you |
| DKLevelAbove | 1 | Highest level above yours to pull |
| DKLevelBelow | 10 | Lowest level below yours to pull |
| DKUseLOS | true | Pull only mobs in line of sight |
| DKPullCooldown | 6 | Seconds between pulls |
| DKRestHPPct | 80 | Rest before pulling until HP is at least this |
| DKRestManaPct | 70 | Rest before pulling until mana is at least this |
| DKSitToMed | true | Sit while resting |
| DKLowHPPct | 30 | Emergency HP level |
| DKLowHPCommand | empty | Command to run once at emergency HP, for example a clicky |
| DKPlayerCheck | true | Hold pulls while a stranger is nearby |
| DKPlayerRadius | 300 | Stranger check distance |
| DKFriends | empty | Comma separated names the stranger check ignores |
| DKHoldOnGM | true | Hold pulls while a GM is in zone |

## Commands

| Command | Action |
|---|---|
| `/rgl druidkite start` | Set the anchor here if none is set, then start |
| `/rgl druidkite pause` | Pause and stop the circle |
| `/rgl druidkite toggle` | Switch between start and pause |
| `/rgl druidkite anchor` | Make your current spot the kite center |
| `/rgl druidkite status` | Print the current state and reason |

## First test checklist

Work through these in order and keep the ones that pass.

1. Load the module. The tab shows Paused, and nothing moves.
2. Set the RGMercs Druid settings above. Press Start and confirm the tab lists no setup problems.
3. Stand in open, flat ground. Set the anchor and press Start with DKPullGem at 0 and DKMaxHaters at 1. Nothing should pull.
4. Snare one mob by hand. The circle should start, then stop once the mob falls behind, and RGMercs should cast.
5. When the mob catches up, the circle should start again.
6. Kill it. The circle stops, looting happens, you walk back to the anchor, and you sit if mana is low.
7. Press a movement key while circling. DruidKite should pause.
8. Set DKPullGem and let it pull by itself.
9. Try a melee mercenary only after steps 1 to 8 run clean.

## Safety notes

1. Do not use the RGMercs Pull tab (Start Pulls or Pull Target) while DruidKite runs. Its pathing stops the circle. Use DKPullGem instead.
2. The RGMercs loot module only runs on emulator servers. On live servers, use MQ2AutoLoot or loot by hand.
3. Keep DKMaxHaters at 1 until everything runs clean. More mobs means more risk of a train.
4. Do not leave it unattended near other players.
5. DruidKite never speaks in public channels. Its messages go only to your MQ console.

## Credits and license

The kiting idea comes from bardkite.mac v0.5 (2005) by reghar, from Siddin's work. It is built for [RGMercs](https://github.com/DerpleDude/rgmercs), which is GPL v3, so this module is also offered under GPL v3.
