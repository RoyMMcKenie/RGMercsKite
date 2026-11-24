# RGMercs Kite Modules

Two RGMercs user modules for solo circle kiting in EverQuest with MacroQuest. Each one has its own folder and README with install steps, settings, commands and a first test checklist.

| Module | Class | Version | How it kites |
|---|---|---|---|
| [BardKite](bardkite/README.md) | Bard | 1.0.2 | Runs the circle the whole fight while RGMercs sings DoTs and slow |
| [DruidKite](druidkite/README.md) | Druid | 1.0.0 | Runs until mobs fall behind, stops so RGMercs can cast, then runs again. Works with a melee mercenary |

## Shared basics

1. Requires MacroQuest, [RGMercs](https://github.com/DerpleDude/rgmercs) and the MQ2MoveUtils plugin.
2. Install by copying the module file to `<MacroQuest folder>/config/rgmercs/modules/`, then open the RGMercs UserModules tab, press Refresh and tick Enabled.
3. Both modules start paused and have a PAUSE button. Pressing a movement key, zoning, dying or pausing RGMercs also pauses them.
4. Both use a train guard so only a set number of mobs are pulled at once.

## Status

BardKite has been tested live. DruidKite has passed offline tests only and has not been run in game yet.

## Credits and license

The kiting idea comes from bardkite.mac v0.5 (2005) by reghar, from Siddin's work. RGMercs is GPL v3, so these modules are offered under GPL v3. See [LICENSE](LICENSE).
