-- ============================================================================
-- modules/player.lua
-- The mission orchestrator. Everything that turns a mission DEFINITION into a
-- running, completable mission lives here. It also provides the functions that
-- actions delegate to (setObjective, completeMission, failMission, showChoice).
--
-- Deploy sequence (the spine):
--   abort anything running -> set activeMission -> scan def for target/friendlies
--   -> resolve objective -> spawn entities (spawn module) -> armMachines()
--   -> mode="play" -> ring the fixer.
--
-- Spawn/despawn are DELEGATED to modules/spawn; they no-op (with a dbg line)
-- until that module attaches CC.spawnMissionEntities / CC.despawnAll.
--
-- FLAGGED-FOR-VERIFY (written best-effort, confirm in-game):
--   * awardRewards XP call           (the exact XP API shifts across patches)
--   * pushFixerCall                  (needs MLPhoneSystem + PhoneExtension mods)
--   * showChoice confirm -> callback (interactionUI extract needs confirm wiring)
-- ============================================================================

return function(CC)

    -- ========================================================================
    -- SMALL HELPERS
    -- ========================================================================

    local function isDead(ent)
        if not ent then return nil end
        local dead = false
        pcall(function() dead = ent:IsDead() end)
        return dead
    end

    -- Transient on-screen status (shown by DrawObjectiveHUD) + console line.
    function CC.notify(msg)
        CC.statusMessage = tostring(msg)
        CC.log(msg)
    end

    -- Give the player money / XP.  VERIFY-IN-GAME: both calls are best-effort.
    function CC.awardRewards(money, xp)
        if money and money > 0 then
            pcall(function() Game.AddToInventory("Items.money", money) end)
        end
        if xp and xp > 0 then
            pcall(function() Game.AddExp("Level", xp) end)   -- confirm the XP API
        end
    end

    -- ========================================================================
    -- FIXER CALL  (ported; depends on the MLPhoneSystem + PhoneExtension mods —
    -- falls back to an on-screen notify if they aren't installed)
    -- ========================================================================
    function CC.pushFixerCall(mission)
        pcall(function()
            local fixer = mission.fixer or "Fixer"
            local title = mission.title or "New Job"
            local messages = mission.call_messages
            if not messages or #messages == 0 then
                local b = mission.briefing
                messages = { (b and b ~= "") and b or "Got work for you." }
            end

            local mlPhone = Game.GetScriptableSystemsContainer():Get(CName.new("MLPhoneSystem"))
            if not mlPhone then
                CC.notify(fixer .. ": " .. title)
                return
            end
            mlPhone:EnsureRegistered()
            local contact = mlPhone:GetContact()
            contact:SetFixerName(fixer)
            contact:SetPreview(title)
            contact:SetAvatar(fixer)
            contact:ClearLines()
            for _, line in ipairs(messages) do contact:AddLine(line) end

            local phoneExt = Game.GetScriptableSystemsContainer():Get(CName.new("PhoneExtension.System.PhoneExtensionSystem"))
            if phoneExt then phoneExt:NotifyNewMessageCustom(77770001, fixer, title) end
        end)
    end

    -- ========================================================================
    -- DEPLOY / ABORT
    -- ========================================================================

    -- Tear the current mission down: despawn everything, wipe run state, go idle.
    function CC.abortMission()
        if CC.despawnAll then CC.despawnAll() end   -- spawn module
        CC.ResetRunState()
        CC.rules = {}                               -- drop runtime rule instances
        CC.activeMission = nil
        CC.statusMessage = nil
        CC.mode = "idle"
    end

    -- Deploy a mission DEFINITION. This is the master sequence.
    function CC.deployMission(mission)
        if not mission then return end

        CC.abortMission()                 -- clean slate first
        CC.activeMission = mission

        -- player-owned per-deploy fields (not part of ResetRunState)
        CC.targetLabel     = nil
        CC.targetSeenAlive = false
        CC.friendlyLabels  = {}
        CC.sawAnyEntity    = false
        CC.lifecycleHasWin = false   -- set true by armMachines when win groups exist

        -- scan the definition for the kill target and any friendlies
        for _, e in ipairs(mission.entities or {}) do
            if e.is_target or e.action == "target" then CC.targetLabel = e.label end
            if (e.action == "friendly" or e.startAttitude == "friendly") and e.label then
                CC.friendlyLabels[e.label] = true
            end
        end

        -- resolve the starting objective from the definition
        if mission.objective then
            local o = mission.objective
            CC.objective = {
                type = o.type, display = o.display,
                x = o.x, y = o.y, z = o.z, radius = o.radius, duration = o.duration,
            }
        end
        CC.objectiveDone = false

        -- spawn (fills CC.labelToEntityId) then arm the machine (needs that map)
        if CC.spawnMissionEntities then CC.spawnMissionEntities()
        else CC.dbg("deploy: spawn module not loaded — no entities spawned") end

        if CC.armMachines then CC.armMachines()
        else CC.dbg("deploy: machine not loaded — rules won't run") end

        CC.mode = "play"
        CC.pushFixerCall(mission)
        CC.log("deployed: " .. (mission.title or mission.mission_id or "?"))
    end

    -- Pick a random mission from the pool and deploy it (used by the wake cycle).
    function CC.deployFromPool()
        if not CC.missionPool or #CC.missionPool == 0 then
            CC.dbg("deployFromPool: pool empty")
            return
        end
        CC.deployMission(CC.pick(CC.missionPool))
    end

    -- ========================================================================
    -- COMPLETION
    -- ========================================================================

    -- Run the lifecycle Finally (exit) actions just before reward + teardown.
    -- quest@outcome is written live first so the actions (and inspector) can see
    -- it. Pass-2 v1: Finally is instant — a `wait` here is ignored (no sequence
    -- survives teardown).
    local function runFinally(outcome)
        local lc = CC.activeMission and CC.activeMission.lifecycle
        local acts = lc and lc.finally and lc.finally.actions
        if not acts or #acts == 0 then return end
        if CC.flags then CC.flags["quest@outcome"] = outcome end
        local ctx = { clock = CC.deployClock or 0 }
        pcall(function() ctx.playerPos = Game.GetPlayer():GetWorldPosition() end)
        for _, a in ipairs(acts) do
            if (a["do"] or a.action) ~= "wait" then CC.runAction(a, ctx) end
        end
    end

    function CC.completeMission()
        local m = CC.activeMission
        if not m or CC.objectiveDone then return end
        CC.objectiveDone = true
        runFinally("win")
        CC.awardRewards(m.reward_money, m.reward_xp)
        CC.notify((m.title or "Mission") .. " — COMPLETE")
        CC.log("mission complete: " .. (m.title or "?"))
        CC.abortMission()
    end

    function CC.failMission()
        local m = CC.activeMission
        if not m then return end
        runFinally("lose")
        CC.notify((m.title or "Mission") .. " — FAILED")
        CC.log("mission failed: " .. (m.title or "?"))
        CC.abortMission()
    end

    -- ========================================================================
    -- OBJECTIVES
    -- ========================================================================

    -- A rule can swap the objective mid-mission (this is multi-objective).
    function CC.setObjective(action)
        CC.objective = {
            type = action.type or "custom", display = action.display or action.text,
            x = action.x, y = action.y, z = action.z,
            radius = action.radius, duration = action.duration,
        }
        CC.objectiveDone = false
    end

    -- Checked every frame in PLAY mode (init.lua calls this).
    function CC.TickPlayer(dt)
        if not CC.activeMission or CC.objectiveDone then return end
        -- Lifecycle owns completion once WIN groups are defined; objective.type
        -- then only drives the HUD/waypoint. This legacy path stays as the
        -- FALLBACK for missions with no lifecycle win groups.
        if CC.lifecycleHasWin then return end
        local obj = CC.objective
        if not obj then return end

        if obj.type == "kill_target" then
            if not CC.targetLabel then return end
            local ent = CC.entityByLabel(CC.targetLabel)
            if ent then
                CC.targetSeenAlive = true
                if isDead(ent) then CC.completeMission() end
            elseif CC.targetSeenAlive then
                CC.completeMission()                       -- despawned after being alive
            end

        elseif obj.type == "kill_all" then
            if not CC.warmupDone then return end           -- let them spawn first
            local anyAlive = false
            for label, _ in pairs(CC.labelToEntityId) do
                if not CC.friendlyLabels[label] then
                    local ent = CC.entityByLabel(label)
                    if ent then
                        CC.sawAnyEntity = true
                        if not isDead(ent) then anyAlive = true end
                    end
                end
            end
            if CC.sawAnyEntity and not anyAlive then CC.completeMission() end

        elseif obj.type == "reach_location" then
            local pp = CC.worldPos(Game.GetPlayer())
            if pp then
                local target = CC.vec4(obj.x or 0, obj.y or 0, obj.z or 0)
                if CC.withinRange(pp, target, obj.radius or CC.config.defaultProximity) then
                    CC.completeMission()
                end
            end

        elseif obj.type == "survive" then
            if (CC.deployClock or 0) >= (obj.duration or 0) then CC.completeMission() end
        end
    end

    -- ========================================================================
    -- PLAYER CHOICE  (the new story primitive — wired to the interactionUI lib)
    -- VERIFY-IN-GAME: the lib captures the controller and shows the hub, but the
    -- "player confirmed selection -> run callback" path needs finishing in
    -- modules/interactionUI. Until then this shows the hub; selection won't fire.
    -- action.choices = { { label=.., flag=.., value=.., trigger=.. }, ... }
    -- ========================================================================
    function CC.showChoice(action)
        local lib = CC.interactionUI
        if not lib then CC.dbg("showChoice: interactionUI not loaded"); return end
        local choices = {}
        lib.clearCallbacks()
        for i, c in ipairs(action.choices or {}) do
            choices[#choices + 1] = lib.createChoice(c.label or ("Option " .. i))
            lib.registerChoiceCallback(i - 1, function()
                if c.flag and CC.setFlag then CC.setFlag(c.flag, c.value or 1) end
                if c.trigger and CC.setFlag then CC.setFlag(CC.trigKey(c.trigger), 1) end
                lib.hideHub()
            end)
        end
        lib.setHub(lib.createHub(action.title or "Choose", choices))
        lib.showHub()
    end

    -- ========================================================================
    -- WAKE CYCLE  (sleep -> a job auto-deploys)
    -- ========================================================================
    local function checkForWake()
        local ts = Game.GetTimeSystem()
        if not ts then return end
        local ok, t = pcall(function() return ts:GetGameTimeStamp() end)
        if not ok or not t then return end

        if not CC.wakeReady then
            CC.lastGameTime = t
            CC.wakeReady = true
            return
        end
        local diff = t - CC.lastGameTime
        CC.lastGameTime = t
        if diff > (CC.config.wakeJumpSeconds or 3600) and CC.mode == "idle" then
            CC.log("wake detected (" .. math.floor(diff) .. "s) — deploying a job")
            CC.deployFromPool()
        end
    end

    -- Runs every frame in EVERY mode (init.lua calls this).
    -- ========================================================================
    -- EDITOR FLYCAM (fly + noclip)  -- ported from the freefly mod's approach.
    -- We hook the game's OWN movement actions (no new keybinds), then Teleport V
    -- each frame. A teleport has no collision sweep, so it passes through walls
    -- AND holds V aloft (no gravity between frames) -- fly and noclip from one
    -- mechanism. NoMovement/NoZooming restrictions stop normal locomotion from
    -- fighting the teleport; Health is pinned so clipping never deals damage.
    -- Toggled from the Quest Hub. WASD = move, Space = up, Sprint = down.
    -- ========================================================================
    CC.fly = CC.fly or { active = false, speed = 1.0, lockVertical = false,
                         f = 0, b = 0, r = 0, l = 0, u = 0, d = 0, yaw = 0, hooked = false }

    local function flyStatus(rec, on)
        pcall(function()
            local ses = Game.GetStatusEffectSystem()
            local id  = Game.GetPlayer():GetEntityID()
            if on then ses:ApplyStatusEffect(id, rec) else ses:RemoveStatusEffect(id, rec) end
        end)
    end

    local function flyStep(dir, pos, speed)
        local f = CC.fly
        local amt = speed * ((dir == "f" and f.f) or (dir == "b" and f.b) or (dir == "r" and f.r)
                          or (dir == "l" and f.l) or (dir == "u" and f.u) or (dir == "d" and f.d) or 0)
        if amt == 0 then return pos end
        local cam = Game.GetCameraSystem()
        if dir == "f" or dir == "b" then
            local v = f.lockVertical and Game.GetPlayer():GetWorldForward() or cam:GetActiveCameraForward()
            local s = (dir == "f") and amt or -amt
            pos.x, pos.y, pos.z = pos.x + v.x * s, pos.y + v.y * s, pos.z + v.z * s
        elseif dir == "r" or dir == "l" then
            local v = cam:GetActiveCameraRight()
            local s = (dir == "r") and amt or -amt
            pos.x, pos.y, pos.z = pos.x + v.x * s, pos.y + v.y * s, pos.z + v.z * s
        elseif dir == "u" then pos.z = pos.z + 0.7 * amt
        elseif dir == "d" then pos.z = pos.z - 0.7 * amt end
        return pos
    end

    -- Read the game's movement actions into the analog flags. Registered once;
    -- gated on CC.fly.active so it does nothing (and costs nothing) when not flying.
    local function flyHookInput()
        if CC.fly.hooked then return end
        CC.fly.hooked = true
        Observe('PlayerPuppet', 'OnGameAttached', function(this)
            pcall(function()
                for _, a in ipairs({ 'Forward', 'Back', 'Right', 'Left', 'Jump', 'ToggleSprint' }) do
                    this:UnregisterInputListener(this, a); this:RegisterInputListener(this, a)
                end
            end)
        end)
        Observe('PlayerPuppet', 'OnAction', function(_, action)
            if not CC.fly.active then return end
            pcall(function()
                local name  = Game.NameToString(action:GetName(action))
                local atype = action:GetType(action).value
                local val   = action:GetValue(action)
                local function btn(cur) return (atype == 'BUTTON_PRESSED') and 1 or (atype == 'BUTTON_RELEASED') and 0 or cur end
                if     name == 'MoveX' then CC.fly.r = val > 0 and val or 0; CC.fly.l = val < 0 and -val or 0
                elseif name == 'MoveY' then CC.fly.f = val > 0 and val or 0; CC.fly.b = val < 0 and -val or 0
                elseif name == 'Forward'      then CC.fly.f = btn(CC.fly.f)
                elseif name == 'Back'         then CC.fly.b = btn(CC.fly.b)
                elseif name == 'Right'        then CC.fly.r = btn(CC.fly.r)
                elseif name == 'Left'         then CC.fly.l = btn(CC.fly.l)
                elseif name == 'ToggleSprint' then CC.fly.d = btn(CC.fly.d)
                elseif name == 'Jump' then
                    CC.fly.u = (atype == 'BUTTON_PRESSED' or atype == 'BUTTON_HOLD_COMPLETE') and 1
                               or (atype == 'BUTTON_RELEASED') and 0 or CC.fly.u
                elseif name == 'CameraMouseX' then
                    local sens = 1.0
                    pcall(function() sens = Game.GetSettingsSystem():GetVar("/controls/fppcameramouse", "FPP_MouseX"):GetValue() / 2.9 end)
                    CC.fly.yaw = -(val / 35) * sens
                end
            end)
        end)
    end

    function CC.toggleFly(state)
        CC.fly.active = state and true or false
        if CC.fly.active then
            pcall(function()   -- register listeners now too, in case OnGameAttached already fired
                local p = Game.GetPlayer()
                for _, a in ipairs({ 'Forward', 'Back', 'Right', 'Left', 'Jump', 'ToggleSprint' }) do
                    p:UnregisterInputListener(p, a); p:RegisterInputListener(p, a)
                end
            end)
        else
            CC.fly.f, CC.fly.b, CC.fly.r, CC.fly.l, CC.fly.u, CC.fly.d, CC.fly.yaw = 0, 0, 0, 0, 0, 0, 0
        end
        flyStatus("GameplayRestriction.NoMovement", CC.fly.active)
        flyStatus("GameplayRestriction.NoZooming",  CC.fly.active)
        CC.log("flycam " .. (CC.fly.active and "ON (WASD move, Space up, Sprint down, mouse to steer)" or "off"))
    end

    function CC.tickFly(dt)
        if not CC.fly.active then return end
        pcall(function()
            local player = Game.GetPlayer()
            if not player or player:GetMountedVehicle() then return end
            local pos   = player:GetWorldPosition()
            local speed = (CC.fly.speed or 1.0) * dt * 15
            for _, dir in ipairs({ "f", "b", "r", "l", "u", "d" }) do pos = flyStep(dir, pos, speed) end
            Game.GetTeleportationFacility():Teleport(player, pos,
                EulerAngles.new(0, 0, player:GetWorldYaw() + CC.fly.yaw))
            Game.GetStatPoolsSystem():RequestSettingStatPoolValue(player:GetEntityID(),
                gamedataStatPoolType.Health, 100, nil)
        end)
    end

    flyHookInput()                                              -- register observers once
    flyStatus("GameplayRestriction.NoMovement", false)         -- clear any restriction left by a reload
    flyStatus("GameplayRestriction.NoZooming",  false)

    function CC.TickAlways(dt)
        checkForWake()
        if CC.spawnFixupTick   then CC.spawnFixupTick(dt)   end   -- fix facing on materialization
        if CC.maintainAttitudes then CC.maintainAttitudes(dt) end -- hold spawned NPCs at their set attitude
        if CC.tickPatrols      then CC.tickPatrols(dt)      end   -- walk active patrols
        if CC.tickFactionTest  then CC.tickFactionTest(dt)  end   -- faction-fight harness deferred wire
        if CC.tickFly          then CC.tickFly(dt)          end   -- editor flycam (fly + noclip)
    end

    -- ========================================================================
    -- HUD  (minimal play-mode objective readout; drawn every frame in PLAY mode)
    -- ========================================================================
    function CC.DrawObjectiveHUD()
        if not CC.activeMission then return end
        pcall(function()
            ImGui.SetNextWindowPos(24, 220, ImGuiCond.FirstUseEver)
            ImGui.Begin("##cc_objective", bit32.bor(
                ImGuiWindowFlags.NoTitleBar,
                ImGuiWindowFlags.AlwaysAutoResize,
                ImGuiWindowFlags.NoInputs,
                ImGuiWindowFlags.NoNav,
                ImGuiWindowFlags.NoFocusOnAppearing
            ))
            ImGui.TextColored(0.0, 1.0, 1.0, 1.0, CC.activeMission.title or "Mission")
            local obj = CC.objective
            if obj then
                ImGui.Text(obj.display or obj.type or "Objective")
                if obj.type == "survive" and obj.duration then
                    local left = math.max(0, obj.duration - (CC.deployClock or 0))
                    ImGui.TextColored(1.0, 0.4, 0.4, 1.0, string.format("Survive: %.0fs", left))
                end
            end
            if CC.statusMessage then
                ImGui.TextColored(1.0, 0.85, 0.2, 1.0, CC.statusMessage)
            end
            ImGui.End()
        end)
    end

    -- ========================================================================
    -- LIFECYCLE
    -- ========================================================================

    -- Game-ready setup (init.lua onInit -> CC.Init).
    function CC.Init()
        if CC.loadMissionPool then CC.loadMissionPool() end   -- filesystem module
        CC.wakeReady = false
        CC.log("player ready (pool: " .. (#(CC.missionPool or {})) .. ")")
    end

    -- Fired once each time a save finishes loading (init.lua).
    function CC.OnGameLoaded()
        if CC.mode == "play" then
            CC.log("save loaded mid-mission — resetting")
            CC.abortMission()
        end
        CC.wakeReady = false        -- re-baseline wake detection after a load
    end

end
