--[[
===============================================================================
 FILE:        druidkite.lua
 MODULE:      DruidKite, an RGMercs user module
 VERSION:     1.0.0
 DATE:        2026-11-23
 LICENSE:     GNU GPL v3 (same license as RGMercs, because this module runs
              inside RGMercs and uses its libraries)
 CREDITS:     Built from BardKite 1.0.2 (this project), which is based on
              "bardkite.mac" v0.5 (2005) by reghar on RedGuides, itself based
              on work by Siddin.
-------------------------------------------------------------------------------
 WHAT:  Adds snare and DoT circle kiting to the RGMercs Druid. RGMercs keeps
        choosing and casting every spell (snare, DoTs, nukes, heals, buffs).
        DruidKite only adds what RGMercs does not have:
          1. A kiting circle around an anchor spot while mobs are on you.
          2. Cast windows: stop running when the mob has fallen far enough
             behind, so RGMercs can cast, then run again before it arrives.
          3. A pull: cast one chosen spell (ideally your snare) at a mob.
          4. A train guard: never pull past a set number of mobs.
          5. Mana rest: sit and med between pulls until mana is back up.
          6. Safety holds: GM visible, a stranger nearby, low HP.
          7. A Pause / Start button and /rgl druidkite commands.
 WHY:   A Druid's DoTs hit much harder than Bard chants, but a Druid cannot
        cast while moving. RGMercs refuses to start a spell while a non Bard
        is moving (Casting.MoveBlocksCast in utils/casting.lua), so a plain
        circle would never cast anything. Stopping at the right moments
        makes the Druid a real kiter.
 WHERE: Copy this file to:
            <MacroQuest folder>/config/rgmercs/modules/druidkite.lua
        Then open RGMercs, go to the UserModules tab, press Refresh and
        tick Enabled for DruidKite. A "DruidKite" tab appears in RGMercs.
        Settings: RGMercs Options > General > Uncategorized (Druid Kite
        sections), or type Druid Kite in the options search box.
 HOW:   RGMercs calls GiveTime() every main loop tick. DruidKite reads the
        mobs on your extended target window and runs a state machine:
            Paused  -> do nothing (you are in control)
            Running -> mobs on you, circle around the anchor
            Casting -> mob far enough behind; standing still so RGMercs
                       casts. Back to Running when a mob gets close.
            Looting -> no mobs, short wait so a loot tool can loot
            Return  -> walk back to the anchor
            Holding -> a safety rule is blocking new pulls
            Resting -> HP or mana below the rest level; sits to med
            Pulling -> cast the pull spell at the best nearby mob
        MERCENARY: A melee DPS mercenary works well with DruidKite. Your
        DoTs keep the mob on you, so it chases you around the circle while
        the merc chases it and hits it. If the merc pulls the mob off you,
        the mob stops coming, so DruidKite just stands and casts until a
        mob heads for you again. A tank merc taunts, so expect it to hold
        the mob and you to cast more and run less.
        Movement uses MQ2MoveUtils commands from its documentation:
            /circle loc <y> <x>, /circle radius <#>, /circle off,
            /moveto loc <y> <x>
        Spawn searches use documented options only:
            npc, pc, gm, targetable, los, radius, zradius, range, xtarhater
        Sitting and standing use the EverQuest /sit and /stand commands.
        While kiting is on, DruidKite applies TEMPORARY RGMercs settings
        (they clear when RGMercs restarts or when you pause DruidKite):
            DoMelee off, DoAutoStick off, DoAutoNav off, FaceTarget off,
            HandleCantSeeTarget off, ReturnToCamp off, ChaseOn off,
            DoPull off, AssistRange raised to cover the kite.
 WHEN:  Starts in the Paused state every time it loads. Nothing moves until
        you press Start Kiting or type /rgl druidkite start.
-------------------------------------------------------------------------------
 REQUIREMENTS:
   - RGMercs Lua (with the UserModules tab)
   - MQ2MoveUtils plugin loaded (/plugin mq2moveutils)
   - A Druid with these RGMercs Druid options set (DruidKite checks them
     when you press Start and lists any that are wrong on its tab):
       Mode: Hybrid       (promotes DoTs and nukes)
       Use Snares: on     (off by default; kiting needs the snare)
       Only Dot Named: off (on by default; it would DoT named mobs only)
     These are saved class settings and some change which spells RGMercs
     memorizes, so DruidKite does not flip them for you.
-------------------------------------------------------------------------------
 SAFETY NOTES:
   - Pressing a movement key while running breaks the MQ2MoveUtils circle.
     DruidKite treats that as "you took control" and pauses itself.
   - If a mob reaches Run Distance while you are mid cast, DruidKite runs
     anyway. Losing a spell is better than standing in melee.
   - Do not use the RGMercs Pull tab while DruidKite runs; its pathing
     stops the circle.
   - Mercenaries are not players (spawn type mercenary), so the player
     check never holds pulls because of yours.
===============================================================================
]]

local mq        = require('mq')
local ImGui     = require('ImGui')
local Base      = require("modules.base")
local Casting   = require("utils.casting")
local Config    = require('utils.config')
local Core      = require("utils.core")
local Globals   = require("utils.globals")
local Logger    = require("utils.logger")
local Targeting = require("utils.targeting")

local Module    = {
    _version = '1.0.0',
    _name    = "DruidKite",
    _author  = 'ElitePro (Roy), built from BardKite, credit to reghar and Siddin (2005)',
    _about   = "Snare and DoT circle kiting for the RGMercs Druid: stop to cast windows, single spell pull, train guard, mana rest and a pause button.",
}
Module.__index  = Module
setmetatable(Module, { __index = Base, })

--[[---------------------------------------------------------------------------
 Module.TempSettings
 WHAT:  Runtime state that is NOT saved between sessions.
 WHY:   The kite should always start paused, with no old anchor, after a
        restart or zone.
 WHERE: Read and written throughout this file.
 HOW:   Plain table. Times are seconds from Globals.GetTimeSeconds().
 WHEN:  Reset in Init(), OnZone() and OnDeath().
-----------------------------------------------------------------------------]]
Module.TempSettings = {
    Paused         = true,
    State          = "Paused",
    Reason         = "Press Start Kiting to begin.",
    AnchorY        = nil,
    AnchorX        = nil,
    CircleExpected = false, -- true while DruidKite has the circle running.
    OverridesOn    = false,
    PendingAction  = nil,
    LastTickMS     = 0,
    LastHaterTime  = 0,
    LastPullTime   = 0,
    PullTargetId   = 0,
    FailedPulls    = {},    -- [spawnId] = time; skipped for 120 seconds.
    LastWarnTime   = 0,
    LowHPCmdUsed   = false,
    CastStart      = 0,     -- When the current cast window began.
    LastSitTime    = 0,
    SetupProblems  = {},    -- RGMercs Druid options that need changing.
}

--[[---------------------------------------------------------------------------
 Module.CommandHandlers
 WHAT:  Adds /rgl druidkite <start|pause|toggle|anchor|status>.
 WHY:   Hotkey control, and a typed way to pause at any time.
 WHERE: RGMercs dispatches /rgl subcommands to loaded modules.
 HOW:   Handlers only queue an action; GiveTime() carries it out.
 WHEN:  Whenever you type the command.
-----------------------------------------------------------------------------]]
Module.CommandHandlers = {
    druidkite = {
        usage = "/rgl druidkite <start|pause|toggle|anchor|status>",
        about = "Control the DruidKite circle kiting module.",
        handler = function(self, action)
            action = (action or "status"):lower()
            if action == "start" or action == "pause" or action == "toggle" or action == "anchor" then
                self.TempSettings.PendingAction = action
            else
                self:PrintStatus()
            end
            return true
        end,
    },
}

--[[---------------------------------------------------------------------------
 Module.FAQ
 WHAT:  Questions and answers shown in the RGMercs FAQ window.
 WHY:   Puts the key how to answers inside the game.
 WHERE: RGMercs FAQ tab and search.
 HOW:   Same format RGMercs modules use.
 WHEN:  Read by RGMercs at load.
-----------------------------------------------------------------------------]]
Module.FAQ = {
    {
        Question = "How does DruidKite cast while kiting?",
        Answer =
            "  It runs the circle until the nearest mob on you is at least Cast Distance away, then stops so RGMercs can cast. " ..
            "When a mob closes to Run Distance it runs again. A melee mercenary can beat on the mob while you cast.\n\n" ..
            "  The snare is what makes this work. Turn on Use Snares in the RGMercs Druid options.",
        Settings_Used = "DKCastGap",
    },
    {
        Question = "Why does DruidKite pause itself?",
        Answer =
            "  It pauses when you zone, die, press a movement key while it is running (which breaks the circle), or pause RGMercs.",
        Settings_Used = "",
    },
}

--[[---------------------------------------------------------------------------
 Module.DefaultConfig
 WHAT:  The saved settings for DruidKite.
 WHY:   RGMercs stores, shows and saves these per character for us.
 WHERE: RGMercs Options > General > Uncategorized, in sections named
        Druid Kite Circle, Druid Kite Casting, Druid Kite Pulling and
        Druid Kite Safety. RGMercs files a setting under a named header only
        when its category is on the built in list in ui/options.lua; others
        go to the catch all Uncategorized header.
 HOW:   Every name starts with "DK" because RGMercs setting names are
        global and must not collide with BardKite or other modules.
 WHEN:  Loaded by Base.Init() at module load.
-----------------------------------------------------------------------------]]
Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    -- ---------------- Circle ----------------
    ['DKCircleRadius'] = {
        DisplayName = "Circle Radius",
        Category = "Druid Kite Circle", Index = 1,
        Tooltip = "Radius of the kiting circle. Druids stop to cast, so a bigger circle than a Bard's gives more room. Needs open, flat ground.",
        Default = 40, Min = 15, Max = 150,
    },
    ['DKLootWait'] = {
        DisplayName = "Loot Wait (seconds)",
        Category = "Druid Kite Circle", Index = 2,
        Tooltip = "After the last mob dies, wait this long before walking back to the anchor, so a loot tool such as MQ2AutoLoot can loot.",
        Default = 8, Min = 0, Max = 60,
    },
    -- ---------------- Casting ----------------
    ['DKCastGap'] = {
        DisplayName = "Cast Distance",
        Category = "Druid Kite Casting", Index = 1,
        Tooltip = "Stop running to cast once the nearest mob on you is at least this far away. Must be more than Run Distance.",
        Default = 70, Min = 20, Max = 200,
    },
    ['DKRunGap'] = {
        DisplayName = "Run Distance",
        Category = "Druid Kite Casting", Index = 2,
        Tooltip = "Start running again when the nearest mob on you gets this close, even mid cast. Keep it well above melee range.",
        Default = 35, Min = 15, Max = 150,
    },
    -- ---------------- Pulling ----------------
    ['DKPullGem'] = {
        DisplayName = "Pull Spell Gem",
        Category = "Druid Kite Pulling", Index = 1,
        Tooltip = "Spell gem of the spell used to pull. Your snare is best, so the mob arrives slowed. 0 = never pull; you pull by hand.",
        Default = 0, Min = 0, Max = 13,
    },
    ['DKPullRadius'] = {
        DisplayName = "Pull Radius",
        Category = "Druid Kite Pulling", Index = 2,
        Tooltip = "Only pull mobs within this distance of you.",
        Default = 150, Min = 20, Max = 300,
    },
    ['DKPullZRadius'] = {
        DisplayName = "Pull Height Limit",
        Category = "Druid Kite Pulling", Index = 3,
        Tooltip = "Only pull mobs within this height difference, so you do not pull from cliffs or floors above.",
        Default = 40, Min = 5, Max = 200,
    },
    ['DKMaxHaters'] = {
        DisplayName = "Max Mobs (Train Guard)",
        Category = "Druid Kite Pulling", Index = 4,
        Tooltip = "Never pull another mob while this many are on you. Start at 1.",
        Default = 1, Min = 1, Max = 5,
    },
    ['DKLevelAbove'] = {
        DisplayName = "Max Levels Above You",
        Category = "Druid Kite Pulling", Index = 5,
        Tooltip = "Highest mob level to pull, relative to yours.",
        Default = 1, Min = 0, Max = 10,
    },
    ['DKLevelBelow'] = {
        DisplayName = "Max Levels Below You",
        Category = "Druid Kite Pulling", Index = 6,
        Tooltip = "Lowest mob level to pull, relative to yours.",
        Default = 10, Min = 0, Max = 60,
    },
    ['DKUseLOS'] = {
        DisplayName = "Line of Sight Only",
        Category = "Druid Kite Pulling", Index = 7,
        Tooltip = "Only pull mobs you can see. Spells need line of sight.",
        Default = true,
    },
    ['DKPullCooldown'] = {
        DisplayName = "Pull Cooldown (seconds)",
        Category = "Druid Kite Pulling", Index = 8,
        Tooltip = "Minimum time between pull attempts.",
        Default = 6, Min = 1, Max = 60,
    },
    -- ---------------- Safety ----------------
    ['DKRestHPPct'] = {
        DisplayName = "Rest Until HP %",
        Category = "Druid Kite Safety", Index = 1,
        Tooltip = "Do not pull while HP is below this.",
        Default = 80, Min = 0, Max = 100,
    },
    ['DKRestManaPct'] = {
        DisplayName = "Rest Until Mana %",
        Category = "Druid Kite Safety", Index = 2,
        Tooltip = "Do not pull while mana is below this. Druid DoTs cost a lot, so start high.",
        Default = 70, Min = 0, Max = 100,
    },
    ['DKSitToMed'] = {
        DisplayName = "Sit While Resting",
        Category = "Druid Kite Safety", Index = 3,
        Tooltip = "Sit to med while resting with nothing on you. You stand automatically when a mob arrives.",
        Default = true,
    },
    ['DKLowHPPct'] = {
        DisplayName = "Emergency HP %",
        Category = "Druid Kite Safety", Index = 4,
        Tooltip = "Below this HP while kiting, warn and run the Emergency Command once.",
        Default = 30, Min = 0, Max = 100,
    },
    ['DKLowHPCommand'] = {
        DisplayName = "Emergency Command",
        Category = "Druid Kite Safety", Index = 5,
        Tooltip = "Command to run once at Emergency HP, for example a gate or evac spell or a clicky. Leave empty for none.",
        Default = "",
    },
    ['DKPlayerCheck'] = {
        DisplayName = "Hold Pulls Near Players",
        Category = "Druid Kite Safety", Index = 6,
        Tooltip = "Do not pull while a player who is not you, your group or your friends list is nearby.",
        Default = true,
    },
    ['DKPlayerRadius'] = {
        DisplayName = "Player Check Radius",
        Category = "Druid Kite Safety", Index = 7,
        Tooltip = "Distance for the player check.",
        Default = 300, Min = 50, Max = 1000,
    },
    ['DKFriends'] = {
        DisplayName = "Friends (comma list)",
        Category = "Druid Kite Safety", Index = 8,
        Tooltip = "Comma separated player names the player check ignores.",
        Default = "",
    },
    ['DKHoldOnGM'] = {
        DisplayName = "Hold Pulls When GM Visible",
        Category = "Druid Kite Safety", Index = 9,
        Tooltip = "Stop pulling while a visible GM is in the zone. Current mobs are still kited.",
        Default = true,
    },
}

-- Temporary RGMercs settings applied while kiting. See file header.
-- BardKite also turns off MezOn; Druids have no mez, so it is not needed.
local RG_OVERRIDES = {
    { name = 'DoMelee',             value = false, },
    { name = 'DoAutoStick',         value = false, },
    { name = 'DoAutoNav',           value = false, },
    { name = 'FaceTarget',          value = false, },
    { name = 'HandleCantSeeTarget', value = false, },
    { name = 'ReturnToCamp',        value = false, },
    { name = 'ChaseOn',             value = false, },
    { name = 'DoPull',              value = false, },
}

--[[---------------------------------------------------------------------------
 Module:New()
 WHAT:  Creates the module object.
 WHY:   Required by the RGMercs user module system.
 WHERE: Called by RGMercs when the module is enabled.
 HOW:   Defers to Base.New().
 WHEN:  Once per load.
-----------------------------------------------------------------------------]]
function Module:New()
    return Base.New(self)
end

--[[---------------------------------------------------------------------------
 Module:Init()
 WHAT:  Loads settings and makes sure DruidKite starts paused.
 WHY:   Nothing should move the moment the module loads.
 WHERE: Called by RGMercs once at load.
 HOW:   Base.Init() loads saved settings, state is reset, and the watchdog
        is registered (see Module:Watchdog()).
 WHEN:  Once per load.
-----------------------------------------------------------------------------]]
function Module:Init()
    Base.Init(self)
    self:ResetState("Press Start Kiting to begin.")
    self:RegisterImGui("DruidKiteWatchdog", function() self:Watchdog() end)
    if not mq.TLO.Plugin('MQ2MoveUtils').IsLoaded() then
        Logger.log_warn("\ay[DruidKite]\ax MQ2MoveUtils is not loaded. Type /plugin mq2moveutils before pressing Start Kiting.")
    end
    if (mq.TLO.Me.Class.ShortName() or ""):upper() ~= "DRU" then
        Logger.log_warn("\ay[DruidKite]\ax This module is written for Druids. Use BardKite on a Bard.")
    end
    Logger.log_info("\ag[DruidKite]\ax Loaded and paused. Open the DruidKite tab and press Start Kiting.")
end

--[[---------------------------------------------------------------------------
 Module:ResetState(reason)
 WHAT:  Puts DruidKite back in a clean paused state.
 WHY:   Old anchors and pull data must never be reused after a zone or
        death.
 WHERE: Init(), OnZone(), OnDeath().
 HOW:   Clears the runtime fields in TempSettings.
 WHEN:  As above.
-----------------------------------------------------------------------------]]
function Module:ResetState(reason)
    local t          = self.TempSettings
    t.Paused         = true
    t.State          = "Paused"
    t.Reason         = reason or ""
    t.AnchorY        = nil
    t.AnchorX        = nil
    t.CircleExpected = false
    t.PendingAction  = nil
    t.PullTargetId   = 0
    t.FailedPulls    = {}
    t.LowHPCmdUsed   = false
    t.CastStart      = 0
end

--[[---------------------------------------------------------------------------
 Module:CheckDruidSetup()
 WHAT:  Lists RGMercs Druid options that would stop the kite from working.
 WHY:   Use Snares is off and Only Dot Named is on by default in the
        RGMercs Live Druid config, and Heal mode puts healing first. Any of
        these makes the kite slow or unsafe. They are saved settings that
        change spell loadouts, so DruidKite reports them instead of
        changing them.
 WHERE: StartKite(); results shown on the DruidKite tab.
 HOW:   Reads settings with failOk so a missing setting on another build
        does not log errors. Core.IsModeActive("Hybrid") asks the class
        module for the current mode. Wrapped in pcall for safety.
 WHEN:  Each time you press Start Kiting.
-----------------------------------------------------------------------------]]
function Module:CheckDruidSetup()
    local problems = {}
    pcall(function()
        if Config:GetSetting('DoSnare', true) == false then
            table.insert(problems, "Turn ON Use Snares (Abilities > Debuffs > Snare).")
        end
        if Config:GetSetting('DotNamedOnly', true) == true then
            table.insert(problems, "Turn OFF Only Dot Named (Abilities > Damage > Over Time).")
        end
        if not Core.IsModeActive("Hybrid") then
            table.insert(problems, "Set Mode to Hybrid (Combat) so DoTs come first.")
        end
    end)
    self.TempSettings.SetupProblems = problems
    for _, p in ipairs(problems) do
        Logger.log_warn("\ay[DruidKite]\ax RGMercs setup: %s", p)
    end
end

--[[---------------------------------------------------------------------------
 Module:ApplyOverrides() / Module:ClearOverrides()
 WHAT:  Turns the temporary RGMercs settings on or off.
 WHY:   RGMercs would otherwise stick to, nav to, face or return to camp,
        any of which breaks the kite.
 WHERE: StartKite(), PauseKite(), Shutdown().
 HOW:   Config:SetTempSetting() and Config:ClearTempSetting() change memory
        only; nothing is written to your saved settings. AssistRange is
        raised so RGMercs keeps casting at mobs across the circle.
 WHEN:  On start, pause and unload.
-----------------------------------------------------------------------------]]
function Module:ApplyOverrides()
    for _, o in ipairs(RG_OVERRIDES) do
        pcall(function() Config:SetTempSetting(o.name, o.value) end)
    end
    local wanted = Config:GetSetting('DKPullRadius') + (Config:GetSetting('DKCircleRadius') * 2)
    pcall(function()
        if (Config:GetSetting('AssistRange') or 0) < wanted then
            Config:SetTempSetting('AssistRange', wanted)
        end
    end)
    self.TempSettings.OverridesOn = true
end

function Module:ClearOverrides()
    if not self.TempSettings.OverridesOn then return end
    for _, o in ipairs(RG_OVERRIDES) do
        pcall(function() Config:ClearTempSetting(o.name) end)
    end
    pcall(function() Config:ClearTempSetting('AssistRange') end)
    self.TempSettings.OverridesOn = false
end

--[[---------------------------------------------------------------------------
 Module:SetAnchorHere()
 WHAT:  Saves where you stand as the circle center.
 WHY:   The kite always circles and returns to one known safe spot.
 WHERE: StartKite() if no anchor yet, the Set Anchor Here button and
        /rgl druidkite anchor.
 HOW:   Reads Me.Y() and Me.X().
 WHEN:  On demand.
-----------------------------------------------------------------------------]]
function Module:SetAnchorHere()
    self.TempSettings.AnchorY = mq.TLO.Me.Y()
    self.TempSettings.AnchorX = mq.TLO.Me.X()
    Logger.log_info("\ag[DruidKite]\ax Anchor set at %.1f, %.1f", self.TempSettings.AnchorY, self.TempSettings.AnchorX)
end

--[[---------------------------------------------------------------------------
 Module:StartKite() / Module:PauseKite(reason)
 WHAT:  The Start and Pause actions.
 WHY:   Every tool in this project has a pause control. Pause must stop
        all movement DruidKite started, right away.
 WHERE: PendingAction handling in GiveTime(), Watchdog(), safety checks.
 HOW:   Start: check the Druid setup, set anchor if needed, apply
        overrides, unpause. Pause: /circle off, clear overrides. RGMercs
        keeps running, so heals and spells continue.
 WHEN:  On button press, command, or automatic safety pause.
-----------------------------------------------------------------------------]]
function Module:StartKite()
    if not mq.TLO.Plugin('MQ2MoveUtils').IsLoaded() then
        Logger.log_error("\ar[DruidKite]\ax MQ2MoveUtils is not loaded. Type /plugin mq2moveutils first.")
        return
    end
    if Config:GetSetting('DKRunGap') >= Config:GetSetting('DKCastGap') then
        Logger.log_error("\ar[DruidKite]\ax Run Distance must be less than Cast Distance. Fix the Druid Kite Casting settings.")
        return
    end
    self:CheckDruidSetup()
    if not self.TempSettings.AnchorY then self:SetAnchorHere() end
    self:ApplyOverrides()
    self.TempSettings.Paused       = false
    self.TempSettings.LowHPCmdUsed = false
    self.TempSettings.Reason       = ""
    Logger.log_info("\ag[DruidKite]\ax Started.")
end

function Module:PauseKite(reason)
    local t = self.TempSettings
    if t.CircleExpected or mq.TLO.Circle.Status() == 'on' then
        mq.cmd('/squelch /circle off')
    end
    t.CircleExpected = false
    t.Paused         = true
    t.State          = "Paused"
    t.Reason         = reason or "Paused by you."
    self:ClearOverrides()
    Logger.log_info("\ay[DruidKite]\ax Paused: %s", t.Reason)
end

--[[---------------------------------------------------------------------------
 Module:StartCircle() / Module:StopCircle()
 WHAT:  Runs or stops the MQ2MoveUtils circle around the anchor.
 WHY:   The circle is the kite; stopping it opens a cast window.
 WHERE: GiveTime() state machine.
 HOW:   "/stand" first if sitting, then "/circle loc <y> <x>" and
        "/circle radius <#>". CircleExpected lets GiveTime() notice when
        something else (a key press) stopped it. StopCircle() clears
        CircleExpected first so our own stop is never mistaken for yours.
 WHEN:  When mobs arrive, after each cast window, and when the last dies.
-----------------------------------------------------------------------------]]
function Module:StartCircle()
    local t = self.TempSettings
    if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
    mq.cmdf('/squelch /circle loc %.2f %.2f', t.AnchorY, t.AnchorX)
    mq.cmdf('/squelch /circle radius %d', Config:GetSetting('DKCircleRadius'))
    t.CircleExpected = true
end

function Module:StopCircle()
    self.TempSettings.CircleExpected = false
    mq.cmd('/squelch /circle off')
end

--[[---------------------------------------------------------------------------
 Module:NearestHaterDistance()
 WHAT:  Distance to the closest mob on your extended target window.
 WHY:   Decides when to stop and cast and when to run again.
 WHERE: GiveTime() while mobs are on you.
 HOW:   NearestSpawn('1, npc xtarhater').Distance(). If the search finds
        nothing even though haters were counted, returns 0 so DruidKite
        treats the mob as close and keeps running (the safe choice).
 WHEN:  Each kiting tick.
-----------------------------------------------------------------------------]]
function Module:NearestHaterDistance()
    local spawn = mq.TLO.NearestSpawn('1, npc xtarhater')
    if (spawn.ID() or 0) == 0 then return 0 end
    return spawn.Distance() or 0
end

--[[---------------------------------------------------------------------------
 Module:DistanceToAnchor()
 WHAT:  Straight line distance from you to the anchor.
 WHY:   Decides when to walk back after looting.
 WHERE: GiveTime().
 HOW:   Pythagoras on Y and X.
 WHEN:  Each tick when no mobs are on you.
-----------------------------------------------------------------------------]]
function Module:DistanceToAnchor()
    local t = self.TempSettings
    if not t.AnchorY then return 0 end
    local dy = (mq.TLO.Me.Y() or 0) - t.AnchorY
    local dx = (mq.TLO.Me.X() or 0) - t.AnchorX
    return math.sqrt(dy * dy + dx * dx)
end

--[[---------------------------------------------------------------------------
 Module:IsFriend(name) / Module:NearbyStranger()
 WHAT:  Player check helpers. IsFriend is true for names in DKFriends.
        NearbyStranger returns the closest player who is not you, not in
        your group and not a friend, or nil.
 WHY:   Kiting near strangers risks training them.
 WHERE: SafetyHold().
 HOW:   SpawnCount('pc radius R') then NearestSpawn('<n>, pc radius R'),
        checking at most 10 players to keep the tick cheap.
 WHEN:  Each tick while deciding whether to pull.
-----------------------------------------------------------------------------]]
function Module:IsFriend(name)
    if not name then return false end
    local list = (Config:GetSetting('DKFriends') or ""):lower()
    for entry in list:gmatch("[^,]+") do
        if entry:match("^%s*(.-)%s*$") == name:lower() then return true end
    end
    return false
end

function Module:NearbyStranger()
    local search = string.format('pc radius %d', Config:GetSetting('DKPlayerRadius'))
    local count  = math.min(mq.TLO.SpawnCount(search)() or 0, 10)
    local myId   = mq.TLO.Me.ID()
    for i = 1, count do
        local pc   = mq.TLO.NearestSpawn(string.format('%d, %s', i, search))
        local id   = pc.ID() or 0
        local name = pc.CleanName()
        if id > 0 and id ~= myId and name and not mq.TLO.Group.Member(name)() and not self:IsFriend(name) then
            return name
        end
    end
    return nil
end

--[[---------------------------------------------------------------------------
 Module:SafetyHold() / Module:RestNeeded()
 WHAT:  SafetyHold returns a reason if pulling must wait for a GM or a
        stranger. RestNeeded returns a reason if HP or mana is too low.
 WHY:   Collects every "do not pull now" rule in one place.
 WHERE: GiveTime().
 HOW:   Spawn searches and Me.PctHPs() / Me.PctMana().
 WHEN:  Each tick while deciding whether to pull.
-----------------------------------------------------------------------------]]
function Module:SafetyHold()
    if Config:GetSetting('DKHoldOnGM') and (mq.TLO.SpawnCount('gm')() or 0) > 0 then
        return "A GM is visible in the zone."
    end
    if Config:GetSetting('DKPlayerCheck') then
        local who = self:NearbyStranger()
        if who then return string.format("Player %s is nearby.", who) end
    end
    return nil
end

function Module:RestNeeded()
    if (mq.TLO.Me.PctHPs() or 100) < Config:GetSetting('DKRestHPPct') then
        return "Resting for HP."
    end
    if (mq.TLO.Me.PctMana() or 100) < Config:GetSetting('DKRestManaPct') then
        return "Resting for mana."
    end
    return nil
end

--[[---------------------------------------------------------------------------
 Module:SitToMed()
 WHAT:  Sits you down while resting with nothing on you.
 WHY:   Druids regain mana much faster sitting. RGMercs only meds at its
        own Med Rules thresholds, which may be lower than Rest Until Mana.
 WHERE: GiveTime() in the Resting state.
 HOW:   Sends "/sit" only when standing, not moving and not casting, at
        most once every 3 seconds. StartCircle() stands you up again.
 WHEN:  While resting, if Sit While Resting is on.
-----------------------------------------------------------------------------]]
function Module:SitToMed()
    local t   = self.TempSettings
    local now = Globals.GetTimeSeconds()
    if not Config:GetSetting('DKSitToMed') then return end
    if mq.TLO.Me.Sitting() or mq.TLO.Me.Moving() or mq.TLO.Me.Casting() then return end
    if (now - t.LastSitTime) < 3 then return end
    t.LastSitTime = now
    mq.cmd('/sit')
end

--[[---------------------------------------------------------------------------
 Module:FindPullTarget()
 WHAT:  Finds the closest mob that is safe and sensible to pull.
 WHY:   Level window, height limit and a skip list for failed pulls.
 WHERE: TryPull().
 HOW:   Search string, for example:
            npc targetable los radius 150 zradius 40 range 40 51
        Walks the 5 nearest matches and returns the first not skipped.
 WHEN:  When a pull is allowed.
-----------------------------------------------------------------------------]]
function Module:FindPullTarget()
    local myLvl  = mq.TLO.Me.Level() or 1
    local low    = math.max(1, myLvl - Config:GetSetting('DKLevelBelow'))
    local high   = myLvl + Config:GetSetting('DKLevelAbove')
    local search = string.format('npc targetable %sradius %d zradius %d range %d %d',
        Config:GetSetting('DKUseLOS') and 'los ' or '',
        Config:GetSetting('DKPullRadius'), Config:GetSetting('DKPullZRadius'), low, high)
    local now = Globals.GetTimeSeconds()
    for i = 1, 5 do
        local spawn = mq.TLO.NearestSpawn(string.format('%d, %s', i, search))
        local id = spawn.ID() or 0
        if id == 0 then return nil end
        local failedAt = self.TempSettings.FailedPulls[id]
        if not failedAt or (now - failedAt) > 120 then
            return spawn
        end
    end
    return nil
end

--[[---------------------------------------------------------------------------
 Module:TryPull()
 WHAT:  Casts the pull spell at the best mob.
 WHY:   Starts the next kite without you tagging mobs by hand.
 WHERE: GiveTime(), only while standing still (at the anchor or in a cast
        window), under the train guard and with no hold.
 HOW:   Reads the spell name from the DKPullGem gem and calls
        Casting.UseSpell(name, targetId, false), the same function RGMercs
        rotations use. A mob that does not come within 10 seconds is
        skipped for 2 minutes.
 WHEN:  At most once per Pull Cooldown.
-----------------------------------------------------------------------------]]
function Module:TryPull()
    local t   = self.TempSettings
    local now = Globals.GetTimeSeconds()
    local gem = Config:GetSetting('DKPullGem')

    if t.PullTargetId > 0 and (now - t.LastPullTime) > 10 then
        t.FailedPulls[t.PullTargetId] = now
        t.PullTargetId = 0
    end

    if gem <= 0 then
        t.State, t.Reason = "Waiting", "Pull Spell Gem is 0. Pull by hand."
        return
    end
    if (now - t.LastPullTime) < Config:GetSetting('DKPullCooldown') then return end
    if mq.TLO.Me.Casting() then return end

    local spellName = mq.TLO.Me.Gem(gem).Name()
    if not spellName then
        t.State, t.Reason = "Waiting", string.format("No spell in gem %d.", gem)
        return
    end

    local spawn = self:FindPullTarget()
    if not spawn then
        t.State, t.Reason = "Waiting", "No valid mob in pull range."
        return
    end

    if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
    t.State, t.Reason = "Pulling", string.format("%s with %s", spawn.CleanName() or "mob", spellName)
    t.LastPullTime = now
    t.PullTargetId = spawn.ID()
    Casting.UseSpell(spellName, spawn.ID(), false)
end

--[[---------------------------------------------------------------------------
 Module:CheckEmergency()
 WHAT:  Handles very low HP while kiting.
 WHY:   Gives you a warning and one automatic escape command.
 WHERE: GiveTime() while mobs are on you.
 HOW:   Below Emergency HP: warn every 10 seconds; run the Emergency
        Command once. Resets once HP is back above Rest Until HP.
 WHEN:  Each kiting tick.
-----------------------------------------------------------------------------]]
function Module:CheckEmergency()
    local t   = self.TempSettings
    local hp  = mq.TLO.Me.PctHPs() or 100
    local now = Globals.GetTimeSeconds()
    if hp < Config:GetSetting('DKLowHPPct') then
        if (now - t.LastWarnTime) >= 10 then
            Logger.log_warn("\ar[DruidKite] LOW HP %d%% while kiting!\ax", hp)
            t.LastWarnTime = now
        end
        local cmd = Config:GetSetting('DKLowHPCommand') or ""
        if not t.LowHPCmdUsed and cmd:len() > 0 then
            mq.cmd(cmd)
            t.LowHPCmdUsed = true
        end
    elseif hp >= Config:GetSetting('DKRestHPPct') then
        t.LowHPCmdUsed = false
    end
end

--[[---------------------------------------------------------------------------
 Module:Watchdog()
 WHAT:  Stops the circle if RGMercs gets paused while DruidKite is kiting.
 WHY:   RGMercs skips module GiveTime() while paused, but the circle would
        keep running on its own.
 WHERE: Registered as an ImGui callback in Init(), so it runs every frame.
 HOW:   Only reads state and sends "/circle off" once. No delays.
 WHEN:  Every frame.
-----------------------------------------------------------------------------]]
function Module:Watchdog()
    local t = self.TempSettings
    if Globals.PauseMain and not t.Paused then
        if t.CircleExpected then mq.cmd('/squelch /circle off') end
        t.CircleExpected = false
        t.Paused = true
        t.State  = "Paused"
        t.Reason = "RGMercs was paused."
    end
end

--[[---------------------------------------------------------------------------
 Module:KiteTick(now, haters)
 WHAT:  Decides between running and casting while mobs are on you.
 WHY:   This is the Druid specific part: RGMercs only casts while you
        stand still, so the kite must open and close cast windows.
 WHERE: GiveTime() step 4.
 HOW:   Running: when the nearest mob is at least Cast Distance away,
        stop the circle and open a cast window.
        Casting: stay put and let RGMercs cast for as long as every mob on
        you is farther than Run Distance. Run again as soon as one comes
        within Run Distance, even mid cast. There is no time limit, so a
        melee mercenary can hold a mob away from you while you cast.
        While standing still and under the train guard, it may also pull
        the next mob.
 WHEN:  Every kiting tick.
-----------------------------------------------------------------------------]]
function Module:KiteTick(now, haters)
    local t    = self.TempSettings
    local dist = self:NearestHaterDistance()

    if t.State == "Casting" then
        if dist <= Config:GetSetting('DKRunGap') then
            self:StartCircle()
            t.State  = "Running"
            t.Reason = string.format("Mob within %.0f. Running.", dist)
            return
        end
        t.Reason = string.format("%d mob(s) on you. Nearest %.0f away. Casting.", haters, dist)
        if haters < Config:GetSetting('DKMaxHaters') and not self:SafetyHold() and not self:RestNeeded() then
            self:TryPull()
            t.State = "Casting"
        end
        return
    end

    -- Running (or just arrived from another state).
    if dist >= Config:GetSetting('DKCastGap') then
        self:StopCircle()
        if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
        t.CastStart = now
        t.State     = "Casting"
        t.Reason    = string.format("Nearest mob %.0f away. Casting.", dist)
        return
    end
    if not t.CircleExpected then self:StartCircle() end
    t.State  = "Running"
    t.Reason = string.format("%d mob(s) on you. Nearest %.0f away.", haters, dist)
end

--[[---------------------------------------------------------------------------
 Module:GiveTime()
 WHAT:  The DruidKite main tick and state machine.
 WHY:   Decides every moment whether to run, cast, wait, return, rest or
        pull.
 WHERE: Called by RGMercs every main loop tick while RGMercs is unpaused.
 HOW:   1. Run any queued button or command action.
        2. Stop here if paused. Throttle to 4 checks per second.
        3. If the circle was ours and is now off, you took control: pause.
        4. Mobs on you: KiteTick() plus the emergency HP check.
        5. No mobs: stop circle, wait for loot, walk back to anchor, then
           hold, rest (sitting to med) or pull.
 WHEN:  Every RGMercs tick.
-----------------------------------------------------------------------------]]
function Module:GiveTime()
    local t = self.TempSettings

    -- 1. Queued actions from the UI or /rgl druidkite.
    if t.PendingAction then
        local action = t.PendingAction
        t.PendingAction = nil
        if action == "start" then
            self:StartKite()
        elseif action == "pause" then
            self:PauseKite("Paused by you.")
        elseif action == "toggle" then
            if t.Paused then self:StartKite() else self:PauseKite("Paused by you.") end
        elseif action == "anchor" then
            self:SetAnchorHere()
            if t.CircleExpected then self:StartCircle() end
        end
    end

    -- 2. Paused or throttled.
    if t.Paused then return end
    local nowMS = Globals.GetTimeMS()
    if (nowMS - t.LastTickMS) < 250 then return end
    t.LastTickMS = nowMS
    local now = Globals.GetTimeSeconds()

    -- 3. Circle broken by a key press or another script.
    if t.CircleExpected and mq.TLO.Circle.Status() ~= 'on' then
        t.CircleExpected = false
        self:PauseKite("The circle was stopped by movement keys or another script. You have control.")
        return
    end

    local haters = Targeting.GetXTHaterCount()

    -- 4. Mobs on you: run or cast.
    if haters > 0 then
        t.LastHaterTime = now
        t.PullTargetId  = 0
        self:KiteTick(now, haters)
        self:CheckEmergency()
        return
    end

    -- 5. No mobs on you.
    if t.CircleExpected then self:StopCircle() end
    if t.State == "Casting" or t.State == "Running" then t.State = "Looting" end

    if (now - t.LastHaterTime) < Config:GetSetting('DKLootWait') then
        t.State, t.Reason = "Looting", "Waiting for your loot tool."
        return
    end

    if self:DistanceToAnchor() > 15 then
        if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
        if not mq.TLO.MoveTo.Moving() then
            mq.cmdf('/squelch /moveto loc %.2f %.2f', t.AnchorY, t.AnchorX)
        end
        t.State, t.Reason = "Return", "Walking back to the anchor."
        return
    end

    local hold = self:SafetyHold()
    if hold then
        t.State, t.Reason = "Holding", hold
        return
    end

    local rest = self:RestNeeded()
    if rest then
        t.State, t.Reason = "Resting", rest
        self:SitToMed()
        return
    end

    self:TryPull()
end

--[[---------------------------------------------------------------------------
 Module:PrintStatus()
 WHAT:  Prints the current DruidKite state to the MQ console.
 WHY:   Quick check without opening the tab.
 WHERE: /rgl druidkite status.
 HOW:   Logger.log_info().
 WHEN:  On demand.
-----------------------------------------------------------------------------]]
function Module:PrintStatus()
    local t = self.TempSettings
    Logger.log_info("\ag[DruidKite]\ax State: %s | %s | Mobs: %d | Anchor: %s",
        t.State, t.Reason or "", Targeting.GetXTHaterCount(),
        t.AnchorY and string.format("%.1f, %.1f", t.AnchorY, t.AnchorX) or "not set")
end

--[[---------------------------------------------------------------------------
 Module:ShouldRender() / Module:Render()
 WHAT:  Draws the DruidKite tab in RGMercs.
 WHY:   Start / PAUSE button, anchor button, live status and a list of
        RGMercs Druid options that need changing.
 WHERE: Called by RGMercs every frame the tab is visible.
 HOW:   Buttons only queue actions (PendingAction). Commands are sent
        later from GiveTime(), never from inside the UI frame.
 WHEN:  Every UI frame while the tab is open.
-----------------------------------------------------------------------------]]
function Module:ShouldRender()
    return true
end

function Module:Render()
    Base.Render(self)
    if not self.ModuleLoaded then return end
    local t = self.TempSettings

    if t.Paused then
        if ImGui.Button("Start Kiting", 160, 30) then t.PendingAction = "start" end
    else
        if ImGui.Button("PAUSE", 160, 30) then t.PendingAction = "pause" end
    end
    ImGui.SameLine()
    if ImGui.Button("Set Anchor Here", 160, 30) then t.PendingAction = "anchor" end

    ImGui.Separator()
    ImGui.Text(string.format("State:   %s", t.State))
    ImGui.TextWrapped(string.format("Detail:  %s", t.Reason or ""))
    ImGui.Text(string.format("Mobs on you: %d   (Train Guard: %d)", Targeting.GetXTHaterCount(), Config:GetSetting('DKMaxHaters')))
    ImGui.Text(string.format("Cast when mobs are %d+ away, run at %d",
        Config:GetSetting('DKCastGap'), Config:GetSetting('DKRunGap')))
    ImGui.Text(string.format("Mana: %d%%   (Rest until %d%%)", mq.TLO.Me.PctMana() or 0, Config:GetSetting('DKRestManaPct')))
    ImGui.Text(string.format("Anchor:  %s", t.AnchorY and string.format("%.1f, %.1f  (%.0f away)", t.AnchorY, t.AnchorX, self:DistanceToAnchor()) or "not set"))
    local gem = Config:GetSetting('DKPullGem')
    ImGui.Text(string.format("Pull spell: %s", gem > 0 and (mq.TLO.Me.Gem(gem).Name() or "empty gem") or "off (pull by hand)"))
    ImGui.Text(string.format("Circle: %s   RGMercs overrides: %s", mq.TLO.Circle.Status() or "?", t.OverridesOn and "on" or "off"))
    if #t.SetupProblems > 0 then
        ImGui.Separator()
        ImGui.TextWrapped("RGMercs Druid options to change:")
        for _, p in ipairs(t.SetupProblems) do ImGui.TextWrapped("  " .. p) end
    end
    ImGui.Separator()
    ImGui.TextWrapped("Settings: RGMercs Options > General > Uncategorized (Druid Kite sections), or search Druid Kite. Spells are set in the RGMercs Druid class settings.")
end

--[[---------------------------------------------------------------------------
 Module:OnZone() / Module:OnDeath()
 WHAT:  Pause and forget the anchor after zoning or dying.
 WHY:   DruidKite must never run to an old anchor in a new zone.
 WHERE: Called by RGMercs after a zone change or on death.
 HOW:   PauseKite() then ResetState().
 WHEN:  As named.
-----------------------------------------------------------------------------]]
function Module:OnZone()
    if not self.TempSettings.Paused then self:PauseKite("You changed zones.") end
    self:ResetState("You changed zones. Set a new anchor and press Start Kiting.")
end

function Module:OnDeath()
    if not self.TempSettings.Paused then self:PauseKite("You died.") end
    self:ResetState("You died. Press Start Kiting when ready.")
end

--[[---------------------------------------------------------------------------
 Module:Shutdown()
 WHAT:  Cleans up when the module is disabled or RGMercs stops.
 WHY:   Leaves nothing running: no circle, no temporary settings.
 WHERE: Called by RGMercs on unload.
 HOW:   Stops the circle if ours and clears overrides. The watchdog is
        removed by RGMercs because it was registered with RegisterImGui.
 WHEN:  On unload.
-----------------------------------------------------------------------------]]
function Module:Shutdown()
    if self.TempSettings.CircleExpected then mq.cmd('/squelch /circle off') end
    self.TempSettings.CircleExpected = false
    self:ClearOverrides()
    Base.Shutdown(self)
end

return Module

--[[
===============================================================================
 END OF FILE: druidkite.lua
-------------------------------------------------------------------------------
 CHANGE LOG:
   1.0.0  2026-11-23  First release. Built from BardKite 1.0.2. Added stop
                      to cast windows (Cast Distance and Run Distance, no
                      time limit so a melee mercenary can hold a mob while
                      you cast), sit to med while resting, a higher default mana
                      rest level, and a start check for the RGMercs Druid
                      options Use Snares, Only Dot Named and Mode. Removed
                      the MezOn override (Druids have no mez).
 MAINTENANCE NOTES:
   - Setting names must keep the DK prefix (RGMercs names are global, and
     BardKite uses BK).
   - Do not change _name; it is the settings namespace.
   - If RGMercs ever lets non Bards cast while moving, the cast windows
     can be removed. See Casting.MoveBlocksCast in utils/casting.lua.
===============================================================================
]]
