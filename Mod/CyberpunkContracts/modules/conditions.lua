-- ============================================================================
-- modules/conditions.lua
-- The WHEN half of a rule. Each evaluator answers ONE question: "is this
-- condition satisfied right now?" — nothing else. chance, delay, and firing are
-- the machine's job; conditions only read state + the world and return a bool.
--
-- Signature:  CC.conditions[kind](rule, rt, ctx) -> bool
--   rule : the rule definition (.watch, .radius, .flag, .op, .value, .after ...)
--   rt   : this rule's per-instance runtime scratch. The machine owns it and
--          resets it on deploy. Conditions may stash small memory here (e.g.
--          dies uses rt.seenAlive; timer uses rt.armedAt set by the machine).
--   ctx  : per-tick shared context the machine computes ONCE and passes in:
--            ctx.playerPos : Vector4 of the player this frame (or nil)
--            ctx.clock     : seconds elapsed since deploy
--
-- triggered / interacted route through the flag bus (reserved-prefix keys) so we
-- don't invent a second bookkeeping table — in this system everything is flags.
-- (CC.getFlag is defined in modules/machine; it's resolved at CALL time, so the
--  fact that machine loads after this file doesn't matter.)
-- ============================================================================

return function(CC)

    -- Read a flag safely even if the machine (which owns getFlag) isn't loaded
    -- yet. Note the explicit nil return so a real flag value of 0 isn't lost.
    local function flagVal(key)
        if CC.getFlag then return CC.getFlag(key) end
        return nil
    end

    -- ------------------------------------------------------------------------
    -- SHARED RESOLVERS  (live here because conditions needs them first; actions
    -- reuse them, so there is one definition of each — no drift).
    -- ------------------------------------------------------------------------

    -- label -> world position. Live spawned entity first (it may have moved),
    -- else the definition's stored position (zones and anything un-spawned).
    function CC.labelPos(label)
        local ent = CC.entityByLabel(label)
        if ent then
            local p = CC.worldPos(ent)
            if p then return p end
        end
        if CC.activeMission and CC.activeMission.entities then
            for _, e in ipairs(CC.activeMission.entities) do
                if e.label == label then return CC.vec4(e.x, e.y, e.z) end
            end
        end
        return nil
    end

    -- label -> the entity DEFINITION in the active mission (zones carry their
    -- shape/dims there; conditions need it to know how to test containment).
    function CC.labelDef(label)
        if CC.activeMission and CC.activeMission.entities then
            for _, e in ipairs(CC.activeMission.entities) do
                if e.label == label then return e end
            end
        end
        return nil
    end

    -- Reserved internal flag keys. The trigger action and the interact handler
    -- build the SAME keys via these, so a chain can never silently miswire.
    function CC.trigKey(id)      return "__trig_" .. tostring(id) end
    function CC.interactKey(lbl) return "__interact_" .. tostring(lbl) end

    -- comparison helper for flag conditions (default is equals)
    local function compare(a, op, b)
        if op == nil or op == "eq" then return a == b end
        if op == "ne" then return a ~= b end
        local na, nb = tonumber(a), tonumber(b)   -- numeric ops
        if na == nil or nb == nil then return false end
        if op == "gt" then return na >  nb end
        if op == "lt" then return na <  nb end
        if op == "ge" then return na >= nb end
        if op == "le" then return na <= nb end
        return false
    end

    -- Is point p inside the zone described by def (sphere or box) at zpos?
    -- One containment test shared by `proximity` (V) and `inside` (an NPC).
    local function zoneContains(def, zpos, p, fallbackRadius)
        if not zpos or not p then return false end
        if def and def.shape == "box" then
            local hx, hy = (def.sx or 4.0) * 0.5, (def.sy or 4.0) * 0.5
            local dx, dy = p.x - zpos.x, p.y - zpos.y
            local dz = p.z - zpos.z
            return math.abs(dx) <= hx and math.abs(dy) <= hy
               and dz >= -0.3 and dz <= (def.sz or 3.0)
        end
        local r = (def and def.radius) or fallbackRadius or CC.config.defaultProximity
        return CC.dist3(p, zpos) <= r
    end

    -- ------------------------------------------------------------------------
    -- THE EVALUATORS
    -- ------------------------------------------------------------------------
    CC.conditions = {}

    -- Fires immediately at deploy. The machine runs on_deploy rules at deploy
    -- time, BEFORE the warmup gate, so this just reports "ready."
    CC.conditions.on_deploy = function(rule, rt, ctx)
        return true
    end

    -- Fires the moment the owning object ENTERS this rule's posture. Mechanism:
    -- the rule is posture-gated (only ticks inside its posture) and setPosture
    -- re-arms it on every entry — so "always true" here means "once per entry."
    CC.conditions.on_enter = function(rule, rt, ctx)
        return true
    end

    -- "V near target": the PLAYER is within the watched zone/entity's volume.
    CC.conditions.proximity = function(rule, rt, ctx)
        if not ctx.playerPos then return false end
        local pos = CC.labelPos(rule.watch)
        if not pos then return false end
        local def = CC.labelDef(rule.watch)
        local hit = zoneContains(def, pos, ctx.playerPos, rule.radius)
        if CC.debug and (not rt._proxNext or (ctx.clock or 0) >= rt._proxNext) then
            rt._proxNext = (ctx.clock or 0) + 1.0
            CC.log(string.format("PROX %s: %s", tostring(rule.watch), hit and "INSIDE" or "outside"))
        end
        if hit then
            CC.log(string.format("PROX FIRE %s", tostring(rule.watch)))
            return true
        end
        return false
    end

    -- "target inside zone": a WATCHED object (NPC etc) is inside a zone's volume.
    -- rule.watch = the moving thing, rule.zone = the zone label.
    CC.conditions.inside = function(rule, rt, ctx)
        local p    = CC.labelPos(rule.watch)
        local zpos = CC.labelPos(rule.zone)
        if not p or not zpos then return false end
        return zoneContains(CC.labelDef(rule.zone), zpos, p)
    end

    -- Watched entity is dead or despawned. Counts ONLY after we've seen it alive,
    -- so a spawn-delay nil can't false-trigger (the old code's hard-won lesson).
    -- VERIFY-IN-GAME: IsDead() exists on puppets; pcall'd so non-puppets fall
    -- through to the despawn path harmlessly.
    CC.conditions.dies = function(rule, rt, ctx)
        local ent = CC.entityByLabel(rule.watch)
        if ent then
            rt.seenAlive = true
            local dead = false
            pcall(function() dead = ent:IsDead() end)
            return dead == true
        end
        return rt.seenAlive == true   -- handle gone, and we'd seen it alive: dead
    end

    -- Every spawned non-friendly entity is dead/gone. The lifecycle's "kill
    -- everyone" primitive (what the old kill_all objective did). Latches rt.sawAny
    -- so it can't true-fire before anything has spawned.
    CC.conditions.all_dead = function(rule, rt, ctx)
        local map = CC.labelToEntityId
        if not map then return false end
        local anyAlive = false
        for label, _ in pairs(map) do
            if not (CC.friendlyLabels and CC.friendlyLabels[label]) then
                local ent = CC.entityByLabel(label)
                if ent then
                    rt.sawAny = true
                    local dead = false
                    pcall(function() dead = ent:IsDead() end)
                    if not dead then anyAlive = true end
                end
            end
        end
        return (rt.sawAny == true) and (not anyAlive)
    end


    -- Watched entity is hostile to the player (via its AttitudeAgent).
    -- VERIFY-IN-GAME: the enum is EAIAttitude.AIA_Hostile; pcall'd to fail safe.
    CC.conditions.aggro = function(rule, rt, ctx)
        local ent = CC.entityByLabel(rule.watch)
        if not ent then return false end
        local hostile = false
        pcall(function()
            local mine   = ent:GetAttitudeAgent()
            local theirs = Game.GetPlayer():GetAttitudeAgent()
            hostile = (mine:GetAttitudeTowards(theirs) == EAIAttitude.AIA_Hostile)
        end)
        return hostile
    end

    -- An interact point with this label was triggered (the interact handler sets
    -- the reserved flag when the player presses [F]).
    CC.conditions.interacted = function(rule, rt, ctx)
        return flagVal(CC.interactKey(rule.watch)) == 1
    end

    -- Fires once rule.after seconds have passed since this rule ARMED.
    -- (rt.armedAt is stamped by the machine when the rule becomes live; defaults
    --  to deploy. rule.delay accepted as the old field name.)
    CC.conditions.timer = function(rule, rt, ctx)
        local dur     = rule.after or rule.delay or 0
        local armedAt = rt.armedAt or 0
        return (ctx.clock - armedAt) >= dur
    end

    -- Another rule fired a `trigger` at this one (chaining), routed through a
    -- reserved internal flag instead of a second table.
    CC.conditions.triggered = function(rule, rt, ctx)
        return flagVal(CC.trigKey(rule.id)) == 1
    end

    -- True while the WATCHED object is in the named posture (cross-object check;
    -- the one-shot latch makes it fire on entry). rule.watch + rule.in_posture.
    -- CC.getPosture lives in machine; resolved at call time.
    CC.conditions.posture = function(rule, rt, ctx)
        if not CC.getPosture then return false end
        return CC.getPosture(rule.watch) == rule.in_posture
    end

    -- A flag equals (or compares against) a value. THE bus condition — this is
    -- what lets a zone, an actor, and the quest interact, and what expresses
    -- durative state when paired with a timer flag ("alarm on for >10s").
    --   rule.flag / rule.key : flag key
    --   rule.value / rule.eq : value to compare against
    --   rule.op              : "eq"(default) | "ne" | "gt" | "lt" | "ge" | "le"
    CC.conditions.flag = function(rule, rt, ctx)
        local key  = rule.flag or rule.key
        local want
        if rule.other and rule.other ~= "" then
            want = flagVal(rule.other)        -- variable vs VARIABLE
        else
            want = rule.value
            if want == nil then want = rule.eq end
        end
        return compare(flagVal(key), rule.op, want)
    end

    -- Watched NPC's Health stat-pool dropped below a percentage -- the reactive
    -- "wounded" trigger (at low HP: flee, change posture, call backup). The Health
    -- pool is 0-100, so the threshold is a percent and works for any NPC regardless
    -- of max HP. Fires only while ALIVE (use `dies` for death); the read is pcall'd
    -- and fails safe; NOT in NO_REPEAT, so `repeats` re-fires if it heals then drops.
    --   rule.watch = NPC label
    --   rule.below = threshold percent (default 50)
    CC.conditions.health = function(rule, rt, ctx)
        local ent = CC.entityByLabel(rule.watch)
        if not ent then return false end
        local hp = -1
        pcall(function()
            hp = Game.GetStatPoolsSystem():GetStatPoolValue(ent:GetEntityID(), gamedataStatPoolType.Health, false)
        end)
        if hp < 0 then return false end            -- couldn't read -> fail safe
        if hp <= 1.0 then hp = hp * 100 end        -- normalize a 0-1 build to a 0-100 percent
        return hp > 0 and hp < (rule.below or 50)
    end

    -- ------------------------------------------------------------------------
    -- DISPATCH — the machine calls this. Unknown condition = false + logged once.
    -- ------------------------------------------------------------------------
    function CC.evalCondition(rule, rt, ctx)
        local kind = rule.when or rule.condition
        local fn = kind and CC.conditions[kind]
        if not fn then
            CC.logOnce("cond:" .. tostring(kind), "unknown condition '" .. tostring(kind) .. "'")
            return false
        end
        return fn(rule, rt, ctx)
    end

end
