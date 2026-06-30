-- ============================================================================
-- modules/state.lua
-- Every runtime variable and its default value, in ONE place.
--
-- This module is PURE DATA. No game calls happen here — anything that needs the
-- game to be ready (reading blackboards, loading missions off disk) belongs in
-- CC.Init instead. Per our rules, this is the single home for state defaults so
-- that nothing gets quietly initialized in some scattered corner of another file.
--
-- The state is split into four lifetimes:
--   CONFIG        — tunables you edit by hand.
--   CONTENT       — loaded once, persists across deploys (the mission pool, etc.).
--   ACTIVE/EDITOR — the mission definition currently deployed or being built.
--   RUN STATE     — ephemeral execution layer, wiped on every deploy/abort/load.
--
-- That last split is the important one: it is how missions stay replayable. The
-- definition lives in the saved file; the running state is rebuilt from scratch
-- every time via ResetRunState() and is never saved.
-- ============================================================================

return function(CC)

    -- ========================================================================
    -- CONFIG — tunables. Safe to edit to taste.
    -- ========================================================================
    CC.config = {
        flagPrefix         = "cc_",  -- namespace hint for our own flags
        defaultProximity   = 10.0,   -- meters: default zone / proximity radius
        wakeJumpSeconds     = 3600,  -- in-game seconds jump that counts as "slept"
        eventWarmupSeconds  = 2.0,   -- grace after deploy before machines tick,
                                     --   so spawned entities have time to settle
    }

    -- ========================================================================
    -- CONTENT — loaded once at startup, persists across deploys.
    -- ========================================================================
    CC.manifest    = {}   -- list of mission file names found on disk
    CC.missionPool = {}   -- list of loaded mission DEFINITIONS (the playable set)
    CC.npcLibrary  = {}   -- optional catalogue of spawnable NPC records

    -- ========================================================================
    -- ACTIVE MISSION — the definition currently deployed (play) or open (editor).
    -- This is DATA: entities, flags, events, metadata. NOT runtime execution
    -- state (that lives in RUN STATE below).
    -- ========================================================================
    CC.activeMission = nil

    -- ========================================================================
    -- EDITOR STATE — only meaningful while CC.mode == "editor".
    -- ========================================================================
    CC.editor = {
        blueprint     = nil,    -- the mission being built (entities + events + flags)
        selectedLabel = nil,    -- label of the entity / zone currently selected
        dirty         = false,  -- true when there are unsaved changes
    }

    -- ========================================================================
    -- RUN STATE — ephemeral execution layer.
    -- Reset on every deploy / abort / game load. NEVER saved.
    -- ResetRunState() defines the COMPLETE set of run-state fields; calling it
    -- wipes everything back to defaults. Player/machine modules and the
    -- OnGameLoaded hook all call this — it is the single reset point.
    --
    -- (Read/write SEMANTICS for the flag bus live in modules/machine. This file
    --  only declares the tables; machine owns get/set and the write-after logic.)
    -- ========================================================================
    function CC.ResetRunState()
        -- The flag bus (the "blackboard"). key -> value. Every machine, zone,
        -- and the quest itself reads and writes here.
        CC.flags      = {}

        -- Pending flag writes, applied AFTER all machines have ticked this frame,
        -- so cross-machine ordering is deterministic (snapshot-read, write-after).
        CC.flagWrites = {}

        -- Per-machine runtime: label -> { stage = 0, ... }. One entry per entity
        -- or zone that has a state machine, plus the quest itself under "quest".
        CC.machines   = {}

        -- Running action SEQUENCES (a fired rule's action list executing over
        -- time; `wait` parks one, set_posture on the owner kills it).
        CC.sequences  = {}

        -- Spawned-entity bookkeeping.
        CC.labelToEntityId = {}   -- label -> EntityID of the spawned instance
        CC.spawnedIds      = {}   -- flat list of everything spawned (for cleanup)
        CC.spawnFixups     = {}   -- pending spawn materialization fixups

        -- Objective / completion tracking (resolved from activeMission on deploy).
        CC.objective     = nil
        CC.objectiveDone = false

        -- Timing.
        CC.deployClock = 0.0      -- seconds elapsed since deploy
        CC.warmupDone  = false    -- true once eventWarmupSeconds has passed

        -- Sleep-cycle / wake detection.
        CC.wakeReady    = false
        CC.lastGameTime = 0.0
    end

    -- Establish all run-state defaults at load time.
    CC.ResetRunState()

end
