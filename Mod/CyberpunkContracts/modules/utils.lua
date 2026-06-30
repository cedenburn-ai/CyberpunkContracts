-- ============================================================================
-- modules/utils.lua
-- Small, generic, cross-cutting helpers. Nothing in here knows about missions,
-- the editor, or the state machine — those modules use these, never the reverse.
--
-- SECOND-LOOK NOTES (what changed from the old iterated helpers, and why):
--   * RNG is seeded ONCE, here — not on every call. The old code reseeded with
--     os.time() on each wake; two reseeds in the same second produce the SAME
--     sequence, so "random" picks repeat. Seed once, then just draw.
--   * math.atan2 (not math.atan). CET is LuaJIT / Lua 5.1, where the two-arg
--     form is atan2. The forward->yaw conversion is isolated in ONE function so
--     its sign/convention is calibrated in-game once and never re-argued.
--   * Range checks compare SQUARED distance (no sqrt), because proximity runs
--     every frame for every zone. dist3/dist2 are for when you need the number.
--   * ENTITY IDENTITY now has an explicit priority, top of the file so it can't
--     drift:
--         1. Things WE spawned   -> CC.entityByLabel(label)      (label -> EntityID)
--         2. Pre-existing world  -> CC.findWorldEntityNear(pos)  (re-find by position)
--         3. Absolute last resort-> CC.entityFromHash(hash)      (session-fragile)
--     Hashes change across save loads, so they are never the primary handle.
--   * AI-command and device-PS-event builders are deliberately NOT here. They
--     are mission verbs and live in modules/actions, in exactly one place, so
--     the hotkeys and the runtime share them instead of each rebuilding them.
-- ============================================================================

return function(CC)

    -- ========================================================================
    -- DEBUG LOGGING
    -- CC.log / CC.logOnce already exist (init.lua). CC.dbg adds a channel that
    -- only prints while CC.debug is true — for the noisy per-frame output you
    -- flip on to hunt a bug and off again afterward.
    -- ========================================================================
    CC.debug = false
    function CC.dbg(msg)
        if CC.debug then CC.log("[dbg] " .. tostring(msg)) end
    end

    -- ========================================================================
    -- VECTORS / ROTATION
    -- ========================================================================

    -- Build a Vector4 from plain numbers (w defaults to 1.0, correct for positions).
    function CC.vec4(x, y, z, w)
        return Vector4.new(x or 0.0, y or 0.0, z or 0.0, w or 1.0)
    end

    -- Forward vector (fwd_x, fwd_y) -> yaw in DEGREES for EulerAngles.
    -- NPCs stand upright, so yaw is the only rotation that matters; this is the
    -- robust spawn-placement path. The zero-heading sign/arg-order almost
    -- certainly needs ONE in-game calibration (spawn a guard facing a known way,
    -- see where he points, adjust the sign here once). Kept in a single function
    -- so that calibration lives in exactly one place.
    function CC.forwardToYaw(fwd_x, fwd_y)
        return math.deg(math.atan2(fwd_x, fwd_y)) * -1.0   -- verify in-game once
    end

    -- ========================================================================
    -- DISTANCE
    -- dist3 / dist2 return the real distance (with sqrt). withinRange compares
    -- the SQUARED distance and skips the sqrt — use it for per-frame proximity.
    -- Positions are anything with .x/.y/.z (a Vector4 or a plain {x,y,z}).
    -- ========================================================================
    function CC.dist3(a, b)
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return math.sqrt(dx*dx + dy*dy + dz*dz)
    end

    function CC.dist2(a, b)  -- planar; ignores z
        local dx, dy = a.x - b.x, a.y - b.y
        return math.sqrt(dx*dx + dy*dy)
    end

    -- True if b is within radius r of a (3D). No sqrt — for hot-path checks.
    function CC.withinRange(a, b, r)
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return (dx*dx + dy*dy + dz*dz) <= (r * r)
    end

    -- Distance from the player to a world position (nil if there's no player).
    function CC.distToPlayer(pos)
        local p = nil
        pcall(function() p = Game.GetPlayer():GetWorldPosition() end)
        if not p then return nil end
        return CC.dist3(p, pos)
    end

    -- ========================================================================
    -- ENTITY HELPERS — generic primitives. The PRIORITY of which to use lives in
    -- the identity note at the top; the policy of choosing lives in editor/player.
    -- ========================================================================

    -- The entity the player is currently looking at, or nil. Used by the editor
    -- to TAG things (crosshair gives you the live handle + position in one go),
    -- and replaces the GetLookAtObject + pcall block copy-pasted into old hotkeys.
    function CC.lookAt()
        local ent = nil
        pcall(function()
            ent = Game.GetTargetingSystem():GetLookAtObject(Game.GetPlayer(), false, false)
        end)
        return ent
    end

    -- World position of an entity, or nil.
    function CC.worldPos(entity)
        if not entity then return nil end
        local pos = nil
        pcall(function() pos = entity:GetWorldPosition() end)
        return pos
    end

    -- (1) PRIMARY for things WE spawned. Resolve label -> EntityID -> live handle.
    -- CC.labelToEntityId is filled by the spawn module at deploy. This is the
    -- reliable path: we own the EntityID, no hashes, valid for the whole session.
    function CC.entityByLabel(label)
        local id = CC.labelToEntityId and CC.labelToEntityId[label]
        if not id then return nil end
        local ent = nil
        pcall(function() ent = Game.FindEntityByID(id) end)
        return ent
    end

    -- (2) PRIMARY for pre-existing WORLD entities (welded doors, world props).
    -- The editor tags one by position + record at author time; at deploy we
    -- re-find it spatially, because position survives a save load and a hash does
    -- not. Returns the closest matching entity within radius, or nil.
    --   opts = { record = "<TweakDBID string>", class = "<class name>", radius = 2.0 }
    --
    -- VERIFY-IN-GAME: the only unconfirmed part is STEP 1 — the exact CET call
    -- for "entities within radius of an arbitrary point." Candidates to test:
    --     * Game.GetTargetingSystem() area/sphere search
    --     * Game.GetSpatialQueriesSystem()
    --     * a device-registry walk (for doors specifically)
    -- The filter + closest-pick logic below is final; only the candidate gather
    -- needs wiring once we confirm the API. Until then it logs once and returns nil.
    function CC.findWorldEntityNear(pos, opts)
        opts = opts or {}
        local radius = opts.radius or CC.config.defaultProximity

        -- STEP 1: gather candidate entities near `pos`.  <-- the piece to verify
        local candidates = nil   -- TODO: populate via the confirmed spatial query
        if not candidates then
            CC.logOnce("findWorldEntityNear",
                "findWorldEntityNear: spatial query not wired yet — verify the API in-game")
            return nil
        end

        -- STEP 2: filter by record/class, return the closest within radius. (Final.)
        local best, bestDist = nil, radius
        for _, ent in ipairs(candidates) do
            local p = CC.worldPos(ent)
            if p and CC.withinRange(pos, p, radius) then
                local match = true
                if opts.record then
                    local rec = "0"
                    pcall(function() rec = tostring(ent:GetRecordID()) end)
                    if rec ~= opts.record then match = false end
                end
                if match and opts.class then
                    local cls = "0"
                    pcall(function() cls = tostring(ent:GetClassName()) end)
                    if cls ~= opts.class then match = false end
                end
                if match then
                    local d = CC.dist3(pos, p)
                    if d <= bestDist then best, bestDist = ent, d end
                end
            end
        end
        return best
    end

    -- uint64 hash of an entity as a STRING ("0" on failure). We keep these as
    -- strings because the raw uint64 doesn't survive as a Lua double and we
    -- write them into mission JSON.
    function CC.entityHash(entity)
        if not entity then return "0" end
        local h = "0"
        pcall(function() h = tostring(entity:GetEntityID().hash) end)
        -- Keep the REAL value: drop only whitespace and a trailing ULL. Do NOT
        -- strip to digits -- a hex hash (0x...) would be butchered into garbage.
        h = h:gsub("%s", ""):gsub("[Uu][Ll][Ll]$", "")
        if h == "" then h = "0" end
        return h
    end

    -- BIND the pre-existing world object under the crosshair into a device entity
    -- table { action="device", label, x,y,z, record, class, hash }. Single capture
    -- path shared by the Place window's Bind button AND the bind hotkey. The hash
    -- is the EXACT handle (a static object's persistent EntityID is stable across
    -- save loads); position+record is the fuzzy fallback. Returns (e) or (nil, err).
    function CC.captureDevice(label)
        local ent = CC.lookAt and CC.lookAt()
        if not ent then return nil, "aim at a device first - nothing under the crosshair" end
        local dp = CC.worldPos(ent)
        local rec, cls = nil, nil
        pcall(function() rec = tostring(ent:GetRecordID()) end)
        pcall(function() cls = tostring(ent:GetClassName()) end)
        return {
            action = "device", label = label,
            x = dp and dp.x or 0.0, y = dp and dp.y or 0.0, z = dp and dp.z or 0.0,
            record = rec, class = cls,
            hash = CC.entityHash and CC.entityHash(ent) or nil,
        }
    end

    -- (3) LAST RESORT only. Resolve a stored hash to a live world entity, or nil.
    -- Hashes are session-fragile (they change across save loads), so prefer
    -- entityByLabel for our spawns and findWorldEntityNear for world objects.
    -- RECONCILE-ME: rebuilt from how the old code used it, not from the old code.
    -- Relies on MakeEntityID (our CET fork's native bridge); the hash format MUST
    -- match how we store hashes (old JSON used "...ULL" strings) — confirm before
    -- trusting this.
    function CC.entityFromHash(hash)
        if not hash then return nil end
        local s = tostring(hash):gsub("%s", ""):gsub("[Uu][Ll][Ll]$", "")   -- keep hex or decimal
        if s == "" or s == "0" or s == "0x0" then return nil end

        local ent, why = nil, nil

        -- Parse the decimal/hex hash into a uint64 using ONLY compiled ULL literals
        -- (no load(), no ffi) so nothing can be sandboxed out from under us. Then
        -- drop it into a freshly built EntityID -- no fork native needed.
        local function parseU64(str)
            local u
            pcall(function()
                if str:match("^0[xX]%x+$") then
                    u = 0ULL
                    for i = 3, #str do
                        local c = str:byte(i)
                        local d = (c >= 48 and c <= 57) and (c - 48)
                               or (c >= 97 and c <= 102) and (c - 87)
                               or (c >= 65 and c <= 70) and (c - 55) or -1
                        if d < 0 then u = nil; return end
                        u = u * 16ULL + d
                    end
                elseif str:match("^%d+$") then
                    u = 0ULL
                    for i = 1, #str do u = u * 10ULL + (str:byte(i) - 48) end
                end
            end)
            return u
        end

        local function reconstruct()
            local u = parseU64(s)
            if not u then why = "could not parse hash to uint64: " .. s; return end
            local id
            if not pcall(function() id = EntityID.new({ hash = u }) end) or not id then
                id = nil
                pcall(function() id = EntityID.new() end)
                if id then pcall(function() id.hash = u end) end
            end
            if not id then why = "EntityID.new not constructable here"; return end
            pcall(function() ent = Game.FindEntityByID(id) end)
            if not ent then why = "FindEntityByID returned nil (object not streamed in?)" end
        end

        if type(MakeEntityID) == "function" then
            pcall(function() ent = Game.FindEntityByID(MakeEntityID(s)) end)
            if not ent then reconstruct() end
        else
            reconstruct()
        end

        if not ent then CC.logOnce("fromhash", "entityFromHash(" .. s .. "): " .. tostring(why or "unresolved")) end
        return ent
    end

    -- ========================================================================
    -- RANDOM  (seeded ONCE, here — see second-look note)
    -- ========================================================================
    math.randomseed(os.time())

    -- Random element from a list (nil if empty).
    function CC.pick(list)
        if not list or #list == 0 then return nil end
        return list[math.random(1, #list)]
    end

    -- Random integer in [a, b].
    function CC.randInt(a, b)
        return math.random(a, b)
    end

end
