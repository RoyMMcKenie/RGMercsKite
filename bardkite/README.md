# BardKite for RGMercs

BardKite is an RGMercs user module that turns a solo Bard into a circle kiter. It is a Lua rebuild of reghar's 2005 bardkite.mac (based on Siddin's work). It only adds what RGMercs does not already have: the kite circle, a train guard, pulling, and safety holds. RGMercs still does the singing.

## What BardKite does

1. Waits paused until you press Start. You also get a PAUSE button, and every pause stops the circle.
2. Pulls the nearest NPC in range and level window with the song in your chosen gem.
3. When a mob is on you, runs `/circle` around your anchor point through MQ2MoveUtils.
4. Pulls more mobs only while you have fewer than BKMaxHaters on you (the train guard).
5. When nothing is on you, stops the circle and waits BKLootWait seconds so a loot tool can loot. The RGMercs loot module only runs on emulator servers. On live servers, use MQ2AutoLoot or loot by hand. Then it walks back to the anchor with `/moveto`.
6. Holds pulls while a GM or a player who is not in your group or friends list is nearby. It also holds to rest when HP or mana is low.
7. Pauses itself if you press a movement key, zone, or die, or if RGMercs is paused.

## What RGMercs still handles

1. Songs: DoTs, slow, Selo's, and twisting, from the RGMercs Bard class config.
2. Targeting and hater tracking on the extended target window.

While kiting, BardKite turns off the RGMercs settings that would fight the circle: DoMelee, DoAutoStick, DoAutoNav, FaceTarget, HandleCantSeeTarget, ReturnToCamp, ChaseOn, DoPull, and MezOn. Mezzing has to be off because RGMercs holds back every combat song while it wants to mez, and mezzed mobs stay on your extended target list, which keeps the circle running. It also raises AssistRange so songs can reach mobs across the circle. These are temporary overrides. Your saved settings come back when you pause.

## Requirements

1. MacroQuest with RGMercs installed and working on your Bard.
2. The MQ2MoveUtils plugin loaded: `/plugin mq2moveutils`.
3. A pull song memorized in a gem, ideally a ranged DoT or snare.

## Install

1. Copy `bardkite.lua` to `<MQ config folder>/rgmercs/modules/bardkite.lua`.
2. In RGMercs, open the UserModules tab, press Refresh, and tick Enabled for BardKite.
3. A BardKite tab appears in the RGMercs window.

## RGMercs Bard settings to turn on

Turn these on in the RGMercs Bard options:

1. UseFireDots, UseIceDots, UsePoisonDots, UseDiseaseDots: your kiting damage.
2. DoSTSlow: Selo's Consonant Chain slows and snares.
3. UseRunBuff: keeps Selo's running so you outrun what you kite.

## BardKite settings

All BardKite settings are in the RGMercs options under General, then Uncategorized, in three sections: Bard Kite Circle, Bard Kite Pulling and Bard Kite Safety. You can also type Bard Kite in the options search box. RGMercs puts settings from user modules there because their categories are not on its built in list.

| Setting | Default | Meaning |
|---|---|---|
| BKCircleRadius | 35 | Circle size in feet |
| BKLootWait | 8 | Seconds to wait for looting after the last kill |
| BKPullGem | 0 | Gem number of your pull song. 0 turns pulling off |
| BKPullRadius | 150 | How far to look for pulls |
| BKPullZRadius | 40 | Height limit for pulls |
| BKMaxHaters | 2 | Train guard: no new pulls at this many mobs on you |
| BKLevelAbove | 1 | Highest level above yours to pull |
| BKLevelBelow | 10 | Lowest level below yours to pull |
| BKUseLOS | true | Pull only mobs in line of sight |
| BKPullCooldown | 6 | Seconds between pulls |
| BKRestHPPct | 80 | Rest before pulling when HP is below this |
| BKRestManaPct | 20 | Rest before pulling when mana is below this |
| BKLowHPPct | 30 | Emergency HP level |
| BKLowHPCommand | empty | Command to run once at emergency HP, for example a clicky |
| BKPlayerCheck | true | Hold pulls while a stranger is nearby |
| BKPlayerRadius | 300 | Stranger check distance |
| BKFriends | empty | Comma separated names the stranger check ignores |
| BKHoldOnGM | true | Hold pulls while a GM is in zone |

## Commands

| Command | Action |
|---|---|
| `/rgl bardkite start` | Set the anchor here if none is set, then start |
| `/rgl bardkite pause` | Pause and stop the circle |
| `/rgl bardkite toggle` | Switch between start and pause |
| `/rgl bardkite anchor` | Make your current spot the kite center |
| `/rgl bardkite status` | Print the current state and reason |

## First test checklist

Work through these in order and keep the ones that pass.

1. Load the module. The tab shows Paused, and nothing moves.
2. Stand in open, flat ground. Set the anchor and press Start with BKPullGem at 0. Nothing should pull.
3. Pull one mob by hand. The circle should start and RGMercs should sing DoTs.
4. Kill it. The circle stops, looting happens, and you walk back to the anchor.
5. Press a movement key while circling. BardKite should pause.
6. Set BKPullGem and BKMaxHaters 1. Let it pull by itself.
7. Raise BKMaxHaters to 2 only after step 6 runs clean.

## Safety notes

1. Do not use the RGMercs Pull tab (Start Pulls or Pull Target) while BardKite runs. Its pathing stops the circle. Use BKPullGem instead.
2. Suspend or dismiss your mercenary while kiting.
3. Start BKMaxHaters at 1 or 2. More mobs means more risk of a train.
4. Do not leave it unattended near other players.
5. BardKite never speaks in public channels. Its messages go only to your MQ console.

## Credits and license

Based on bardkite.mac v0.5 (2005) by reghar, from Siddin's work. It is built for [RGMercs](https://github.com/DerpleDude/rgmercs), which is GPL v3, so this module is also offered under GPL v3.
