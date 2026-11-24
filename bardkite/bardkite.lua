--[[
===============================================================================
 FILE:        bardkite.lua
 MODULE:      BardKite, an RGMercs user module
 VERSION:     1.0.2
 DATE:        2026-11-23
 LICENSE:     GNU GPL v3 (same license as RGMercs, because this module runs
              inside RGMercs and uses its libraries)
 CREDITS:     Kiting idea and behavior based on "bardkite.mac" v0.5 (2005)
              by reghar on RedGuides, itself based on work by Siddin.
-------------------------------------------------------------------------------
 WHAT:  Adds circle kiting to the RGMercs Bard. RGMercs keeps doing all the
        singing (Selo's, damage over time chants, snare and slow, regen,
        melody management). BardKite only adds what RGMercs does not have:
          1. A kiting circle around an anchor spot while mobs are on you.
          2. A pull: sing one chosen song at a mob when you are ready.
          3. A train guard: never pull past a set number of mobs.
          4. Safety holds: stop pulling when a GM or another player is near,
             when your HP or mana is low, or when RGMercs is paused.
          5. A Pause / Start button and /rgl bardkite commands.
 WHY:   RGMercs only fights from a camp or by chasing. A solo Bard is at its
        best kiting. The 2005 macro did the kite but its song code no longer
        fits current clients. Combining them gets the best of both.
 WHERE: Copy this file to:
            <MacroQuest config folder>/rgmercs/modules/bardkite.lua
        Then open RGMercs, go to the UserModules tab, press Refresh and
        tick Enabled for BardKite. A "BardKite" tab appears in RGMercs.
 HOW:   RGMercs calls GiveTime() every main loop tick. BardKite reads the
        number of mobs on your extended target window and runs a small
        state machine:
            Paused  -> do nothing (you are in control)
            Kiting  -> mobs on you, circle around the anchor
            Looting -> no mobs, short wait so the RGMercs loot module works
            Return  -> walk back to the anchor
            Holding -> a safety rule is blocking new pulls
            Resting -> HP or mana below the rest threshold
            Pulling -> sing the pull song at the best nearby mob
        Movement uses MQ2MoveUtils commands taken from its own help text:
            /circle loc <y> <x>, /circle radius <#>, /circle off,
            /moveto loc <y> <x>
        Spawn searches use documented options only:
            npc, pc, gm, targetable, los, radius, zradius, range
        While kiting is on, BardKite applies TEMPORARY RGMercs settings
        (they clear when RGMercs restarts or when you pause BardKite):
            DoMelee off, DoAutoStick off, DoAutoNav off, FaceTarget off,
            HandleCantSeeTarget off, ReturnToCamp off, ChaseOn off,
            DoPull off, MezOn off, AssistRange raised to cover the kite.
        These stop RGMercs from walking to, sticking to, or turning toward a
        mob, which would break the circle and drag you into melee.
 WHEN:  Starts in the Paused state every time it loads. Nothing moves until
        you press Start or type /rgl bardkite start.
-------------------------------------------------------------------------------
 REQUIREMENTS:
   - RGMercs Lua (with the UserModules tab)
   - MQ2MoveUtils plugin loaded (/plugin MQ2MoveUtils)
   - A Bard. Turn on the damage over time songs you want in the RGMercs
     Bard settings (for example UseFireDots, UseIceDots) and DoSTSlow for
     Selo's Consonant Chain (snare plus slow).
-------------------------------------------------------------------------------
 SAFETY NOTES:
   - Pressing a movement key breaks the MQ2MoveUtils circle. BardKite treats
     that as "you took control" and pauses itself.
   - BardKite never stops circling on its own while mobs are on you, except
     when you pause it, when RGMercs is paused, or on zone or death. Standing
     still with mobs on a Bard is how Bards die.
===============================================================================
]]

local mq        = require('mq')
local ImGui     = require('ImGui')
local Base      = require("modules.base")
local Casting   = require("utils.casting")
local Config    = require('utils.config')
local Globals   = require("utils.globals")
local Logger    = require("utils.logger")
local Targeting = require("utils.targeting")

local Module    = {
    _version = '1.0.2',
    _name    = "BardKite",
    _author  = 'ElitePro (Roy) with credit to reghar and Siddin (2005)',
    _about   = "Circle kiting for the RGMercs Bard: kite circle, single song pull, train guard, safety holds and a pause button.",
}
Module.__index  = Module
setmetatable(Module, { __index = Base, })

--[[---------------------------------------------------------------------------
 Module.TempSettings
 WHAT:  Runtime state that is NOT saved between sessions.
 WHY:   The kite should always start paused, with no old anchor, after a
        restart or zone. Keeping state here makes that automatic.
 WHERE: Read and written throughout this file.
 HOW:   Plain table. Times are seconds from Globals.GetTimeSeconds().
 WHEN:  Reset in Init(), OnZone() and OnDeath().
-----------------------------------------------------------------------------]]
Module.TempSettings = {
    Paused         = true,  -- true = BardKite does nothing.
    State          = "Paused",
    Reason         = "Press Start to begin.",
    AnchorY        = nil,   -- Circle center, EverQuest Y (as /loc prints).
    AnchorX        = nil,   -- Circle center, EverQuest X.
    CircleExpected = false, -- true while BardKite has the circle running.
    OverridesOn    = false, -- true while temporary RGMercs settings are set.
    PendingAction  = nil,   -- Set by UI buttons, run in GiveTime().
    LastTickMS     = 0,
    LastHaterTime  = 0,     -- Last time any mob was on extended target.
    LastPullTime   = 0,
    PullTargetId   = 0,
    FailedPulls    = {},    -- [spawnId] = time; skipped for 120 seconds.
    LastWarnTime   = 0,
    LowHPCmdUsed   = false,
}

--[[---------------------------------------------------------------------------
 Module.CommandHandlers
 WHAT:  Adds /rgl bardkite <start|pause|toggle|anchor|status>.
 WHY:   So the kite can be controlled from hotkeys and other scripts, and so
        there is always a typed way to pause.
 WHERE: RGMercs dispatches /rgl subcommands to loaded modules.
 HOW:   Handlers only queue an action. GiveTime() carries it out on the
        RGMercs main loop, which is where commands are safe to send.
 WHEN:  Whenever you type the command.
-----------------------------------------------------------------------------]]
Module.CommandHandlers = {
    bardkite = {
        usage = "/rgl bardkite <start|pause|toggle|anchor|status>",
        about = "Control the BardKite circle kiting module.",
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
        Question = "How do I start Bard kiting?",
        Answer =
            "  Stand where you want the circle to be. Make sure the area is clear and flat with no walls. Open the BardKite tab and press Start. " ..
            "The anchor is set where you are standing. Set a Pull Song Gem so BardKite can pull, or pull by hand and it will kite whatever is on you.\n\n" ..
            "  Pause stops the circle and all pulls at once. You can also type /rgl bardkite pause.",
        Settings_Used = "BKPullGem",
    },
    {
        Question = "Why does BardKite pause itself?",
        Answer =
            "  It pauses when you zone, die, press a movement key (which breaks the circle), or pause RGMercs. " ..
            "This makes sure the script never fights you for control.",
        Settings_Used = "",
    },
}

--[[---------------------------------------------------------------------------
 Module.DefaultConfig
 WHAT:  The saved settings for BardKite, shown in the RGMercs settings window
        under General > Uncategorized, in three sections named Bard Kite
        Circle, Bard Kite Pulling and Bard Kite Safety. RGMercs only files a
        setting under a named header when its category is on the built in
        list in ui/options.lua; any other category goes to the catch all
        Uncategorized header. Group and Header fields are not used for that.
 WHY:   RGMercs stores, shows and saves these per character for us.
 WHERE: Read with Config:GetSetting('<name>').
 HOW:   Every name starts with "BK" because RGMercs setting names are global
        and must not collide with other modules.
 WHEN:  Loaded by Base.Init() at module load.
-----------------------------------------------------------------------------]]
Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    -- ---------------- Circle ----------------
    ['BKCircleRadius'] = {
        DisplayName = "Circle Radius",
        Category = "Bard Kite Circle", Index = 1,
        Tooltip = "Radius of the kiting circle. The 2005 macro used 35. Bigger circles are safer from mobs cutting across but need more open ground.",
        Default = 35, Min = 10, Max = 150,
    },
    ['BKLootWait'] = {
        DisplayName = "Loot Wait (seconds)",
        Category = "Bard Kite Circle", Index = 2,
        Tooltip = "After the last mob dies, wait this long before walking back to the anchor, so the RGMercs loot module can loot.",
        Default = 8, Min = 0, Max = 60,
    },
    -- ---------------- Pulling ----------------
    ['BKPullGem'] = {
        DisplayName = "Pull Song Gem",
        Category = "Bard Kite Pulling", Index = 1,
        Tooltip = "Spell gem of the song used to pull, usually a damage over time chant. 0 = never pull; you pull by hand and BardKite only kites.",
        Default = 0, Min = 0, Max = 13,
    },
    ['BKPullRadius'] = {
        DisplayName = "Pull Radius",
        Category = "Bard Kite Pulling", Index = 2,
        Tooltip = "Only pull mobs this close to you. Keep it inside your song range.",
        Default = 150, Min = 30, Max = 250,
    },
    ['BKPullZRadius'] = {
        DisplayName = "Pull Height Limit",
        Category = "Bard Kite Pulling", Index = 3,
        Tooltip = "Ignore mobs more than this far above or below you, such as mobs on another floor.",
        Default = 40, Min = 10, Max = 200,
    },
    ['BKMaxHaters'] = {
        DisplayName = "Max Mobs (Train Guard)",
        Category = "Bard Kite Pulling", Index = 4,
        Tooltip = "Never pull while this many mobs are on your extended target window. Start at 1 or 2.",
        Default = 2, Min = 1, Max = 8,
    },
    ['BKLevelAbove'] = {
        DisplayName = "Max Levels Above You",
        Category = "Bard Kite Pulling", Index = 5,
        Tooltip = "Highest mob level to pull, relative to you. The 2005 macro used 1.",
        Default = 1, Min = 0, Max = 10,
    },
    ['BKLevelBelow'] = {
        DisplayName = "Max Levels Below You",
        Category = "Bard Kite Pulling", Index = 6,
        Tooltip = "Lowest mob level to pull, relative to you.",
        Default = 10, Min = 0, Max = 60,
    },
    ['BKUseLOS'] = {
        DisplayName = "Line of Sight Only",
        Category = "Bard Kite Pulling", Index = 7,
        Tooltip = "Only pull mobs you can see.",
        Default = true,
    },
    ['BKPullCooldown'] = {
        DisplayName = "Pull Cooldown (seconds)",
        Category = "Bard Kite Pulling", Index = 8,
        Tooltip = "Minimum time between pull attempts.",
        Default = 6, Min = 2, Max = 60,
    },
    -- ---------------- Safety ----------------
    ['BKRestHPPct'] = {
        DisplayName = "Rest Until HP %",
        Category = "Bard Kite Safety", Index = 1,
        Tooltip = "Do not pull while your HP is below this.",
        Default = 80, Min = 1, Max = 100,
    },
    ['BKRestManaPct'] = {
        DisplayName = "Rest Until Mana %",
        Category = "Bard Kite Safety", Index = 2,
        Tooltip = "Do not pull while your mana is below this. Bard songs use little mana; 0 turns this off.",
        Default = 20, Min = 0, Max = 100,
    },
    ['BKLowHPPct'] = {
        DisplayName = "Emergency HP %",
        Category = "Bard Kite Safety", Index = 3,
        Tooltip = "Below this HP while kiting, BardKite warns you every 10 seconds and runs the Emergency Command once.",
        Default = 30, Min = 1, Max = 99,
    },
    ['BKLowHPCommand'] = {
        DisplayName = "Emergency Command",
        Category = "Bard Kite Safety", Index = 4,
        Tooltip = "Optional command you choose, run once per emergency, for example /useitem with your own potion. Leave blank for none.",
        Default = "",
    },
    ['BKPlayerCheck'] = {
        DisplayName = "Hold Pulls Near Players",
        Category = "Bard Kite Safety", Index = 5,
        Tooltip = "Stop pulling when another player (not in your group or friends list) is near. Keeps you from training people.",
        Default = true,
    },
    ['BKPlayerRadius'] = {
        DisplayName = "Player Check Radius",
        Category = "Bard Kite Safety", Index = 6,
        Tooltip = "Distance for the player check. The 2005 macro used 500.",
        Default = 300, Min = 50, Max = 1000,
    },
    ['BKFriends'] = {
        DisplayName = "Friends (comma list)",
        Category = "Bard Kite Safety", Index = 7,
        Tooltip = "Player names the player check ignores, separated by commas.",
        Default = "",
    },
    ['BKHoldOnGM'] = {
        DisplayName = "Hold Pulls When GM Visible",
        Category = "Bard Kite Safety", Index = 8,
        Tooltip = "Stop pulling while a visible GM is in the zone. Current mobs are still kited.",
        Default = true,
    },
}

-- Temporary RGMercs settings applied while kiting. See file header.
local RG_OVERRIDES = {
    { name = 'DoMelee',             value = false, },
    { name = 'DoAutoStick',         value = false, },
    { name = 'DoAutoNav',           value = false, },
    { name = 'FaceTarget',          value = false, },
    { name = 'HandleCantSeeTarget', value = false, },
    { name = 'ReturnToCamp',        value = false, },
    { name = 'ChaseOn',             value = false, },
    { name = 'DoPull',              value = false, },
    -- MezOn: RGMercs turns mezzing on by default for Bards, with Prioritize
    -- Mez on. While a mez is needed, Core.CombatActionsCheck() blocks all
    -- combat songs, so no DoTs go out, and the mezzed mobs stay on the
    -- extended target list, which keeps the circle running forever.
    -- Kiting needs every mob awake and dotted, so mezzing is off while kiting.
    { name = 'MezOn',               value = false, },
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
 WHAT:  Loads settings and makes sure BardKite starts paused.
 WHY:   Nothing should move the moment the module loads.
 WHERE: Called by RGMercs once at load.
 HOW:   Base.Init() loads the saved settings, then state is reset.
        A watchdog ImGui callback is registered (see Module:Watchdog()).
 WHEN:  Once per load.
-----------------------------------------------------------------------------]]
function Module:Init()
    Base.Init(self)
    self:ResetState("Press Start to begin.")
    self:RegisterImGui("BardKiteWatchdog", function() self:Watchdog() end)
    if not mq.TLO.Plugin('MQ2MoveUtils').IsLoaded() then
        Logger.log_warn("\ay[BardKite]\ax MQ2MoveUtils is not loaded. Type /plugin MQ2MoveUtils before pressing Start.")
    end
    if (mq.TLO.Me.Class.ShortName() or ""):upper() ~= "BRD" then
        Logger.log_warn("\ay[BardKite]\ax This module is written for Bards. Other classes cannot sing while moving.")
    end
    Logger.log_info("\ag[BardKite]\ax Loaded and paused. Open the BardKite tab and press Start.")
end

--[[---------------------------------------------------------------------------
 Module:ResetState(reason)
 WHAT:  Puts BardKite back in a clean paused state.
 WHY:   Used on load, zone and death so old anchors and pull data are never
        reused by mistake.
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
end

--[[---------------------------------------------------------------------------
 Module:ApplyOverrides() / Module:ClearOverrides()
 WHAT:  Turns the temporary RGMercs settings on or off.
 WHY:   RGMercs would otherwise stick to the target, nav to it, face it or
        return to camp, any of which breaks the kite.
 WHERE: StartKite(), PauseKite(), Shutdown().
 HOW:   Config:SetTempSetting() and Config:ClearTempSetting() change memory
        only; nothing is written to your saved RGMercs settings. pcall()
        guards against a setting name that does not exist on your build.
        AssistRange is raised so RGMercs keeps singing at mobs that are
        across the circle or still running in.
 WHEN:  On start, pause and unload.
-----------------------------------------------------------------------------]]
function Module:ApplyOverrides()
    for _, o in ipairs(RG_OVERRIDES) do
        pcall(function() Config:SetTempSetting(o.name, o.value) end)
    end
    local wanted = Config:GetSetting('BKPullRadius') + (Config:GetSetting('BKCircleRadius') * 2)
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
 WHY:   The 2005 macro remembered the start spot and always came back to it.
 WHERE: StartKite() (if no anchor yet), the "Set Anchor Here" button and
        /rgl bardkite anchor.
 HOW:   Reads Me.Y() and Me.X().
 WHEN:  On demand.
-----------------------------------------------------------------------------]]
function Module:SetAnchorHere()
    self.TempSettings.AnchorY = mq.TLO.Me.Y()
    self.TempSettings.AnchorX = mq.TLO.Me.X()
    Logger.log_info("\ag[BardKite]\ax Anchor set at %.1f, %.1f", self.TempSettings.AnchorY, self.TempSettings.AnchorX)
end

--[[---------------------------------------------------------------------------
 Module:StartKite() / Module:PauseKite(reason)
 WHAT:  The Start and Pause actions.
 WHY:   Every tool in this project has a pause control. Pause must stop all
        movement BardKite started, right away.
 WHERE: PendingAction handling in GiveTime(), Watchdog(), safety checks.
 HOW:   Start: set anchor if needed, apply overrides, unpause.
        Pause: stop circle and moveto (by issuing /circle off; a new
        /circle or /moveto also ends the old one), clear overrides.
        RGMercs itself keeps running, so songs and heals continue.
 WHEN:  On button press, command, or automatic safety pause.
-----------------------------------------------------------------------------]]
function Module:StartKite()
    if not mq.TLO.Plugin('MQ2MoveUtils').IsLoaded() then
        Logger.log_error("\ar[BardKite]\ax MQ2MoveUtils is not loaded. Type /plugin MQ2MoveUtils first.")
        return
    end
    if not self.TempSettings.AnchorY then self:SetAnchorHere() end
    self:ApplyOverrides()
    self.TempSettings.Paused       = false
    self.TempSettings.LowHPCmdUsed = false
    self.TempSettings.Reason       = ""
    Logger.log_info("\ag[BardKite]\ax Started.")
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
    Logger.log_info("\ay[BardKite]\ax Paused: %s", t.Reason)
end

--[[---------------------------------------------------------------------------
 Module:StartCircle() / Module:StopCircle()
 WHAT:  Runs or stops the MQ2MoveUtils circle around the anchor.
 WHY:   The circle is the kite.
 WHERE: GiveTime() state machine.
 HOW:   "/circle loc <y> <x>" turns the circle on at the anchor, then
        "/circle radius <#>" sizes the running circle. CircleExpected lets
        GiveTime() notice when something else (a key press) stopped it.
 WHEN:  When mobs arrive and when the last one dies.
-----------------------------------------------------------------------------]]
function Module:StartCircle()
    local t = self.TempSettings
    mq.cmdf('/squelch /circle loc %.2f %.2f', t.AnchorY, t.AnchorX)
    mq.cmdf('/squelch /circle radius %d', Config:GetSetting('BKCircleRadius'))
    t.CircleExpected = true
end

function Module:StopCircle()
    mq.cmd('/squelch /circle off')
    self.TempSettings.CircleExpected = false
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
 Module:IsFriend(name)
 WHAT:  True if a player name is in your BKFriends list.
 WHY:   So boxed characters or friends do not hold your pulls.
 WHERE: NearbyStranger().
 HOW:   Splits BKFriends on commas, trims spaces, compares lowercase.
 WHEN:  During the player check.
-----------------------------------------------------------------------------]]
function Module:IsFriend(name)
    if not name then return false end
    local list = (Config:GetSetting('BKFriends') or ""):lower()
    for entry in list:gmatch("[^,]+") do
        if entry:match("^%s*(.-)%s*$") == name:lower() then return true end
    end
    return false
end

--[[---------------------------------------------------------------------------
 Module:NearbyStranger()
 WHAT:  Returns the name of the closest player near you who is not you,
        not in your group and not on your friends list, or nil.
 WHY:   Port of the 2005 "playercheck". Kiting near strangers risks
        training them and draws attention.
 WHERE: SafetyHold().
 HOW:   SpawnCount('pc radius R'), then NearestSpawn('<n>, pc radius R')
        for each one, skipping self, group members and friends.
        Checks at most 10 players to keep the tick cheap.
 WHEN:  Each tick while deciding whether to pull.
-----------------------------------------------------------------------------]]
function Module:NearbyStranger()
    local radius = Config:GetSetting('BKPlayerRadius')
    local search = string.format('pc radius %d', radius)
    local count  = math.min(mq.TLO.SpawnCount(search)() or 0, 10)
    local myId   = mq.TLO.Me.ID()
    for i = 1, count do
        local pc = mq.TLO.NearestSpawn(string.format('%d, %s', i, search))
        local id = pc.ID() or 0
        local name = pc.CleanName()
        if id > 0 and id ~= myId and name and not mq.TLO.Group.Member(name)() and not self:IsFriend(name) then
            return name
        end
    end
    return nil
end

--[[---------------------------------------------------------------------------
 Module:SafetyHold()
 WHAT:  Returns a reason string if pulling must wait, or nil if it is safe.
 WHY:   Collects every "do not pull now" rule in one place.
 WHERE: GiveTime().
 HOW:   Checks, in order: RGMercs paused, GM visible, nearby stranger,
        resting HP, resting mana.
 WHEN:  Each tick while deciding whether to pull.
-----------------------------------------------------------------------------]]
function Module:SafetyHold()
    if Config:GetSetting('BKHoldOnGM') and (mq.TLO.SpawnCount('gm')() or 0) > 0 then
        return "A GM is visible in the zone."
    end
    if Config:GetSetting('BKPlayerCheck') then
        local who = self:NearbyStranger()
        if who then return string.format("Player %s is nearby.", who) end
    end
    return nil
end

function Module:RestNeeded()
    if (mq.TLO.Me.PctHPs() or 100) < Config:GetSetting('BKRestHPPct') then
        return "Resting for HP."
    end
    local manaRest = Config:GetSetting('BKRestManaPct')
    if manaRest > 0 and (mq.TLO.Me.MaxMana() or 0) > 0 and (mq.TLO.Me.PctMana() or 100) < manaRest then
        return "Resting for mana."
    end
    return nil
end

--[[---------------------------------------------------------------------------
 Module:FindPullTarget()
 WHAT:  Finds the closest mob that is safe and sensible to pull.
 WHY:   Port of the 2005 target logic, with a level floor, a height limit
        and a skip list for mobs that failed to pull.
 WHERE: TryPull().
 HOW:   Search string, for example:
            npc targetable los radius 150 zradius 40 range 20 31
        Walks the 5 nearest matches and returns the first one not skipped.
 WHEN:  When a pull is allowed.
-----------------------------------------------------------------------------]]
function Module:FindPullTarget()
    local myLvl  = mq.TLO.Me.Level() or 1
    local low    = math.max(1, myLvl - Config:GetSetting('BKLevelBelow'))
    local high   = myLvl + Config:GetSetting('BKLevelAbove')
    local search = string.format('npc targetable %sradius %d zradius %d range %d %d',
        Config:GetSetting('BKUseLOS') and 'los ' or '',
        Config:GetSetting('BKPullRadius'), Config:GetSetting('BKPullZRadius'), low, high)
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
 WHAT:  Sings the pull song at the best mob.
 WHY:   Starts the next kite without you having to tag mobs by hand.
 WHERE: GiveTime(), only when no mobs are on you and nothing holds pulls.
 HOW:   Reads the song name from the BKPullGem gem and calls
        Casting.UseSong(name, targetId, false), the same function the
        RGMercs Bard rotations use, so song timing is handled by RGMercs.
        If the last pull did not bring a mob within 10 seconds, that mob
        is skipped for 2 minutes (it may be out of reach or resisted).
 WHEN:  At most once per BKPullCooldown seconds.
-----------------------------------------------------------------------------]]
function Module:TryPull()
    local t   = self.TempSettings
    local now = Globals.GetTimeSeconds()
    local gem = Config:GetSetting('BKPullGem')

    if t.PullTargetId > 0 and (now - t.LastPullTime) > 10 then
        t.FailedPulls[t.PullTargetId] = now
        t.PullTargetId = 0
    end

    if gem <= 0 then
        t.State, t.Reason = "Waiting", "Pull Song Gem is 0. Pull by hand."
        return
    end
    if (now - t.LastPullTime) < Config:GetSetting('BKPullCooldown') then return end

    local songName = mq.TLO.Me.Gem(gem).Name()
    if not songName then
        t.State, t.Reason = "Waiting", string.format("No song in gem %d.", gem)
        return
    end

    local spawn = self:FindPullTarget()
    if not spawn then
        t.State, t.Reason = "Waiting", "No valid mob in pull range."
        return
    end

    t.State, t.Reason = "Pulling", string.format("%s with %s", spawn.CleanName() or "mob", songName)
    t.LastPullTime = now
    t.PullTargetId = spawn.ID()
    Casting.UseSong(songName, spawn.ID(), false)
end

--[[---------------------------------------------------------------------------
 Module:CheckEmergency()
 WHAT:  Handles very low HP while kiting.
 WHY:   The 2005 macro called for an evac. Current Bards may not have one,
        so BardKite warns and runs a command you choose, once.
 WHERE: GiveTime() while kiting.
 HOW:   Below BKLowHPPct: warn every 10 seconds; run BKLowHPCommand once.
        Resets after HP recovers above the rest threshold.
 WHEN:  Each kiting tick.
-----------------------------------------------------------------------------]]
function Module:CheckEmergency()
    local t   = self.TempSettings
    local hp  = mq.TLO.Me.PctHPs() or 100
    local now = Globals.GetTimeSeconds()
    if hp < Config:GetSetting('BKLowHPPct') then
        if (now - t.LastWarnTime) >= 10 then
            Logger.log_warn("\ar[BardKite] LOW HP %d%% while kiting!\ax", hp)
            t.LastWarnTime = now
        end
        local cmd = Config:GetSetting('BKLowHPCommand') or ""
        if not t.LowHPCmdUsed and cmd:len() > 0 then
            mq.cmd(cmd)
            t.LowHPCmdUsed = true
        end
    elseif hp >= Config:GetSetting('BKRestHPPct') then
        t.LowHPCmdUsed = false
    end
end

--[[---------------------------------------------------------------------------
 Module:Watchdog()
 WHAT:  Stops the circle if RGMercs gets paused while BardKite is kiting.
 WHY:   RGMercs does not call module GiveTime() while it is paused, but the
        MQ2MoveUtils circle would keep running on its own. This closes that
        gap so a paused RGMercs never leaves you running in circles.
 WHERE: Registered as an ImGui callback in Init(), so it runs every frame
        whether or not RGMercs is paused.
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
 Module:GiveTime()
 WHAT:  The BardKite main tick and state machine.
 WHY:   Decides every moment whether to circle, wait, return or pull.
 WHERE: Called by RGMercs every main loop tick while RGMercs is unpaused.
 HOW:   1. Run any queued button or command action.
        2. Stop here if paused. Throttle to 4 checks per second.
        3. If the circle was ours and is now off, you took control: pause.
        4. Mobs on you: keep circling, check emergency HP, maybe pull more
           (only below the train guard and with no safety hold).
        5. No mobs: stop circle, wait for loot, walk back to anchor, then
           rest, hold or pull.
 WHEN:  Every RGMercs tick.
-----------------------------------------------------------------------------]]
function Module:GiveTime()
    local t = self.TempSettings

    -- 1. Queued actions from the UI or /rgl bardkite.
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

    -- 4. Mobs on you: kite.
    if haters > 0 then
        t.LastHaterTime = now
        t.PullTargetId  = 0
        if not t.CircleExpected then self:StartCircle() end
        t.State, t.Reason = "Kiting", string.format("%d mob(s) on you.", haters)
        self:CheckEmergency()

        if haters < Config:GetSetting('BKMaxHaters') and not self:SafetyHold() and not self:RestNeeded() then
            self:TryPull()
            if t.State == "Pulling" or t.State == "Waiting" then
                t.State = "Kiting"
            end
        end
        return
    end

    -- 5. No mobs on you.
    if t.CircleExpected then self:StopCircle() end

    if (now - t.LastHaterTime) < Config:GetSetting('BKLootWait') then
        t.State, t.Reason = "Looting", "Waiting for the loot module."
        return
    end

    if self:DistanceToAnchor() > 15 then
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
        return
    end

    self:TryPull()
end

--[[---------------------------------------------------------------------------
 Module:PrintStatus()
 WHAT:  Prints the current BardKite state to the MQ chat window.
 WHY:   Quick check without opening the tab.
 WHERE: /rgl bardkite status.
 HOW:   Logger.log_info().
 WHEN:  On demand.
-----------------------------------------------------------------------------]]
function Module:PrintStatus()
    local t = self.TempSettings
    Logger.log_info("\ag[BardKite]\ax State: %s | %s | Mobs: %d | Anchor: %s",
        t.State, t.Reason or "", Targeting.GetXTHaterCount(),
        t.AnchorY and string.format("%.1f, %.1f", t.AnchorY, t.AnchorX) or "not set")
end

--[[---------------------------------------------------------------------------
 Module:ShouldRender() / Module:Render()
 WHAT:  Draws the BardKite tab in RGMercs.
 WHY:   Gives the Start / Pause button, an anchor button and live status.
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
    ImGui.Text(string.format("Mobs on you: %d   (Train Guard: %d)", Targeting.GetXTHaterCount(), Config:GetSetting('BKMaxHaters')))
    ImGui.Text(string.format("Anchor:  %s", t.AnchorY and string.format("%.1f, %.1f  (%.0f away)", t.AnchorY, t.AnchorX, self:DistanceToAnchor()) or "not set"))
    local gem = Config:GetSetting('BKPullGem')
    ImGui.Text(string.format("Pull song: %s", gem > 0 and (mq.TLO.Me.Gem(gem).Name() or "empty gem") or "off (pull by hand)"))
    ImGui.Text(string.format("Circle: %s   RGMercs overrides: %s", mq.TLO.Circle.Status() or "?", t.OverridesOn and "on" or "off"))
    ImGui.Separator()
    ImGui.TextWrapped("Settings: RGMercs Options > General > Uncategorized (Bard Kite sections), or search Bard Kite. Songs are set in the RGMercs Bard class settings.")
end

--[[---------------------------------------------------------------------------
 Module:OnZone() / Module:OnDeath()
 WHAT:  Pause and forget the anchor after zoning or dying.
 WHY:   The 2005 macro camped out on zone. Pausing is gentler and still
        guarantees BardKite never runs to an old anchor in a new zone.
 WHERE: Called by RGMercs after a zone change or on death.
 HOW:   PauseKite() then ResetState().
 WHEN:  As named.
-----------------------------------------------------------------------------]]
function Module:OnZone()
    if not self.TempSettings.Paused then self:PauseKite("You changed zones.") end
    self:ResetState("You changed zones. Set a new anchor and press Start.")
end

function Module:OnDeath()
    if not self.TempSettings.Paused then self:PauseKite("You died.") end
    self:ResetState("You died. Press Start when ready.")
end

--[[---------------------------------------------------------------------------
 Module:Shutdown()
 WHAT:  Cleans up when the module is disabled or RGMercs stops.
 WHY:   Leaves nothing running: no circle, no temporary settings.
 WHERE: Called by RGMercs on unload.
 HOW:   Stops the circle if ours and clears overrides. Events, binds and
        the ImGui watchdog are removed by RGMercs automatically because
        they were registered with self:Register*.
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
 END OF FILE: bardkite.lua
-------------------------------------------------------------------------------
 CHANGE LOG:
   1.0.0  2026-11-23  First release. Rebuilt the 2005 bardkite.mac as an
                      RGMercs user module. Song logic (Selo's, heal, snare,
                      twist) removed in favor of the RGMercs Bard rotation.
                      Kept: circle at a start anchor, return after loot,
                      level limits, player check, GM check. Added: train
                      guard, pull song, height limit, failed pull skip list,
                      rest thresholds, emergency command, Pause button,
                      key press takeover, RGMercs pause watchdog.
   1.0.1  2026-11-23  Settings now use categories named Bard Kite Circle,
                      Bard Kite Pulling and Bard Kite Safety. They show under
                      General > Uncategorized. The old category "Pulling"
                      clashed with the RGMercs Pulling header name. Fixed
                      the settings location text on the BardKite tab.
   1.0.2  2026-11-23  Added MezOn off to the temporary RGMercs overrides.
                      Found in the first live test: RGMercs mezzed the
                      pirates, which blocked the DoT songs and kept the
                      mezzed mobs on extended target, so the circle never
                      ended. Also noted that the RGMercs loot module only
                      runs on emulator servers.
   Removed from 2005 on purpose: auto camp to desktop on zone or player,
   coin destroying, MQ2DoCrack, public chat. RedGuides rules require
   automated communication to stay private.
 MAINTENANCE NOTES:
   - Setting names must keep the BK prefix (RGMercs names are global).
   - Do not change _name; it is the settings namespace.
   - After an RGMercs update, re-test: user modules can break if RGMercs
     internals change (see docs/user_modules.md in RGMercs).
   - Only use MQ2MoveUtils commands that appear in its help text.
===============================================================================
]]
