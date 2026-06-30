-- ============================================================================
-- modules/actions.lua
-- The DO half of a rule. When the machine fires a rule, it runs each action in
-- the rule's action list through CC.runAction(). Each verb either does a game op
-- directly, or delegates to the module that owns that concern (barks -> gizmos,
-- objective/completion -> player, spawn -> spawn, patrol -> a future behavior
-- module). Delegated verbs auto-activate the moment their module attaches its
-- function — until then they just log once and no-op.
--
-- Action shape (from mission JSON):  { "do": "<verb>", target = "...", ... }
-- NOTE: "do" is a Lua keyword, so it's always read as action["do"].
--
-- SECOND-LOOK NOTES:
--   * The old EntityStartAttitudes bookkeeping is GONE. It only existed to fight
--     an old per-tick attitude re-applier we aren't carrying forward, so
--     set_attitude is just "set the attitude" again.
--   * AI move/follow/stop are real helpers here (CC.aiMoveTo/aiFollow/aiStop).
--     Actions AND the dev hotkeys call these — one definition, not two copies.
--   * Doors go through the quest pipeline (QuestForceOpen/...), which the old
--     notes confirm works even on welded doors, instead of re-running the manual
--     SetNewDoorType/unseal/unlock/open sequence by hand.
--   * move_to resolves its destination via CC.labelPos (active mission + live
--     entities), which structurally fixes the old bug where it read the editor's
--     scratch blueprint and silently failed on wake-deployed missions.
-- ============================================================================

return function(CC)

    -- ========================================================================
    -- SHARED LOW-LEVEL HELPERS
    -- ========================================================================

    -- (attitude application moved to modules/spawn's tracked system, which
    -- re-asserts attitude every frame so the engine can't revert it — the
    -- attitude verbs below delegate to it.)

    -- Resolve a target spec to a list of live entities.
    --   a label            -> that one spawned entity
    --   "all_npcs"/"all"/"all_devices" -> everything we spawned (per-verb filters as needed)
    local function resolveTargets(spec)
        local out = {}
        if not spec then return out end
        if spec == "all" or spec == "all_npcs" or spec == "all_devices" then
            if CC.labelToEntityId then
                for label, _ in pairs(CC.labelToEntityId) do
                    local e = CC.entityByLabel(label)
                    if e then out[#out + 1] = e end
                end
            end
        else
            local e = CC.entityByLabel(spec)
            if e then out[#out + 1] = e end
        end
        return out
    end

    -- Queue a device PS event (get-PS / new / SetUp / SetExecutor / queue). Every
    -- failure mode is now LOGGED instead of swallowed, so an in-game test says
    -- exactly where it died. `tag` is the verb name, for readable log lines.
    local function queueDeviceEvent(ent, actionClass, tag)
        if not actionClass then
            CC.log("device " .. tostring(tag) .. ": action class is NIL (not a valid class in this build)")
            return false
        end
        local ok, err = pcall(function()
            local ps = ent:GetDevicePS()
            if not ps then
                local cls = "?"; pcall(function() cls = tostring(ent:GetClassName()) end)
                error("target has no DevicePS (" .. cls .. ")", 0)
            end
            local a = actionClass.new()
            a:SetUp(ps)
            a:SetExecutor(Game.GetPlayer())
            Game.GetPersistencySystem():QueuePSDeviceEvent(a)
        end)
        if ok then CC.log("device " .. tostring(tag) .. ": queued")
        else        CC.log("device " .. tostring(tag) .. ": FAILED - " .. tostring(err)) end
        return ok
    end

    -- Apply a device PS event to every entity a target spec resolves to.
    local function deviceEventOnTargets(spec, actionClass, tag)
        local targets = resolveTargets(spec)
        if #targets == 0 then
            CC.log("device " .. tostring(tag) .. ": no target for '" .. tostring(spec) ..
                   "' (world door not bound/resolved at deploy?)")
            return
        end
        for _, ent in ipairs(targets) do queueDeviceEvent(ent, actionClass, tag) end
    end

    -- ========================================================================
    -- AI COMMAND HELPERS  (single source — hotkeys call these too)
    -- ========================================================================

    function CC.aiMoveTo(ent, pos, run, force)
        if not ent or not pos then return end
        if CC.moveDebug then
            local np = CC.worldPos(ent)
            local d  = np and math.sqrt((np.x-pos.x)^2 + (np.y-pos.y)^2 + (np.z-pos.z)^2) or -1
            CC.log(string.format("[aiMoveTo] dest=(%.1f,%.1f,%.1f) npc=(%.1f,%.1f,%.1f) dist=%.1fm",
                pos.x, pos.y, pos.z, np and np.x or 0, np and np.y or 0, np and np.z or 0, d))
        end
        local outCmd
        pcall(function()
            local cmd  = AIMoveToCommand.new()
            local spec = AIPositionSpec.new()
            local wp   = WorldPosition.new()
            WorldPosition.SetVector4(wp, CC.vec4(pos.x, pos.y, pos.z))
            AIPositionSpec.SetWorldPosition(spec, wp)
            cmd.movementTarget  = spec
            cmd.movementType    = run and moveMovementType.Run or moveMovementType.Walk
            cmd.useStart        = true
            cmd.useStop         = true
            cmd.ignoreNavigation = false
            -- AMM's proven field set + approach distance (all guarded: fields vary by build)
            pcall(function() cmd.finishWhenDestinationReached    = true  end)
            pcall(function() cmd.rotateEntityTowardsFacingTarget = false end)
            pcall(function() cmd.desiredDistanceFromTarget       = 1.0   end)
            local ai = ent:GetAIControllerComponent()
            -- move_to only: clear the NPC's current (ambient) command so ours takes control
            if force then pcall(function() ai:CancelAllCommands() end) end
            ai:SendCommand(cmd)
            outCmd = cmd
        end)
        return outCmd      -- handle, so patrols can check if the move is still running
    end

    function CC.aiFollow(ent)
        if not ent then return end
        pcall(function()
            local cmd = AIFollowTargetCommand.new()
            cmd.target  = Game.GetPlayer()
            cmd.desiredDistance = 2.0
            cmd.tolerance       = 1.0
            cmd.lookAtTarget    = Game.GetPlayer()
            cmd.matchSpeed      = true
            cmd.stopWhenDestinationReached = false
            cmd.teleport        = false
            ent:GetAIControllerComponent():SendCommand(cmd)
        end)
    end

    function CC.aiStop(ent)
        if not ent then return end
        pcall(function() ent:GetAIControllerComponent():CancelAllCommands() end)
        -- a follow command is sticky and resumes after a bare cancel, so hand him
        -- a terminal "move to where you already are" — it completes at once and
        -- leaves nothing to resume.
        local p = CC.worldPos(ent)
        if p then CC.aiMoveTo(ent, p) end
    end

    -- Small delegate helper for verbs owned by other modules.
    local function delegate(fnName, action)
        if CC[fnName] then return CC[fnName](action) end
        CC.dbg("action '" .. tostring(action and action["do"]) .. "' -> " .. fnName .. " not available yet")
    end

    -- ========================================================================
    -- THE VERBS
    -- ========================================================================
    CC.actions = {}

    -- ----- flags / chaining (the bus) ---------------------------------------

    -- Set a flag. The KEY is whatever you name it:
    --   a machine's label        -> that machine's STAGE  (e.g. flag "Jacksmith" = its stage)
    --   "alarm", "combat", etc.  -> a global flag
    --   "label.sub"              -> extra per-machine sub-state
    -- (target= is accepted as the key when no flag/key is given, so
    --  { do="set_flag", target="Jacksmith", value=1 } sets Jacksmith's stage.)
    -- CC.setFlag lives in modules/machine (write-after-tick buffer); resolved at call time.
    CC.actions.set_flag = function(action, ctx)
        local key = action.flag or action.key or action.target
        if not key then return end
        local op = action.op or "set"
        if op == "add" then
            if CC.modifyFlag then CC.modifyFlag(key, action.value) end
        elseif op == "sub" then
            if CC.modifyFlag then CC.modifyFlag(key, -(tonumber(action.value) or 0)) end
        elseif op == "random" then
            -- roll an integer in [min,max] into the flag. This is the seed of a
            -- random mission: set it in Setup, then branch on it with flag rules.
            local lo = tonumber(action.min) or 1
            local hi = tonumber(action.max) or lo
            if hi < lo then lo, hi = hi, lo end
            local r = CC.randInt and CC.randInt(lo, hi) or lo
            if CC.setFlag then CC.setFlag(key, r) end
            CC.log("set_flag: " .. tostring(key) .. " = random(" .. lo .. ".." .. hi .. ") -> " .. tostring(r))
        else
            if CC.setFlag then CC.setFlag(key, action.value) end
        end
    end

    -- Knock an object into a posture: cancels its running sequences (waits die),
    -- switches mode, re-arms that posture's rules. CC.setPosture lives in machine.
    CC.actions.set_posture = function(action, ctx)
        if CC.setPosture then CC.setPosture(action.target, action.posture) end
    end

    -- `wait` is not an instant verb — the machine's sequence runner intercepts it
    -- (parks the sequence). This entry exists so the dispatcher never logs it as
    -- unknown if one slips through outside a sequence.
    CC.actions.wait = function(action, ctx) end

    -- Fire another rule by id. Routed through the reserved trigger flag that
    -- conditions.triggered reads back. target = the rule id to trigger.
    CC.actions.trigger = function(action, ctx)
        if action.target and CC.setFlag then
            CC.setFlag(CC.trigKey(action.target), 1)
        end
    end

    -- ----- speech ------------------------------------------------------------

    -- Floating text over the target entity. gizmos owns the bark list + rendering.
    -- CC.addBark(label, text, durationSeconds); resolved at call time.
    CC.actions.speak = function(action, ctx)
        local text = action.text or action.bark or ""
        if CC.addBark then CC.addBark(action.target, text, action.duration or 6.0) end
    end

    -- ----- VFX ---------------------------------------------------------------

    -- Play / stop a named VFX on a target NPC via the effect-event system (the raw
    -- StartEffectEvent path -- confirmed on-NPC: fire, shock, etc.). Names come from
    -- the VFX catalog. Stop needs the same name Start used, since it is NOT a status
    -- effect (RemoveStatusEffect can't touch it). pcall'd by runAction.
    CC.actions.add_effect = function(action, ctx)
        local ent  = CC.entityByLabel(action.target)
        local name = action.fx or action.effect
        if not ent or not name or name == "" then return end
        GameObjectEffectHelper.StartEffectEvent(ent, CName.new(name))
    end

    CC.actions.remove_effect = function(action, ctx)
        local ent  = CC.entityByLabel(action.target)
        local name = action.fx or action.effect
        if not ent or not name or name == "" then return end
        GameObjectEffectHelper.StopEffectEvent(ent, CName.new(name))
    end

    -- World-space FX at a resolved point (zone center or NPC's live pos). The point
    -- is resolved ONCE here, so the effect pins to the spot and won't follow.
    CC.actions.play_fx = function(action, ctx)
        local pos = CC.labelPos(action.target)
        if pos and CC.playWorldFx then CC.playWorldFx(pos, action.fx) end
    end

    -- Explosion = world FX at the point + optional AoE damage over the same point.
    -- Drop radius/damage and it's just spectacle (== play_fx).
    CC.actions.explode = function(action, ctx)
        local pos = CC.labelPos(action.target)
        if not pos then return end
        if CC.playWorldFx then CC.playWorldFx(pos, action.fx) end
        local radius = tonumber(action.radius) or 0
        local dmg    = tonumber(action.damage) or 0
        if radius > 0 and dmg > 0 and CC.damageInRadius then
            local n = CC.damageInRadius(pos, radius, dmg)
            CC.log("explode '" .. tostring(action.target) .. "': hit " .. n .. " within " .. radius .. "m")
        end
    end

    -- Status effects (the ApplyStatusEffect path -- VFX + gameplay: fire, stun, etc.)
    CC.actions.apply_status = function(action, ctx)
        local ent = CC.entityByLabel(action.target)
        local rec = action.status or action.fx
        if not ent or not rec or rec == "" then return end
        Game.GetStatusEffectSystem():ApplyStatusEffect(ent:GetEntityID(), rec)
    end

    CC.actions.remove_status = function(action, ctx)
        local ent = CC.entityByLabel(action.target)
        local rec = action.status or action.fx
        if not ent or not rec or rec == "" then return end
        Game.GetStatusEffectSystem():RemoveStatusEffect(ent:GetEntityID(), rec)
    end

    -- Freeze / hide (and their inverses). Target-only; resolve to the spawned entity.
    CC.actions.freeze   = function(action, ctx) local e = CC.entityByLabel(action.target); if e then CC.freezeEntity(e, true)  end end
    CC.actions.unfreeze = function(action, ctx) local e = CC.entityByLabel(action.target); if e then CC.freezeEntity(e, false) end end
    CC.actions.hide     = function(action, ctx) local e = CC.entityByLabel(action.target); if e then CC.hideEntity(e, true)   end end
    CC.actions.unhide   = function(action, ctx) local e = CC.entityByLabel(action.target); if e then CC.hideEntity(e, false)  end end

    -- ----- attitude ----------------------------------------------------------

    -- Attitude verbs delegate to the tracked system in modules/spawn, which both
    -- applies the attitude now AND re-asserts it each frame so the engine can't
    -- quietly revert a spawned combat NPC back to hostile.
    CC.actions.set_attitude = function(action, ctx)
        -- attitude defaults to "hostile" to match the editor's shown default, so an
        -- action authored before the editor persisted it still does the right thing.
        if CC.setNpcAttitudeTracked then CC.setNpcAttitudeTracked(action.target, action.attitude or "hostile") end
    end

    CC.actions.aggro = function(action, ctx)
        if CC.setNpcAttitudeTracked then CC.setNpcAttitudeTracked(action.target, "hostile") end
    end

    CC.actions.friendly = function(action, ctx)
        if CC.setNpcAttitudeTracked then CC.setNpcAttitudeTracked(action.target, "friendly") end
    end

    -- ----- movement ----------------------------------------------------------

    -- Drop any pending arrival-facing for a label (a new move or a stop
    -- supersedes the old destination's facing).
    local function clearPendingFace(label)
        if not CC.pendingFaces then return end
        local keep = {}
        for _, f in ipairs(CC.pendingFaces) do
            if f.label ~= label then keep[#keep + 1] = f end
        end
        CC.pendingFaces = keep
    end

    CC.actions.move_to = function(action, ctx)
        local ent  = CC.entityByLabel(action.target)
        local dest = CC.labelPos(action.destination or action.to)
        if not ent or not dest then
            CC.dbg("move_to: missing " .. (ent and "destination" or "entity") ..
                   " (" .. tostring(action.target) .. " -> " .. tostring(action.destination) .. ")")
            return
        end
        if CC.moveDebug then
            local dl = action.destination or action.to
            local de = CC.entityByLabel(dl)
            CC.log(string.format("[move_to] '%s' -> dest=(%.1f,%.1f,%.1f) label='%s' viaEntity=%s%s",
                tostring(action.target), dest.x, dest.y, dest.z, tostring(dl), tostring(de ~= nil),
                de and (" CLASS=" .. tostring(de:GetClassName())) or " (authored coords)"))
        end
        CC.aiMoveTo(ent, dest, action.run, true)
        clearPendingFace(action.target)
        if action.face then
            -- arrive-facing: watcher turns him when he reaches the last ~1.2m
            CC.pendingFaces = CC.pendingFaces or {}
            CC.pendingFaces[#CC.pendingFaces + 1] = {
                label = action.target, at = action.face,
                dest = { x = dest.x, y = dest.y, z = dest.z },
                age = 0.0,
            }
        end
    end

    -- Arrival watcher: when a pending walker is within arriveRadius of his
    -- destination, apply the facing and drop the entry. 30s timeout (blocked
    -- paths, despawns). Driven by player's TickAlways.
    function CC.facePendingTick(dt)
        if not CC.pendingFaces or #CC.pendingFaces == 0 then return end
        local keep = {}
        for _, f in ipairs(CC.pendingFaces) do
            local done = false
            local ent = CC.entityByLabel(f.label)
            if ent then
                local p = CC.worldPos(ent)
                if p and CC.withinRange(p, f.dest, 1.2) then
                    if CC.faceToward then CC.faceToward(f.label, f.at) end
                    done = true
                end
            else
                done = true                       -- despawned; drop
            end
            if not done then
                f.age = f.age + (dt or 0)
                if f.age < 30.0 then keep[#keep + 1] = f end
            end
        end
        CC.pendingFaces = keep
    end

    -- Turn in place to face a label or V. target = who turns, at = what to face.
    CC.actions.face = function(action, ctx)
        if CC.faceToward then CC.faceToward(action.target, action.at) end   -- native smooth rotate
    end

    -- Hold position: pin an NPC in place for a duration (AMM's Util:HoldPosition).
    -- After the duration it resumes prior behavior, so use a long value to "stay put".
    function CC.holdPosition(ent, duration)
        if not ent then return end
        pcall(function()
            local cmd = AIHoldPositionCommand.new()
            cmd.duration          = duration or 8.0
            cmd.ignoreInCombat    = false
            cmd.removeAfterCombat = false
            cmd.alwaysUseStealth  = false
            ent:GetAIControllerComponent():SendCommand(cmd)
        end)
    end
    CC.actions.hold = function(action, ctx)
        local e = CC.entityByLabel(action.target)
        if e then CC.holdPosition(e, tonumber(action.duration)) end
    end

    -- ---- combat / look / follow / weapon / immortal (ported from AMM's Util) -----

    -- Actually START a fight. Attitude alone leaves NPCs willing-but-idle; the fix is
    -- a reaction preset + TriggerCombat on BOTH sides (AMM's Util:TriggerCombatAgainst).
    -- We deliberately do NOT drag the player in, so NPC-vs-NPC stays between them.
    function CC.triggerCombat(handle, target)
        if not handle or not target then return end
        pcall(function() handle:GetAttitudeAgent():SetAttitudeTowards(target:GetAttitudeAgent(), EAIAttitude.AIA_Hostile) end)
        pcall(function() target:GetAttitudeAgent():SetAttitudeTowards(handle:GetAttitudeAgent(), EAIAttitude.AIA_Hostile) end)
        pcall(function()
            local preset = TweakDBInterface.GetReactionPresetRecord(TweakDBID.new("ReactionPresets.Ganger_Aggressive"))
            if handle.reactionComponent then handle.reactionComponent:SetReactionPreset(preset) end
            if target.reactionComponent then target.reactionComponent:SetReactionPreset(preset) end
        end)
        pcall(function() if handle.reactionComponent then handle.reactionComponent:TriggerCombat(target) end end)
        pcall(function() if target.reactionComponent then target.reactionComponent:TriggerCombat(handle) end end)
    end

    -- Follow an arbitrary entity at a distance (AMM's Util:FollowTarget). Distinct from
    -- CC.aiFollow, which is hardwired to the player for the follow_player verb.
    function CC.followTarget(ent, target, run)
        if not ent or not target then return end
        pcall(function()
            local cmd = AIFollowTargetCommand.new()
            cmd.desiredDistance = 2.0
            cmd.matchSpeed      = true
            cmd.stopWhenDestinationReached = false
            cmd.target          = target
            cmd.movementType    = run and "Run" or "Walk"
            cmd.teleport        = false
            cmd.tolerance       = 2.0
            cmd.lookAtTarget    = target
            ent:GetAIControllerComponent():SendCommand(cmd)
        end)
    end

    -- Unholster primary weapon (AMM's Util:EquipPrimaryWeaponCommand).
    function CC.drawWeapon(ent)
        if not ent then return end
        pcall(function()
            local cmd = AISwitchToPrimaryWeaponCommand.new()
            cmd.unEquip = false
            ent:GetAIControllerComponent():SendCommand(cmd)
        end)
    end

    -- Immortal / mortal toggle via the god-mode system (AMM's Util:SetGodMode).
    function CC.setImmortal(ent, immortal)
        if not ent then return end
        pcall(function()
            local id = ent:GetEntityID()
            local gs = Game.GetGodModeSystem()
            gs:ClearGodMode(id, CName.new("Default"))
            gs:AddGodMode(id, immortal and gameGodModeType.Immortal or gameGodModeType.Mortal, CName.new("Default"))
        end)
    end

    -- Make an NPC look at a target. Tries the stim-reaction upper-body look first
    -- (AMM's NPCTalk path -- turns head + torso), then falls back to a LookAtAddEvent.
    -- Returns which path took ("stim" / "event" / "none") so the test hotkey can report.
    function CC.npcLookAt(ent, target)
        if not ent then return "no-ent" end
        target = target or Game.GetPlayer()
        local via = "none"
        -- Primary: StimReactionComponent upper-body look (the reliable one in AMM).
        pcall(function()
            local stim = ent:GetStimReactionComponent()
            if stim then
                stim:ActivateReactionLookAt(target, false, 1, true, true)   -- upperBody = true
                via = "stim"
            end
        end)
        if via == "stim" then return via end
        -- Fallback: queue a head-targeted LookAtAddEvent directly.
        pcall(function()
            local stim = ent:FindComponentByName("ReactionManager")
            if not stim then return end
            stim:DeactiveLookAt()
            local ev = LookAtAddEvent.new()
            ev:SetEntityTarget(target, "pla_default_tgt", Vector4.new(0, 0, 0, 0))
            ev:SetStyle(animLookAtStyle.Normal)
            ev.request.limits.softLimitDegrees  = 360.0
            ev.request.limits.hardLimitDegrees  = 270.0
            ev.request.limits.hardLimitDistance = 1000000.0
            ev.request.limits.backLimitDegrees  = 210.0
            ev.request.calculatePositionInParentSpace = true
            ev.bodyPart = "Head"
            ent:QueueEvent(ev)
            stim.lookatEvent = ev
            via = "event"
        end)
        return via
    end

    -- Is a previously-sent command still running? (AMM's CheckIfCommandIsActive)
    function CC.commandActive(ent, cmd)
        if not ent or not cmd then return false end
        local ok, res = pcall(function()
            return AIActiveCommandList.IsActionCommandById(ent:GetAIControllerComponent().activeCommands, cmd.id)
        end)
        return ok and res or false
    end

    local function resolveAt(at)   -- "at" field: player sentinel, else a label
        if at == nil or at == "V" or at == "player" then return Game.GetPlayer() end
        return CC.entityByLabel(at)
    end

    CC.actions.attack = function(action, ctx)
        local ent = CC.entityByLabel(action.target)
        local tgt = resolveAt(action.at)
        if ent and tgt then CC.triggerCombat(ent, tgt) end
    end
    CC.actions.look_at = function(action, ctx)
        local ent = CC.entityByLabel(action.target)
        if ent then CC.npcLookAt(ent, resolveAt(action.at)) end
    end

    -- Clear a persistent look (the DeactiveLookAt half of npcLookAt) -- head/eyes
    -- return to default. Same dual-path component lookup as npcLookAt.
    function CC.stopLookAt(ent)
        if not ent then return "no-ent" end
        local via = "none"
        pcall(function()
            local stim = ent:GetStimReactionComponent()
            if stim then stim:DeactiveLookAt(); via = "stim" end
        end)
        if via == "stim" then return via end
        pcall(function()
            local stim = ent:FindComponentByName("ReactionManager")
            if stim then stim:DeactiveLookAt(); via = "event" end
        end)
        return via
    end
    CC.actions.stop_look = function(action, ctx)
        local e = CC.entityByLabel(action.target)
        if e then CC.stopLookAt(e) end
    end
    CC.actions.follow = function(action, ctx)
        local ent = CC.entityByLabel(action.target)
        local tgt = resolveAt(action.at)
        if ent and tgt then CC.followTarget(ent, tgt, action.run) end
    end
    CC.actions.draw_weapon = function(action, ctx)
        local e = CC.entityByLabel(action.target)
        if e then CC.drawWeapon(e) end
    end
    CC.actions.set_immortal = function(action, ctx)
        local e = CC.entityByLabel(action.target)
        if e then CC.setImmortal(e, action.immortal ~= false) end
    end

    CC.actions.follow_player = function(action, ctx)
        CC.aiFollow(CC.entityByLabel(action.target))
    end

    CC.actions.stop_move = function(action, ctx)
        CC.aiStop(CC.entityByLabel(action.target))
        clearPendingFace(action.target)
        if CC.stopPatrol then CC.stopPatrol(action.target) end
    end

    -- ----- world / devices ---------------------------------------------------

    CC.actions.dispose = function(action, ctx)
        local ent = CC.entityByLabel(action.target)
        if ent then pcall(function() ent:Dispose() end) end
    end
    CC.actions.destroy = CC.actions.dispose  -- alias (old name)

    -- Doors via the quest pipeline (works on welded doors).
    CC.actions.open         = function(action) deviceEventOnTargets(action.target, QuestForceOpen,   "open")   end
    CC.actions.lock         = function(action) deviceEventOnTargets(action.target, QuestForceLock,   "lock")   end
    CC.actions.unlock       = function(action) deviceEventOnTargets(action.target, QuestForceUnlock, "unlock") end
    CC.actions.quest_open   = CC.actions.open
    CC.actions.quest_close  = function(action) deviceEventOnTargets(action.target, QuestForceClose,  "close")  end
    CC.actions.quest_lock   = CC.actions.lock
    CC.actions.quest_unlock = CC.actions.unlock

    -- Power devices on/off.
    CC.actions.enable  = function(action) deviceEventOnTargets(action.target, ToggleON,  "enable")  end
    CC.actions.disable = function(action) deviceEventOnTargets(action.target, ToggleOFF, "disable") end

    -- ----- delegated to owning modules (forward-compatible stubs) ------------
    -- These work automatically once the named module attaches its function.

    CC.actions.spawn         = function(action, ctx) delegate("spawnRecord",    action) end  -- modules/spawn
    CC.actions.set_objective = function(action, ctx) delegate("setObjective",   action) end  -- modules/player
    CC.actions.complete      = function(action, ctx) delegate("completeMission",action) end  -- modules/player
    CC.actions.fail          = function(action, ctx) delegate("failMission",    action) end  -- modules/player
    CC.actions.choice        = function(action, ctx) delegate("showChoice",     action) end  -- player + interactionUI
    CC.actions.set_patrol    = function(action, ctx) delegate("setPatrol",      action) end  -- future behavior module
    CC.actions.return_to_post= function(action, ctx) delegate("returnToPost",   action) end  -- future behavior module

    -- ----- FUTURE IDEAS (no home yet — uncomment + implement when we get there)
    -- CC.actions.device_friendly = function(action) ... end  -- camera/turret treats player as friendly
    -- CC.actions.device_hostile  = function(action) ... end
    -- CC.actions.play_sound      = function(action) ... end  -- one-shot SFX/vo
    -- CC.actions.camera          = function(action) ... end  -- cinematic framing on a beat
    -- CC.actions.wait            = function(action) ... end  -- explicit pause node, if delay-on-rule isn't enough
    -- CC.actions.give_item       = function(action) ... end  -- hand the player an item as a reward beat

    -- ========================================================================
    -- DISPATCH — the machine calls this once per action in a firing rule.
    -- Fails soft: an unknown or broken verb logs once and the mission keeps running.
    -- ========================================================================
    function CC.runAction(action, ctx)
        local kind = action["do"] or action.action
        local fn = kind and CC.actions[kind]
        if not fn then
            CC.logOnce("act:" .. tostring(kind), "unknown action '" .. tostring(kind) .. "'")
            return
        end
        local ok, err = pcall(fn, action, ctx)
        if not ok then
            CC.logOnce("acterr:" .. tostring(kind), "action '" .. tostring(kind) .. "' error — " .. tostring(err))
        end
    end

end
