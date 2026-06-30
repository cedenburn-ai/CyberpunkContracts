-- ============================================================================
-- modules/hotkeys.lua
-- Functional dev/mechanic hotkeys. Bind in the CET "Bindings" tab.
-- (Inspect Attitude + Device Info were removed — the editor focus inspector
--  covers both live.)
--
-- AI hotkeys reuse the shared helpers in modules/actions / spawn. Device/door
-- hotkeys operate on whatever you're looking at, via the PS-event pattern —
-- these run the Phase 0 welded-door test.
-- ============================================================================

return function(CC)

    -- Queue a device PS event on the looked-at entity.
    local function onLookAtDevice(actionClass, name)
        local ent = CC.lookAt()
        if not ent then CC.log(name .. ": aim at a device/door"); return end
        if not actionClass then CC.log(name .. ": class is NIL (not a valid class in this build)"); return end
        local raw = "?"; pcall(function() raw = tostring(ent:GetEntityID().hash) end)
        local stored = CC.entityHash and CC.entityHash(ent) or "?"   -- exactly what bind would store
        local ok, err = pcall(function()
            local ps = ent:GetDevicePS()
            if not ps then error("no DevicePS on " .. tostring(ent:GetClassName()), 0) end
            local a = actionClass.new()
            a:SetUp(ps)
            a:SetExecutor(Game.GetPlayer())
            Game.GetPersistencySystem():QueuePSDeviceEvent(a)
        end)
        if ok then CC.log(name .. " -> " .. tostring(ent:GetClassName()) .. "  raw=" .. raw .. "  stored=" .. stored)
        else        CC.log(name .. ": FAILED - " .. tostring(err) .. "  raw=" .. raw) end
    end

    -- ---- doors -------------------------------------------------------------

    -- Unlock + open the door you're aiming at (the common "open this locked door").
    registerHotkey("CCDoorOpen", "CC: Door unlock + open", function()
        onLookAtDevice(QuestForceUnlock, "QuestForceUnlock")
        onLookAtDevice(QuestForceOpen,   "QuestForceOpen")
    end)

    -- ---- editor: add / place / move objects --------------------------------

    -- Add the world object under the crosshair into the open blueprint as a Device.
    -- Same capture path as the Place window's Device button; auto-names DeviceN.
    registerHotkey("CCBindDevice", "CC: Add device at crosshair", function()
        local ed = CC.editor
        local bp = ed and ed.blueprint
        if not bp then CC.log("add device: no mission open in the editor"); return end
        bp.entities = bp.entities or {}
        local used = {}
        for _, en in ipairs(bp.entities) do if en.label then used[en.label] = true end end
        local n, name = 1, "Device1"
        while used[name] do n = n + 1; name = "Device" .. n end
        local e, err = CC.captureDevice(name)
        if not e then CC.log("add device: " .. tostring(err)); return end
        if CC.pushUndo then CC.pushUndo() end
        bp.entities[#bp.entities + 1] = e
        ed.dirty = true
        ed.selectedLabel = name
        CC.log("added device '" .. name .. "' (" .. tostring(e.class) .. ")")
    end)

    registerHotkey("CCPlaceSquare", "CC: Place square node at V",    function() CC.placeZoneAtV("box")    end)
    registerHotkey("CCPlaceCircle", "CC: Place circle node at V",    function() CC.placeZoneAtV("sphere") end)
    registerHotkey("CCMoveSelToV",  "CC: Move selected object to V", function() CC.moveSelectedToV()      end)

    -- ---- PROP SPAWN TEST (stability-critical) -------------------------------
    -- exEntitySpawner = CET's prop spawner (what AMM / World Builder use). Props are
    -- .ent template paths. I can't verify exact base-game paths from here, so SET ONE:
    -- copy a path from AMM's prop browser / World Builder, paste into PROP_PATHS.
    -- PROTOCOL: spawn ONE -> confirm it appears -> despawn -> confirm it's gone ->
    -- then SAVE + RELOAD the save and confirm it did NOT come back (no save leak).
    local PROP_PATHS = {
        -- [VERIFY] replace with real .ent paths (these are plausible guesses only):
        "base\\environment\\decoration\\furniture\\chair\\chair_office_a.ent",
        "base\\environment\\architecture\\common\\int\\containers\\container_crate_a.ent",
    }
    CC.spawnedProps = CC.spawnedProps or {}
    local pIdx = 0
    registerHotkey("CCSpawnProp", "CC: TEST spawn prop at crosshair", function()
        if not exEntitySpawner then CC.log("prop: exEntitySpawner missing (update CET)"); return end
        local p = Game.GetPlayer()
        local pos, fwd = p:GetWorldPosition(), p:GetWorldForward()
        pIdx = (pIdx % #PROP_PATHS) + 1
        local path = PROP_PATHS[pIdx]
        local id
        local ok, err = pcall(function()
            local t = WorldTransform.new()
            t:SetOrientation(p:GetWorldOrientation())
            t:SetPosition(Vector4.new(pos.x + fwd.x * 2.0, pos.y + fwd.y * 2.0, pos.z, 1.0))
            id = exEntitySpawner.Spawn(path, t, "")
        end)
        if ok and id then
            CC.spawnedProps[#CC.spawnedProps + 1] = id
            CC.log("prop: spawned '" .. path .. "'  (tracking " .. #CC.spawnedProps .. ")")
        else
            CC.log("prop: FAILED '" .. path .. "' -- " .. tostring(err) .. "  (set a real .ent path)")
        end
    end)

    registerHotkey("CCClearProps", "CC: Despawn test props", function()
        local n, gone = #(CC.spawnedProps or {}), 0
        for _, id in ipairs(CC.spawnedProps or {}) do
            local ok = false
            pcall(function() local e = Game.FindEntityByID(id); if e then e:Dispose(); ok = true end end)
            if not ok then pcall(function() Game.GetDynamicEntitySystem():DeleteEntity(id); ok = true end) end
            if ok then gone = gone + 1 end
        end
        CC.spawnedProps = {}
        CC.log("prop: despawned " .. gone .. "/" .. n .. " (look around -- any ghosts left?)")
    end)

    -- Diagnostic: toggle the [aiMoveTo] dest/dist logging -- handy when a move or
    -- patrol misbehaves (prints the resolved destination vs the NPC's position).
    registerHotkey("CCToggleMoveDebug", "CC: Toggle move/path debug log", function()
        CC.moveDebug = not CC.moveDebug
        CC.log("move/path debug: " .. (CC.moveDebug and "ON" or "off"))
    end)

    -- Falsify the two new AMM-derived verbs before building a stage around them.
    local looking = false
    registerHotkey("CCTestLookAt", "CC: TEST look_at / clear (toggle, look-at)", function()
        local ent = CC.lookAt()
        if not ent then CC.log("look_at: aim at an NPC"); return end
        looking = not looking
        if looking then
            local how = CC.npcLookAt(ent, Game.GetPlayer())
            CC.log("look_at: " .. tostring(ent:GetClassName()) .. " now TRACKING V via " .. tostring(how))
        else
            local how = CC.stopLookAt(ent)
            CC.log("look_at: CLEARED on " .. tostring(ent:GetClassName()) .. " via " .. tostring(how))
        end
    end)

    local imm = false
    registerHotkey("CCTestImmortal", "CC: TEST immortal toggle (look-at)", function()
        local ent = CC.lookAt()
        if not ent then CC.log("immortal: aim at an NPC"); return end
        imm = not imm
        CC.setImmortal(ent, imm)
        CC.log("immortal: " .. (imm and "IMMORTAL -- now shoot it, should survive" or "mortal again") .. " " .. tostring(ent:GetClassName()))
    end)

    -- ========================================================================
    -- FACTION-FIGHT TEST HARNESS (falsify-first, per the research doc).
    -- Spawn 2 of side A + 2 of side B, wait for puppets to ATTACH
    -- (GetAttitudeAgent ~= nil), then pairwise SetAttitudeTowards: cross-side
    -- hostile, same-side friendly -- with read-back, so we separate "did the
    -- write take" from "did they fight". Wiring is driven by TickAlways (no Cron
    -- here). These are throwaway NPCs, NOT mission entities; ffClear despawns them.
    -- ========================================================================
    local FF_RECORD_A = "Character.q001_scavenger_shotgun3"                               -- spawnable (proven)
    local FF_RECORD_B = "Character.sts_wat_nid_04_enemy_maelstrom_fast_sniper2_grad_ma"   -- VERIFY: swap if it never resolves

    local function ffSpawn(record, pos)
        local id
        pcall(function()
            local spec = DynamicEntitySpec.new()
            spec.recordID      = TweakDBID.new(record)
            spec.position      = pos
            spec.orientation   = Quaternion.new(0, 0, 0, 1)
            spec.persistState  = false
            spec.persistSpawn  = false
            spec.alwaysSpawned = true
            spec.tags          = { CName.new("CyberpunkContracts") }
            id = Game.GetDynamicEntitySystem():CreateEntity(spec)
        end)
        return id
    end

    -- Drained by TickAlways: once every spawned agent resolves (or a 6s timeout),
    -- wire the attitude cross-product ONCE and read it back.
    function CC.tickFactionTest(dt)
        local st = CC.ffTest
        if not st or st.wired then return end
        local waited = os.clock() - st.t0
        if waited < 1.0 then return end
        local A, B, ready = {}, {}, true
        for _, id in ipairs(st.a) do
            local e = Game.FindEntityByID(id); local ag = e and e:GetAttitudeAgent()
            if ag then A[#A + 1] = ag else ready = false end
        end
        for _, id in ipairs(st.b) do
            local e = Game.FindEntityByID(id); local ag = e and e:GetAttitudeAgent()
            if ag then B[#B + 1] = ag else ready = false end
        end
        if not ready and waited < 6.0 then return end
        st.wired = true
        if #A == 0 or #B == 0 then
            CC.log("[FF] ABORT: agents never resolved (A=" .. #A .. " B=" .. #B .. ") -- does FF_RECORD_B spawn?")
            return
        end
        CC.log(string.format("[FF] wiring A=%d B=%d (waited %.1fs)", #A, #B, waited))
        for _, agA in ipairs(A) do
            for _, agB in ipairs(B) do
                pcall(function()
                    local before = agA:GetAttitudeTowards(agB)
                    agA:SetAttitudeTowards(agB, EAIAttitude.AIA_Hostile)
                    agB:SetAttitudeTowards(agA, EAIAttitude.AIA_Hostile)
                    local after = agA:GetAttitudeTowards(agB)
                    CC.log("[FF] cross  before=" .. tostring(before) .. "  after=" .. tostring(after))
                end)
            end
        end
        local function bindFriendly(grp)
            for i = 1, #grp do for j = i + 1, #grp do
                pcall(function()
                    grp[i]:SetAttitudeTowards(grp[j], EAIAttitude.AIA_Friendly)
                    grp[j]:SetAttitudeTowards(grp[i], EAIAttitude.AIA_Friendly)
                end)
            end end
        end
        bindFriendly(A); bindFriendly(B)
        CC.log("[FF] wired. If cross reads AIA_Hostile but they idle -> it's sensing/placement,")
        CC.log("[FF] not the write. Put them in line-of-sight, or use FactionFight: Force engage.")
    end

    registerHotkey("ffSpawn", "FactionFight: Spawn A vs B", function()
        local p   = CC.worldPos and CC.worldPos(Game.GetPlayer())
        local fwd = nil; pcall(function() fwd = Game.GetPlayer():GetWorldForward() end)
        if not p or not fwd then CC.log("[FF] no player pos/forward"); return end
        local right = { x = fwd.y, y = -fwd.x }                    -- horizontal perpendicular
        local function ffAt(fdist, side)                           -- in front of V, offset left/right
            return Vector4.new(p.x + fwd.x * fdist + right.x * side,
                               p.y + fwd.y * fdist + right.y * side,
                               p.z, 1.0)
        end
        local a, b, all = {}, {}, {}
        for i = 1, 2 do
            local idA = ffSpawn(FF_RECORD_A, ffAt(6 + i, -3))      -- left cluster
            local idB = ffSpawn(FF_RECORD_B, ffAt(6 + i,  3))      -- right cluster, ~6m across, in LOS
            if idA then a[#a + 1] = idA; all[#all + 1] = idA end
            if idB then b[#b + 1] = idB; all[#all + 1] = idB end
        end
        CC.ffTest = { a = a, b = b, all = all, t0 = os.clock(), wired = false }
        CC.log("[FF] spawned A=" .. #a .. " B=" .. #b .. " in front of V -- wiring after attach")
    end)

    registerHotkey("ffClear", "FactionFight: Despawn test NPCs", function()
        local st = CC.ffTest
        if st then
            for _, id in ipairs(st.all) do
                pcall(function() Game.GetDynamicEntitySystem():DeleteEntity(id) end)
            end
        end
        CC.ffTest = nil
        CC.log("[FF] cleared")
    end)

    registerHotkey("ffPoke", "FactionFight: Force engage (report back)", function()
        -- Phase 2 only: use IF the cross read-back showed AIA_Hostile but they still
        -- idle. The right combat nudge (stim broadcast vs AI command vs alert state)
        -- needs a method verified on YOUR build, so this reports instead of guessing.
        if not CC.ffTest then CC.log("[FF] nothing spawned"); return end
        local st, fired = CC.ffTest, 0
        for _, idA in ipairs(st.a) do
            for _, idB in ipairs(st.b) do
                local eA = Game.FindEntityByID(idA)
                local eB = Game.FindEntityByID(idB)
                if eA and eB and CC.triggerCombat then CC.triggerCombat(eA, eB); fired = fired + 1 end
            end
        end
        CC.log("[FF] force-engage: TriggerCombat fired on " .. fired .. " cross-pair(s)")
    end)

end
