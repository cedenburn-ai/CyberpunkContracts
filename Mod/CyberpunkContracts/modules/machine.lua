-- ============================================================================
-- modules/machine.lua
-- The state-machine engine. This is what makes a rule actually fire: it owns the
-- flag bus, arms the mission at deploy, and runs the per-frame tick that ties
-- conditions (the WHEN) to actions (the DO).
--
-- THE FLAG BUS — the one piece every other module leans on:
--   CC.getFlag(key)        read the CURRENT (already-applied) flag value
--   CC.setFlag(key, value) BUFFER a write; it does not take effect this frame
--   (writes are flushed to CC.flags only AFTER every rule has ticked)
--
-- Why buffered: it guarantees no rule sees a flag another rule changed mid-tick,
-- so ordering between machines never matters. A chain (rule A -> trigger -> rule
-- B) therefore advances exactly one rule per frame. At ~16ms that reads as
-- instant, and it removes the entire class of "why did X fire on deploy" bugs.
--
-- STAGE = FLAG. A machine's "stage" is just a flag keyed by its label, so
-- "Stage=1 on Jacksmith" is setFlag("Jacksmith", 1) and a rule gates on it with
-- a `flag` condition. There is no separate stage storage — it's all flags, which
-- is the whole point of the design.
--
-- SECOND-LOOK NOTES:
--   * Rules are ONE-SHOT (fire once, then done). That matches the old proven
--     event model and every stage-progression example. Re-arming rules (a
--     def.repeat flag) is a deliberate future addition, not a v1 default.
--   * Runtime state (the rt scratch) is NEVER stored on the rule definition —
--     it lives in a parallel wrapper so the JSON definition stays immutable and
--     replayable across deploys. The definition is data; rt is per-deploy.
-- ============================================================================

return function(CC)

    -- ========================================================================
    -- FLAG BUS
    -- ========================================================================

    function CC.getFlag(key)
        return CC.flags[key]
    end

    -- Buffer a write. Applied after the tick (see flushFlagWrites).
    function CC.setFlag(key, value)
        if key == nil then return end
        CC.flagWrites[key] = value
    end

    -- Arithmetic on a flag, buffer-aware: reads the pending write if one exists
    -- this tick, so several +1s in the same frame ACCUMULATE instead of losing
    -- updates. Non-numeric current values are treated as 0.
    function CC.modifyFlag(key, delta)
        if key == nil then return end
        local base = CC.flagWrites[key]
        if base == nil then base = CC.flags[key] end
        base = tonumber(base) or 0
        CC.flagWrites[key] = base + (tonumber(delta) or 0)
    end

    -- Convenience: a machine's stage is the flag keyed by its label.
    function CC.getStage(label)
        return CC.flags[label]
    end

    -- ========================================================================
    -- POSTURES — named behavior modes per object. A rule with def.posture only
    -- evaluates while its owner is in that posture; rules with no posture work
    -- in every posture. Posture changes are IMMEDIATE (not buffered): they are
    -- control signals — they cancel the owner's running sequences (knocking it
    -- out of any wait) and re-arm the entered posture's rules so postures are
    -- repeatable. Conflicts are last-write-wins: that's the level designer's job.
    -- ========================================================================
    local function postureKey(label) return tostring(label) .. "@posture" end

    function CC.getPosture(label)
        return CC.flags[postureKey(label)] or "default"
    end

    function CC.setPosture(label, posture)
        if not label or not posture then
            CC.logOnce("setposture_nil",
                "set_posture skipped: missing target or posture (left on '(pick)'?)")
            return
        end
        CC.flags[postureKey(label)] = posture          -- immediate, by design
        CC.cancelSequences(label)                       -- the wait override
        if CC.stopPatrol then CC.stopPatrol(label) end  -- a mode change ends the patrol too
        -- re-arm the entered posture's rules (fresh machine per entry)
        for _, r in ipairs(CC.rules or {}) do
            if r.self == label and r.def.posture == posture then
                r.rt.fired = false
                r.rt.conditionMet = false
                r.rt.metAt = nil
                r.rt.armedAt = CC.deployClock or 0
                r.rt.needFalse = false
            end
        end
        CC.log("posture: " .. label .. " -> " .. posture)   -- always visible
    end

    -- ========================================================================
    -- SEQUENCES — a fired rule's action list, executed over time. Instant verbs
    -- run back-to-back; `wait` (action.seconds) parks the sequence; a posture
    -- change on the owner cancels it mid-wait.
    -- ========================================================================
    local function advanceSequence(seq, ctx)
        while seq.idx <= #seq.actions do
            local a = seq.actions[seq.idx]
            local verb = a["do"] or a.action
            if verb == "wait" then
                seq.waitUntil = ctx.clock + (a.seconds or a.value or 1.0)
                seq.idx = seq.idx + 1
                return false                            -- parked
            end
            CC.runAction(a, ctx)
            seq.idx = seq.idx + 1
        end
        return true                                     -- finished
    end

    function CC.startSequence(owner, actions, ctx)
        if not actions or #actions == 0 then return end
        -- ONE activity per object: a new sequence REPLACES whatever the owner was
        -- doing (same contract as a posture change). Newest wins, by design.
        CC.cancelSequences(owner)
        local seq = { owner = owner, actions = actions, idx = 1, waitUntil = nil }
        if not advanceSequence(seq, ctx) then           -- run instants now; park on wait
            CC.sequences[#CC.sequences + 1] = seq
        end
    end

    function CC.cancelSequences(owner)
        if not CC.sequences then return end
        local keep = {}
        for _, seq in ipairs(CC.sequences) do
            if seq.owner ~= owner then keep[#keep + 1] = seq end
        end
        CC.sequences = keep
    end

    local function tickSequences(ctx)
        if not CC.sequences or #CC.sequences == 0 then return end
        local keep = {}
        for _, seq in ipairs(CC.sequences) do
            if seq.waitUntil and ctx.clock < seq.waitUntil then
                keep[#keep + 1] = seq                   -- still waiting
            else
                seq.waitUntil = nil
                if not advanceSequence(seq, ctx) then keep[#keep + 1] = seq end
            end
        end
        CC.sequences = keep
    end

    -- Apply all buffered writes into the live flag table, then clear the buffer.
    local function flushFlagWrites()
        for k, v in pairs(CC.flagWrites) do
            CC.flags[k] = v
        end
        CC.flagWrites = {}
    end

    -- ========================================================================
    -- ARMING (called once by the player's deploy, AFTER entities are spawned so
    -- CC.labelToEntityId is populated)
    -- ========================================================================

    -- Initialize flags from the mission definition: global flags, plus each
    -- entity's starting stage (flag keyed by its label). Written directly (not
    -- buffered) since this is one-time deploy setup, not in-tick.
    local function initFlags()
        local m = CC.activeMission
        if not m then return end

        if m.flags then
            for k, v in pairs(m.flags) do CC.flags[k] = v end
        end

        -- the QUEST is a machine too: it wakes up in its declared start phase
        CC.flags["quest@posture"] = m.basePosture or "default"

        if m.entities then
            for _, e in ipairs(m.entities) do
                if e.label then
                    if e.flags and e.flags.stage ~= nil then
                        CC.flags[e.label] = e.flags.stage          -- declared start stage
                    elseif e.events then
                        CC.flags[e.label] = 0                       -- entity has rules: default stage 0
                    end
                    -- every object wakes up in its declared base posture
                    CC.flags[e.label .. "@posture"] = e.basePosture or "default"
                end
            end
        end
    end

    -- Build the flat list of runtime rule instances from the mission. Each entry
    -- wraps the immutable definition with fresh rt scratch and its owner label.
    local function buildRules()
        CC.rules = {}
        local m = CC.activeMission
        if not m then return end
        local clock = CC.deployClock or 0

        local function add(def, selfLabel)
            CC.rules[#CC.rules + 1] = {
                def  = def,
                self = selfLabel,
                rt   = {
                    fired        = false,
                    conditionMet = false,
                    metAt        = nil,
                    armedAt      = clock,   -- timer conditions measure from here
                    seenAlive    = false,   -- dies tracks this
                    self         = selfLabel,
                },
            }
        end

        -- mission / quest-level rules
        local questEvents = m.quest_events or m.events
        if questEvents then
            for _, def in ipairs(questEvents) do add(def, "quest") end
        end

        -- per-entity rules (the per-object event structures)
        if m.entities then
            for _, e in ipairs(m.entities) do
                if e.events then
                    for _, def in ipairs(e.events) do add(def, e.label) end
                end
            end
        end
    end

    -- Run on_deploy rules immediately, BEFORE the warmup gate, so setup (initial
    -- attitudes) and any rolled variation (on_deploy + chance: fused doors, extra
    -- spawns) land before the first real tick. Flag writes are flushed right after
    -- so those rolled flags are live for everything that follows.
    local function fireOnDeploy(ctx)
        for _, r in ipairs(CC.rules) do
            local kind = r.def.when or r.def.condition
            if kind == "on_deploy" and not r.rt.fired then
                if math.random() <= (r.def.chance or 1.0) then
                    CC.startSequence(r.self, r.def.actions, ctx)
                end
                r.rt.fired = true
            end
        end
        flushFlagWrites()
    end

    -- ========================================================================
    -- QUEST LIFECYCLE ENVELOPE  (setup / win / lose / finally)
    -- The quest is a machine too: Setup = entry actions at deploy, Win/Lose =
    -- DNF condition groups checked each tick (ANY group fully true ends it),
    -- Finally = exit actions (run by the player at teardown). Each win/lose leaf
    -- gets its own rt scratch (dies/timer need it), built once here.
    -- ========================================================================
    local function buildLifecycle()
        CC.lifecycleRT     = { win = {}, lose = {} }
        CC.lifecycleHasWin = false
        local m  = CC.activeMission
        local lc = m and m.lifecycle
        if not lc then return end
        local clock = CC.deployClock or 0
        local function buildBox(box, store)
            for g, group in ipairs((box and box.groups) or {}) do
                store[g] = {}
                for ci = 1, #group do
                    store[g][ci] = { armedAt = clock, seenAlive = false, self = "quest" }
                end
            end
        end
        buildBox(lc.win,  CC.lifecycleRT.win)
        buildBox(lc.lose, CC.lifecycleRT.lose)
        CC.lifecycleHasWin = (lc.win and lc.win.groups and #lc.win.groups > 0) or false
    end

    -- Setup = entry actions, run once at deploy (formalizes on_deploy: set flags,
    -- roll random variation). Flushed right after so those values are live.
    local function fireSetup(ctx)
        local lc = CC.activeMission and CC.activeMission.lifecycle
        if lc and lc.setup and lc.setup.actions and #lc.setup.actions > 0 then
            CC.startSequence("quest", lc.setup.actions, ctx)
        end
        flushFlagWrites()
    end

    -- DNF: true if ANY group is fully satisfied (all its leaves true this tick).
    local function evalGroups(box, store, ctx)
        local groups = box and box.groups
        if not groups then return false end
        for g, group in ipairs(groups) do
            local all = #group > 0
            for ci, cond in ipairs(group) do
                store[g] = store[g] or {}
                local rt = store[g][ci]
                if not rt then rt = { armedAt = ctx.clock, self = "quest" }; store[g][ci] = rt end
                if not CC.evalCondition(cond, rt, ctx) then all = false; break end
            end
            if all then return true end
        end
        return false
    end

    -- Check win first, then lose. A complete/fail ends the mission immediately.
    local function tickLifecycle(ctx)
        local lc = CC.activeMission and CC.activeMission.lifecycle
        if not lc then return end
        if evalGroups(lc.win, CC.lifecycleRT.win, ctx) then
            if CC.completeMission then CC.completeMission() end
            return
        end
        if not CC.activeMission then return end
        if evalGroups(lc.lose, CC.lifecycleRT.lose, ctx) then
            if CC.failMission then CC.failMission() end
        end
    end

    -- The single deploy entry point the player calls.
    function CC.armMachines()
        if not CC.activeMission then return end
        CC.deployClock = 0.0
        CC.warmupDone  = false

        initFlags()
        buildRules()

        local ctx = { clock = 0.0, playerPos = nil }
        pcall(function() ctx.playerPos = Game.GetPlayer():GetWorldPosition() end)
        fireOnDeploy(ctx)
        buildLifecycle()                 -- quest win/lose scratch + the fallback flag
        fireSetup(ctx)                   -- lifecycle Setup = entry actions at deploy

        CC.log("armed: " .. #CC.rules .. " rule(s)")
    end

    -- ========================================================================
    -- TICK
    -- ========================================================================

    -- Advance one rule. condition -> latch -> wait delay -> chance roll -> fire.
    local function tickRule(r, ctx)
        local rt  = r.rt
        if rt.fired then return end
        local def = r.def

        -- on_deploy rules were handled at deploy; never tick them here.
        local kind = def.when or def.condition
        if kind == "on_deploy" then return end

        -- posture gate: a posture-scoped rule only lives while its owner is in it
        if def.posture and def.posture ~= "" and CC.getPosture(r.self) ~= def.posture then
            return
        end

        -- latch the condition the first time it's satisfied. A repeating rule
        -- that just fired must see the condition go FALSE once (falling edge)
        -- before it may latch again — otherwise standing in a zone machine-guns.
        if not rt.conditionMet then
            local met = CC.evalCondition(def, rt, ctx)
            if rt.needFalse then
                if not met then rt.needFalse = false end
            elseif met then
                rt.conditionMet = true
                rt.metAt        = ctx.clock
            end
        end

        -- once latched, wait out the delay, then roll and fire
        if rt.conditionMet then
            if (ctx.clock - rt.metAt) >= (def.delay or 0) then
                if math.random() <= (def.chance or 1.0) then
                    CC.startSequence(r.self, def.actions, ctx)   -- instants now, waits park
                end
                if def.repeats then
                    -- re-arm: fresh timer base, wait for the falling edge, and
                    -- consume one-shot trigger flags so they can't self-refire
                    rt.conditionMet = false
                    rt.metAt        = nil
                    rt.armedAt      = ctx.clock
                    rt.needFalse    = true
                    local kind = def.when or def.condition
                    if kind == "triggered" and def.id then
                        CC.setFlag(CC.trigKey(def.id), 0)
                    elseif kind == "interacted" and def.watch then
                        CC.setFlag(CC.interactKey(def.watch), 0)
                    end
                else
                    rt.fired = true   -- one-shot (the default)
                end
            end
        end
    end

    -- Called every frame in PLAY mode (init.lua dispatches this).
    function CC.TickMachines(dt)
        if not CC.activeMission or not CC.rules then return end

        CC.deployClock = (CC.deployClock or 0) + (dt or 0)

        -- warmup grace: let spawned entities settle before rules start evaluating
        if not CC.warmupDone then
            if CC.deployClock < (CC.config.eventWarmupSeconds or 0) then return end
            CC.warmupDone = true
        end

        -- per-tick context, computed once and shared by every condition
        local ctx = { clock = CC.deployClock, playerPos = nil }
        pcall(function() ctx.playerPos = Game.GetPlayer():GetWorldPosition() end)

        for _, r in ipairs(CC.rules) do
            if not CC.activeMission then break end   -- a complete/fail action can end the mission mid-tick
            tickRule(r, ctx)
        end

        -- the quest's own win/lose envelope (same flag snapshot the rules just read)
        if CC.activeMission then tickLifecycle(ctx) end
        if not CC.activeMission then return end   -- envelope ended the mission this tick

        tickSequences(ctx)   -- resume any sequences whose waits have elapsed

        -- flush AFTER every rule and sequence has read this frame's flag snapshot
        flushFlagWrites()
    end

end
