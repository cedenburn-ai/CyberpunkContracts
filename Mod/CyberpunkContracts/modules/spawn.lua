-- ============================================================================
-- modules/spawn.lua
-- Puts entities in the world, takes them out, and KEEPS THEM at their intended
-- attitude. Player deploy delegates here (CC.spawnMissionEntities), abort here
-- (CC.despawnAll), the runtime spawn verb here (CC.spawnRecord), and the attitude
-- verbs here (CC.setNpcAttitudeTracked). Everything we create is tracked so
-- cleanup is total.
--
-- IDENTITY: spawned entities are tracked by label -> EntityID (CC.labelToEntityId)
-- plus a flat cleanup list (CC.spawnedIds) — the reliable handle path, no hashes.
--
-- DEFERRED FIXUP: a fresh spawn isn't materialized yet, so we queue a one-time
-- fixup per spawn and apply it the first frame the entity resolves — re-teleport
-- to its facing, and register its initial attitude.
--
-- TRACKED ATTITUDE (the re-asserted kind): the engine quietly reverts a spawned
-- combat NPC back to hostile, so setting an attitude ONCE doesn't stick. We
-- remember each NPC's intended attitude (CC.npcAttitudes[label]) and re-assert it
-- every frame via CC.maintainAttitudes (driven by player's TickAlways). This is
-- the old AggroMissionSquad mechanism, rebuilt — it's what makes "neutral until
-- tripped" actually hold.
--
-- FLAGGED-FOR-VERIFY:
--   * DynamicEntitySpec fields + CreateEntity/DeleteEntity (standard CET).
--   * GetTeleportationFacility():Teleport(ent, Vector4, EulerAngles) for the fixup.
--   * AttitudeAgent:SetAttitudeTowards / enum names EAIAttitude.AIA_*.
-- ============================================================================

return function(CC)

    CC.npcAttitudes = CC.npcAttitudes or {}   -- label -> intended attitude string
    CC.spawnFixups  = CC.spawnFixups  or {}   -- pending materialization fixups
                                              -- (BUG FIX: was only created on deploy;
                                              -- editor preview spawns indexed nil and
                                              -- died silently inside the UI pcall)
    CC.npcGroups    = CC.npcGroups    or {}   -- label -> original (hostile) attitude group

    local _des, _tp
    local function dyn() if not _des then _des = Game.GetDynamicEntitySystem() end return _des end
    local function tp()  if not _tp  then _tp  = Game.GetTeleportationFacility() end return _tp  end

    local function attitudeEnum(name)
        if name == "hostile"  then return EAIAttitude.AIA_Hostile  end
        if name == "neutral"  then return EAIAttitude.AIA_Neutral  end
        if name == "friendly" then return EAIAttitude.AIA_Friendly end
        return nil
    end

    -- Apply an attitude to a materialized entity now. The GROUP is the real lever:
    -- a pairwise SetAttitudeTowards alone gets overridden by a hostile group (the
    -- old mod's hard-won lesson). neutral/friendly -> join the PLAYER's group so the
    -- engine stops treating you as an enemy; hostile -> restore the original group.
    local function applyAttitudeNow(ent, attName, label)
        if not ent then return end
        pcall(function()
            local agent  = ent:GetAttitudeAgent()
            local pagent = Game.GetPlayer():GetAttitudeAgent()
            -- remember the original (usually hostile) group the first time we touch it
            if label and CC.npcGroups[label] == nil then
                CC.npcGroups[label] = agent:GetAttitudeGroup()
            end
            if attName == "hostile" then
                local orig = label and CC.npcGroups[label]
                if orig then agent:SetAttitudeGroup(orig) end
                agent:SetAttitudeTowards(pagent, EAIAttitude.AIA_Hostile)
            else
                agent:SetAttitudeGroup(pagent:GetAttitudeGroup())   -- <-- the actual fix
                local att = (attName == "friendly") and EAIAttitude.AIA_Friendly or EAIAttitude.AIA_Neutral
                agent:SetAttitudeTowards(pagent, att)
            end
        end)
    end

    -- ========================================================================
    -- TRACKED ATTITUDE
    -- ========================================================================

    -- Set an NPC (or all_npcs/all) to an attitude AND remember it so the per-frame
    -- maintenance keeps re-asserting it. The attitude VERBS in actions delegate here.
    function CC.setNpcAttitudeTracked(spec, attName)
        if not spec or not attName then return end
        CC.log("attitude: " .. tostring(spec) .. " -> " .. tostring(attName))
        local function one(label)
            CC.npcAttitudes[label] = attName
            local ent = CC.entityByLabel(label)
            if ent then applyAttitudeNow(ent, attName, label) end
        end
        if spec == "all" or spec == "all_npcs" or spec == "all_devices" then
            for label, _ in pairs(CC.labelToEntityId) do one(label) end
        else
            one(spec)
        end
    end

    -- Re-assert tracked NPC attitudes as insurance. The group set generally holds
    -- (groups don't auto-revert like the pairwise attitude did), so once a second
    -- is plenty — the every-frame hammer was only needed back when we leaned on the
    -- pairwise attitude alone.
    local _attTimer = 0.0
    function CC.maintainAttitudes(dt)
        if not CC.npcAttitudes then return end
        _attTimer = _attTimer + (dt or 0)
        if _attTimer < 1.0 then return end
        _attTimer = 0.0
        for label, attName in pairs(CC.npcAttitudes) do
            local ent = CC.entityByLabel(label)
            if ent then applyAttitudeNow(ent, attName, label) end
        end
    end

    -- ========================================================================
    -- PATROL  (a real behavior: walk a node loop with ARRIVAL gating, so the next
    -- leg only fires once the NPC actually reaches the current one -- what
    -- set_patrol delegates to. One action instead of N arrival-gated rules. The
    -- per-frame ticker is driven by player's TickAlways.)
    -- ========================================================================
    CC.patrols = CC.patrols or {}   -- label -> { nodes, idx, loop, run, arrive, started, reissue }
    CC.moveDebug = true             -- diagnostic: log every move destination (toggle hotkey to silence)

    -- Start (or replace) a patrol. action.nodes = ordered waypoint labels (zones or
    -- any placed object). loop defaults true, run defaults false (walk).
    -- Arrival radius for a node: if the node is a zone, use ITS radius (or half the
    -- box's largest side) so "reached" means "inside the zone", not "within 2m of a
    -- point you may never navmesh onto". Falls back to the action's arrive default.
    local function patrolNodeRadius(label, default)
        if CC.activeMission and CC.activeMission.entities then
            for _, e in ipairs(CC.activeMission.entities) do
                if e.label == label and e.action == "zone" then
                    if e.shape == "box" then
                        local half = math.max(e.sx or 0, e.sy or 0) * 0.5   -- horizontal footprint only; height must not widen arrival
                        if half > 0 then return math.max(default, half + 0.5) end
                    elseif e.radius then
                        return math.max(default, e.radius + 0.5)
                    end
                end
            end
        end
        return default
    end

    function CC.setPatrol(action)
        if CC.patrolDebug == nil then CC.patrolDebug = false end  -- set CC.patrolDebug = true to log patrol steps
        local label = action and action.target
        local raw   = action and (action.nodes or action.path)
        if not label or type(raw) ~= "table" then
            CC.logOnce("patrol:" .. tostring(label), "set_patrol: needs a target and a nodes list")
            return
        end
        local nodes = {}
        for _, n in ipairs(raw) do
            if type(n) == "string" and n ~= "" then nodes[#nodes + 1] = n end
        end
        if #nodes == 0 then
            CC.logOnce("patrol:" .. tostring(label), "set_patrol: no valid nodes for " .. tostring(label))
            return
        end
        CC.patrols[label] = {
            nodes = nodes, idx = 1,
            loop = action.loop ~= false, run = action.run == true,
            arrive = tonumber(action.arrive) or 2.0, started = false, reissue = 0.0,
        }
        CC.log("patrol: " .. label .. " over " .. #nodes .. " node(s)")
        if CC.patrolDebug then
            -- Dump every node's RESOLVED position now -- this is the "junk coordinates?"
            -- check: if a node prints UNRESOLVED or a wild (x,y,z), that's the bug.
            for i, nl in ipairs(nodes) do
                local np = CC.labelPos(nl)
                if np then
                    CC.log(string.format("[patrol] node %d '%s' -> (%.2f, %.2f, %.2f)  arrive<=%.1f",
                        i, tostring(nl), np.x, np.y, np.z, math.max(patrolNodeRadius(nl, 2.0), 3.0)))
                else
                    CC.log("[patrol] node " .. i .. " '" .. tostring(nl) .. "' -> UNRESOLVED (nil) -- bad label / not deployed")
                end
            end
            local sp  = CC.entityByLabel(label)
            local spp = sp and CC.worldPos(sp)
            if spp then CC.log(string.format("[patrol] %s starts at (%.2f, %.2f, %.2f)", label, spp.x, spp.y, spp.z)) end
        end
    end

    function CC.stopPatrol(label)
        if label and CC.patrols then CC.patrols[label] = nil end
    end

    -- Advance every active patrol one frame: issue the first move, detect arrival
    -- at the current node, advance to the next (looping). Re-issues periodically so
    -- a move cleared by combat/knockback resumes once he is idle again.
    function CC.tickPatrols(dt)
        if not CC.patrols then return end
        for label, pt in pairs(CC.patrols) do
            local ent = CC.entityByLabel(label)
            if not ent then
                CC.patrols[label] = nil                       -- despawned: drop
            else
                local pos  = CC.worldPos(ent)
                local node = pt.nodes[pt.idx]
                local dest = node and CC.labelPos(node)
                if pos and node and not dest then
                    CC.logOnce("patrolnil:" .. label .. ":" .. tostring(node),
                        "[patrol] " .. label .. " node '" .. tostring(node) .. "' won't resolve -- check the label")
                end
                if pos and dest then
                    local arr = math.max(patrolNodeRadius(node, pt.arrive), 3.0)   -- patrol-waypoint floor
                    local dx, dy, dz = pos.x - dest.x, pos.y - dest.y, pos.z - dest.z
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if not pt.started then
                        pt.started, pt.reissue, pt.minDist, pt.legTime, pt.lastPos = true, 0.0, dist, 0.0, nil
                        -- (no teleport pre-orient: a snap-face halts the walk and stutters.
                        --  aiMoveTo orients toward the destination on its own.)
                        pt.cmd = CC.aiMoveTo(ent, dest, pt.run)
                        if CC.patrolDebug then
                            CC.log(string.format("[patrol] %s START -> '%s' (%.1f,%.1f,%.1f) arrive<=%.1f",
                                label, tostring(node), dest.x, dest.y, dest.z, arr))
                        end
                    else
                        pt.minDist = math.min(pt.minDist or dist, dist)   -- closest approach (now tracks correctly)
                        pt.legTime = (pt.legTime or 0) + (dt or 0)
                        -- Arrived: inside the radius, OR got close then started receding (overshoot:
                        -- center off the navmesh). Gave up: never got close and is now walking AWAY,
                        -- or 12s elapsed -- node is blocked / off-navmesh / on a different level.
                        local overshoot   = pt.minDist <= (arr + 2.0) and dist > pt.minDist + 2.0
                        local diverging   = pt.legTime > 4.0 and pt.minDist > arr and dist > pt.minDist + 4.0
                        local timedOut    = pt.legTime > 12.0 and dist > arr
                        local gaveUp      = diverging or timedOut
                        if dist <= arr or overshoot or gaveUp then
                            if gaveUp then
                                CC.logOnce("patrolstuck:" .. label .. ":" .. tostring(node),
                                    "[patrol] " .. label .. " can't reach '" .. tostring(node) .. "' (closest " ..
                                    string.format("%.1f", pt.minDist) .. "m) -- node is off-navmesh or behind a closed " ..
                                    "door; move it onto open floor on the same level she can walk to")
                            end
                            if CC.patrolDebug then
                                CC.log(string.format("[patrol] %s %s '%s' (dist=%.1f min=%.1f arr=%.1f)%s -> advancing",
                                    label, gaveUp and "GAVE UP on" or "ARRIVED", tostring(node), dist, pt.minDist, arr,
                                    overshoot and " [overshoot]" or ""))
                            end
                            pt.idx = pt.idx + 1                    -- arrived/gave up -> next leg
                            if pt.idx > #pt.nodes then
                                if pt.loop then pt.idx = 1 else CC.patrols[label] = nil end
                            end
                            local nl = CC.patrols[label] and pt.nodes[pt.idx]
                            local nd = nl and CC.labelPos(nl)
                            if nd then
                                -- no teleport pre-orient here either -- that was the node stutter.
                                pt.cmd = CC.aiMoveTo(ent, nd, pt.run)
                                pt.reissue, pt.legTime, pt.minDist, pt.lastPos = 0.0, 0.0, nil, nil
                                if CC.patrolDebug then
                                    CC.log(string.format("[patrol] %s -> '%s' (%.1f,%.1f,%.1f)", label, tostring(nl), nd.x, nd.y, nd.z))
                                end
                            end
                        else
                            pt.reissue = pt.reissue + (dt or 0)
                            if pt.reissue >= 1.0 then
                                pt.reissue = 0.0
                                -- re-issue only if the move command stopped running (combat or a
                                -- knockback cleared it) -- cleaner than guessing from stall distance.
                                if not CC.commandActive(ent, pt.cmd) then
                                    pt.cmd = CC.aiMoveTo(ent, dest, pt.run)
                                end
                                if CC.patrolDebug then
                                    CC.log(string.format("[patrol] %s en route '%s' dist=%.1f min=%.1f active=%s (need<=%.1f, %.0fs)",
                                        label, tostring(node), dist, pt.minDist, tostring(CC.commandActive(ent, pt.cmd)), arr, pt.legTime))
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- ========================================================================
    -- SPAWNING
    -- ========================================================================

    local function isSpawnable(e)
        if not e.id or e.action == "zone" then return false end
        return string.find(e.id, "Character%.") ~= nil
            or string.find(e.id, "Vehicle%.")  ~= nil
    end

    -- Facing as EulerAngles (yaw only). Prefer forward vector, then a captured
    -- (yaw-only) quaternion, else zero. One source for the angle.
    local function eulerFor(e)
        if e.fwd_x ~= nil and e.fwd_y ~= nil then
            return EulerAngles.new(0.0, 0.0, CC.forwardToYaw(e.fwd_x, e.fwd_y))
        end
        if e.r_r ~= nil then
            local yaw = math.deg(2.0 * math.atan2(e.r_k or 0.0, e.r_r))
            return EulerAngles.new(0.0, 0.0, yaw)
        end
        return EulerAngles.new(0.0, 0.0, 0.0)
    end

    local function spawnOne(e)
        local pos   = CC.vec4(e.x or 0.0, e.y or 0.0, e.z or 0.0)
        local euler = eulerFor(e)
        local id    = nil
        pcall(function()
            local spec = DynamicEntitySpec.new()
            spec.recordID      = TweakDBID.new(e.id)
            spec.position      = pos
            spec.orientation   = euler:ToQuat()
            spec.persistState  = false
            spec.persistSpawn  = false
            spec.alwaysSpawned = true
            if e.appearance and e.appearance ~= "" then
                spec.appearanceName = CName.new(e.appearance)
            end
            spec.tags = { CName.new("CyberpunkContracts") }
            id = dyn():CreateEntity(spec)
        end)
        if id then
            if e.label then CC.labelToEntityId[e.label] = id end
            CC.spawnedIds[#CC.spawnedIds + 1] = id
            CC.spawnFixups[#CC.spawnFixups + 1] = {
                id = id, label = e.label, pos = pos, euler = euler,
                attitude = e.startAttitude, age = 0.0,
            }
        else
            CC.dbg("spawn failed (bad record?): " .. tostring(e.id))
        end
        return id
    end

    -- Re-acquire a pre-existing WORLD device (door/terminal) tagged in the editor
    -- and register it under its label WITHOUT adding it to spawnedIds -- we don't
    -- own it, so teardown must never dispose it. A static world object keeps a
    -- STABLE persistent EntityID across save loads (it's placed by the level, not
    -- spawned by us), so the stored hash is the EXACT handle and is tried first;
    -- position+record is the fuzzy fallback, once findWorldEntityNear's spatial
    -- query is wired (see utils, STEP 1).
    local function acquireWorldDevice(e)
        local ent = nil
        if e.hash and e.hash ~= "0" and CC.entityFromHash then
            ent = CC.entityFromHash(e.hash)      -- exact object (stable for statics)
        end
        if not ent and CC.findWorldEntityNear and e.x then
            ent = CC.findWorldEntityNear({ x = e.x, y = e.y, z = e.z },
                { record = e.record, class = e.class, radius = e.radius or 2.5 })
        end
        if ent then
            local id = nil
            pcall(function() id = ent:GetEntityID() end)
            if id then
                CC.labelToEntityId[e.label] = id     -- NOT in spawnedIds (not ours)
                CC.log("bound device '" .. tostring(e.label) .. "'")
                return true
            end
        end
        CC.logOnce("dev:" .. tostring(e.label),
            "device '" .. tostring(e.label) .. "' not found at deploy - verify bind / spatial query")
        return false
    end

    function CC.spawnMissionEntities()
        local m = CC.activeMission
        if not m or not m.entities then return end
        local n = 0
        for _, e in ipairs(m.entities) do
            if e.action == "device" then
                acquireWorldDevice(e)
            elseif isSpawnable(e) and spawnOne(e) then
                n = n + 1
            end
        end
        CC.log("spawned " .. n .. " entit" .. (n == 1 and "y" or "ies"))
    end

    function CC.spawnRecord(action)
        local e = {
            id = action.id or action.target, label = action.label,
            appearance = action.appearance, startAttitude = action.startAttitude,
            x = action.x, y = action.y, z = action.z,
            r_i = action.r_i, r_j = action.r_j, r_k = action.r_k, r_r = action.r_r,
            fwd_x = action.fwd_x, fwd_y = action.fwd_y,
        }
        if not e.x then
            local p = CC.worldPos(Game.GetPlayer())
            if p then e.x, e.y, e.z = p.x, p.y, p.z end
        end
        return spawnOne(e)
    end

    -- Apply each pending fixup the first frame its entity resolves: fix facing,
    -- then REGISTER its initial attitude (which maintenance then keeps asserting).
    function CC.spawnFixupTick(dt)
        if not CC.spawnFixups or #CC.spawnFixups == 0 then return end
        local keep = {}
        for _, f in ipairs(CC.spawnFixups) do
            local ent = nil
            pcall(function() ent = Game.FindEntityByID(f.id) end)
            if ent then
                pcall(function() tp():Teleport(ent, f.pos, f.euler) end)        -- fix facing
                if f.attitude and f.label then
                    CC.setNpcAttitudeTracked(f.label, f.attitude)               -- register + assert
                end
                -- done; drop it
            else
                f.age = f.age + (dt or 0)
                if f.age < 5.0 then keep[#keep + 1] = f end
            end
        end
        CC.spawnFixups = keep
    end

    -- ------------------------------------------------------------------------
    -- EDITOR PREVIEWS
    -- ------------------------------------------------------------------------

    -- Spawn a preview body for every NPC in the editor blueprint (used by Load/
    -- Edit). Previews are forced NEUTRAL no matter the configured startAttitude —
    -- you don't want a hostile-configured guard attacking you mid-edit; the real
    -- attitude applies on deploy.
    function CC.spawnEditorPreviews()
        local bp = CC.editor and CC.editor.blueprint
        if not bp or not bp.entities then return end
        local n = 0
        for _, e in ipairs(bp.entities) do
            if e.id and e.label and string.find(e.id, "Character%.") then
                if spawnOne({
                    id = e.id, label = e.label, appearance = e.appearance,
                    x = e.x, y = e.y, z = e.z,
                    fwd_x = e.fwd_x, fwd_y = e.fwd_y,
                    r_i = e.r_i, r_j = e.r_j, r_k = e.r_k, r_r = e.r_r,
                    startAttitude = "neutral",        -- previews are always calm
                }) then n = n + 1 end
            end
        end
        if n > 0 then CC.log("spawned " .. n .. " preview bod" .. (n == 1 and "y" or "ies")) end
    end

    -- Teleport a live preview body to its (re-stamped) definition position/facing.
    function CC.movePreview(e)
        if not e or not e.label then return end
        local ent = CC.entityByLabel(e.label)
        if not ent then return end
        pcall(function()
            local yaw = (e.fwd_x and e.fwd_y) and CC.forwardToYaw(e.fwd_x, e.fwd_y) or 0.0
            tp():Teleport(ent, CC.vec4(e.x, e.y, e.z), EulerAngles.new(0.0, 0.0, yaw))
        end)
    end

    -- Turn an entity in place to face a target. `at`: nil/"player"/"v"/"V" -> face V;
    -- a label string -> face that object; a {x,y,z} -> face that point. Snap-faces via
    -- an in-place teleport (same path the spawn fixup uses). This was referenced by the
    -- face action but never defined, so every "face" verb silently did nothing.
    -- Core: rotate an entity to face a world point. A LIVE NPC re-derives its facing
    -- from locomotion every frame, so a raw teleport-rotation is overwritten instantly
    -- (that's why face "did nothing"). Issue it as an AI command instead -- the AI
    -- performs the in-place turn itself, so it holds. Fall back to a raw teleport for
    -- non-AI entities (props, dead bodies). Returns which path ran (for the test log).
    function CC.faceEntityTo(ent, to)
        if not ent or not to then return "nil" end
        local from = CC.worldPos(ent)
        if not from then return "nopos" end
        local dx, dy = to.x - from.x, to.y - from.y
        if (dx*dx + dy*dy) < 1e-4 then return "ontop" end   -- already on top of it
        -- Primary: native rotate command -- a REAL turn animation (AMM's Util:RotateTo).
        local viaRotate = pcall(function()
            local dest = WorldPosition.new()
            WorldPosition.SetVector4(dest, CC.vec4(to.x, to.y, to.z))
            local spec = AIPositionSpec.new()
            AIPositionSpec.SetWorldPosition(spec, dest)
            local cmd = AIRotateToCommand.new()
            cmd.target         = spec
            cmd.angleOffset    = 0.0      -- face straight at the point
            cmd.angleTolerance = 10.0     -- finish within ~10 degrees (loose = no jitter)
            cmd.speed          = 1.0
            ent:GetAIControllerComponent():SendCommand(cmd)
        end)
        if viaRotate then return "rotate" end
        -- Fallbacks: AI-teleport snap, then raw teleport (non-AI entity / older build).
        local yaw = CC.forwardToYaw(dx, dy)
        local viaAI = pcall(function()
            local cmd = AITeleportCommand.new()
            cmd.position  = CC.vec4(from.x, from.y, from.z)
            cmd.rotation  = yaw
            cmd.doNavTest = false
            ent:GetAIControllerComponent():SendCommand(cmd)
        end)
        if viaAI then return "snap" end
        pcall(function() tp():Teleport(ent, from, EulerAngles.new(0.0, 0.0, yaw)) end)
        return "tp"
    end

    function CC.faceToward(label, at)
        local ent = CC.entityByLabel(label)
        if not ent then return end
        local to
        if at == nil or at == "player" or at == "v" or at == "V" then
            to = CC.worldPos(Game.GetPlayer())
        elseif type(at) == "string" then
            to = CC.labelPos(at)
        elseif type(at) == "table" and at.x then
            to = at
        end
        if to then CC.faceEntityTo(ent, to) end
    end

    -- Remove ONE spawned body by label (object deletion in the editor).
    function CC.despawnOne(label)
        local id = CC.labelToEntityId and CC.labelToEntityId[label]
        if not id then return end
        local d = dyn()
        if d then pcall(function() d:DeleteEntity(id) end) end
        CC.labelToEntityId[label] = nil
        CC.npcAttitudes[label] = nil
        CC.npcGroups[label] = nil
        if CC.spawnedIds then
            for i, sid in ipairs(CC.spawnedIds) do
                if sid == id then table.remove(CC.spawnedIds, i) break end
            end
        end
    end

    function CC.despawnAll()
        local d = dyn()
        if d and CC.spawnedIds then
            for _, id in ipairs(CC.spawnedIds) do
                pcall(function() d:DeleteEntity(id) end)
            end
        end
        CC.spawnedIds      = {}
        CC.labelToEntityId = {}
        CC.spawnFixups     = {}
        CC.npcAttitudes    = {}
        CC.npcGroups       = {}
        CC.patrols         = {}
    end

    -- Despawn every preview body and respawn them from the current blueprint, so
    -- newly added/duplicated actors appear without a map reload. Zones/devices are
    -- gizmo overlays drawn straight from the blueprint, so they refresh on their own.
    function CC.refreshPreviews()
        CC.despawnAll()
        CC.spawnEditorPreviews()
        CC.log("refreshed object previews")
    end

    -- Editor-mutation helpers used by the add/place/move hotkeys --------------
    local function uniqueLabel(base)
        local bp = CC.editor and CC.editor.blueprint
        local ents = (bp and bp.entities) or {}
        local function taken(nm)
            for _, e in ipairs(ents) do if e.label == nm then return true end end
            return false
        end
        local n, name = 1, base .. "1"
        while taken(name) do n = n + 1; name = base .. n end
        return name
    end

    -- Drop a zone node (box/sphere) at V's feet and select it.
    function CC.placeZoneAtV(shape)
        local bp = CC.editor and CC.editor.blueprint
        if not bp then CC.log("place node: no mission open in the editor"); return end
        local p = CC.worldPos(Game.GetPlayer())
        if not p then return end
        bp.entities = bp.entities or {}
        local label = uniqueLabel("Node")
        local e
        if shape == "box" then
            e = { action = "zone", shape = "box", label = label,
                  x = p.x, y = p.y, z = p.z, sx = 4.0, sy = 4.0, sz = 3.0 }
        else
            e = { action = "zone", shape = "sphere", label = label,
                  x = p.x, y = p.y, z = p.z, radius = 3.0 }
        end
        if CC.pushUndo then CC.pushUndo() end
        bp.entities[#bp.entities + 1] = e
        if CC.editor then CC.editor.selectedLabel = label; CC.editor.dirty = true end
        CC.log("placed " .. (shape == "box" and "square" or "circle") .. " node '" .. label .. "' at V")
    end

    -- Move the currently-selected editor object to V's position + facing.
    function CC.moveSelectedToV()
        local bp  = CC.editor and CC.editor.blueprint
        local sel = CC.editor and CC.editor.selectedLabel
        if not bp or not sel then CC.log("move to V: select an object in the editor first"); return end
        local e
        for _, x in ipairs(bp.entities or {}) do if x.label == sel then e = x; break end end
        if not e then CC.log("move to V: '" .. tostring(sel) .. "' not found"); return end
        local p = CC.worldPos(Game.GetPlayer())
        if not p then return end
        if CC.pushUndo then CC.pushUndo() end
        e.x, e.y, e.z = p.x, p.y, p.z
        local f = nil; pcall(function() f = Game.GetPlayer():GetWorldForward() end)
        if f then e.fwd_x, e.fwd_y = f.x, f.y end
        if CC.movePreview then CC.movePreview(e) end
        if CC.editor then CC.editor.dirty = true end
        CC.log("moved '" .. tostring(sel) .. "' to V")
    end

    -- ---- FX + damage primitives (for play_fx / explode) ---------------------

    -- Play a world-space .effect/.particle at a fixed point (resolved ONCE, so it
    -- pins to the location and does not follow the target). FxSystem path -- proven.
    function CC.playWorldFx(pos, path)
        if not pos or not path or path == "" then return end
        pcall(function()
            local t = WorldTransform.new()
            t:SetPosition(Vector4.new(pos.x, pos.y, pos.z, 1.0))
            local fx  = Game.GetFxSystem()
            local res = gameFxResource.new({ effect = path })
            local h   = fx:SpawnEffect(res, t)
            if not IsDefined(h) then fx:SpawnEffectOnGround(res, t, true) end
        end)
    end

    -- Subtract health from one entity via the stat-pool system. [VERIFY in-game]
    function CC.damageEntity(ent, amount)
        if not ent then return end
        pcall(function()
            Game.GetStatPoolsSystem():RequestChangingStatPoolValue(
                ent:GetEntityID(), gamedataStatPoolType.Health, -math.abs(amount or 0), nil, false, true)
        end)
    end

    -- Damage every spawned NPC within `radius` of `pos` (live positions, 3D).
    function CC.damageInRadius(pos, radius, dmg)
        if not pos or not CC.labelToEntityId then return 0 end
        local r2, hit = (radius or 0) * (radius or 0), 0
        for label, _ in pairs(CC.labelToEntityId) do
            local ent = CC.entityByLabel(label)
            local p   = ent and CC.worldPos(ent)
            if p then
                local dx, dy, dz = p.x - pos.x, p.y - pos.y, p.z - pos.z
                if (dx*dx + dy*dy + dz*dz) <= r2 then
                    CC.damageEntity(ent, dmg); hit = hit + 1
                end
            end
        end
        return hit
    end

    -- ---- freeze / hide (runtime only -- both reset on save/reload) ----------

    -- Freeze an entity in place via per-entity time dilation (~0 = stopped). The
    -- signature varies by CET build, so net-cast it. [VERIFY with CCTestFreeze]
    function CC.freezeEntity(ent, frozen)
        if not ent then return end
        if frozen then
            local ok = pcall(function()
                ent:SetIndividualTimeDilation(CName.new("CCFreeze"), 0.0001, 0.0, "", "", true)
            end)
            if not ok then pcall(function() ent:SetIndividualTimeDilation(CName.new("CCFreeze"), 0.0001) end) end
        else
            pcall(function() ent:UnsetIndividualTimeDilation(CName.new("CCFreeze")) end)
        end
    end

    -- Hide/show an entity's visuals. Try the visual controller (all at once); fall
    -- back to toggling mesh components. Returns which path worked. [VERIFY w/ CCTestHide]
    function CC.hideEntity(ent, hidden)
        if not ent then return "nil" end
        local show = not hidden
        local viaVC = pcall(function()
            local vc = ent:GetVisualControllerComponent()
            vc:ToggleAllVisualComponents(show)
        end)
        if viaVC then return "vc" end
        local n = 0
        pcall(function()
            for _, c in ipairs(ent:GetComponents() or {}) do
                pcall(function()
                    if c:IsA("entMeshComponent") or c:IsA("entSkinnedMeshComponent")
                       or c:IsA("entPhysicalMeshComponent") or c:IsA("entSkinnedClothComponent") then
                        c:Toggle(show); n = n + 1
                    end
                end)
            end
        end)
        return "comp:" .. n
    end

    -- ========================================================================
    -- TEMP DEV HOTKEY — deploy a hardcoded test mission. (Move to hotkeys later.)
    -- Guy spawns ~6m ahead facing you, holds NEUTRAL (re-asserted), goes hostile
    -- only when you step into the zone, and killing him completes the mission.
    -- ========================================================================
    registerHotkey("CCDeployTest", "CC: Deploy Test Mission", function()
        local TEST_NPC = "Character.q001_scavenger_shotgun3"   -- a record you've confirmed spawns

        local p = CC.worldPos(Game.GetPlayer())
        if not p then CC.log("test: no player"); return end

        -- unit HORIZONTAL forward (ignore look pitch, or the zone lands too close)
        local fwd = nil
        pcall(function() fwd = Game.GetPlayer():GetWorldForward() end)
        local fx, fy = (fwd and fwd.x) or 1.0, (fwd and fwd.y) or 0.0
        local mag = math.sqrt(fx * fx + fy * fy)
        if mag < 0.01 then fx, fy = 1.0, 0.0 else fx, fy = fx / mag, fy / mag end

        local npc = {
            id = TEST_NPC, label = "TestGuy", is_target = true,
            x = p.x + fx * 10.0, y = p.y + fy * 10.0, z = p.z,
            fwd_x = -fx, fwd_y = -fy,
            startAttitude = "neutral",
        }
        local zone = {
            id = "Zone.trigger", action = "zone", label = "TestZone",
            x = p.x + fx * 7.0, y = p.y + fy * 7.0, z = p.z, radius = 2.5,
        }

        CC.deployMission({
            mission_id = "cc_test", title = "CC Test", fixer = "Test",
            briefing = "Walk into the zone to wake the guy up.",
            reward_money = 1000, reward_xp = 250,
            objective = { type = "kill_target" },
            entities = { npc, zone },
            events = {
                { id = "trip", when = "proximity", watch = "TestZone", radius = 3.0, actions = {
                    { ["do"] = "speak", target = "TestGuy", text = "The hell you doing here?" },
                    { ["do"] = "set_attitude", target = "all_npcs", attitude = "hostile" },
                }},
            },
        })
    end)

    -- TEMP DEV HOTKEY — read the looked-at NPC's LIVE attitude/group vs what we
    -- set, so we can see whether the group change is actually landing.
    registerHotkey("CCInspect", "CC: Inspect Target Attitude", function()
        local ent = CC.lookAt()
        if not ent then CC.log("inspect: aim at an NPC first"); return end
        pcall(function()
            local agent  = ent:GetAttitudeAgent()
            local pagent = Game.GetPlayer():GetAttitudeAgent()
            CC.log("--- INSPECT ---")
            CC.log("class        : " .. tostring(ent:GetClassName()))
            CC.log("toward player: " .. tostring(agent:GetAttitudeTowards(pagent)))
            CC.log("its group    : " .. tostring(agent:GetAttitudeGroup()))
            CC.log("player group : " .. tostring(pagent:GetAttitudeGroup()))
        end)
        for label, att in pairs(CC.npcAttitudes or {}) do
            CC.log("tracked '" .. label .. "' = " .. tostring(att)
                .. "  (orig group " .. tostring(CC.npcGroups and CC.npcGroups[label]) .. ")")
        end
    end)

    -- TEMP DEV HOTKEY — deploy the guy with NO rules. Nothing can set him hostile,
    -- so walk right up to him: if he stays neutral, the proximity rule was the only
    -- aggro source and the attitude system is solid. If he STILL aggros with zero
    -- rules, it's NPC-perception level, not us.
    registerHotkey("CCDeployNoRules", "CC: Deploy Peaceful (no rules)", function()
        local TEST_NPC = "Character.q001_scavenger_shotgun3"
        local p = CC.worldPos(Game.GetPlayer())
        if not p then CC.log("test: no player"); return end
        local fwd = nil
        pcall(function() fwd = Game.GetPlayer():GetWorldForward() end)
        local fx, fy = (fwd and fwd.x) or 1.0, (fwd and fwd.y) or 0.0
        local mag = math.sqrt(fx * fx + fy * fy)
        if mag < 0.01 then fx, fy = 1.0, 0.0 else fx, fy = fx / mag, fy / mag end

        CC.deployMission({
            mission_id = "cc_test_norules", title = "CC Test (no rules)", fixer = "Test",
            objective = { type = "kill_target" },
            entities = {
                { id = TEST_NPC, label = "TestGuy", is_target = true,
                  x = p.x + fx * 8.0, y = p.y + fy * 8.0, z = p.z,
                  fwd_x = -fx, fwd_y = -fy, startAttitude = "neutral" },
            },
            events = {},   -- NO rules: nothing here can flip him hostile
        })
    end)

end
