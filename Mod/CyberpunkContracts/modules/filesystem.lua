-- ============================================================================
-- modules/filesystem.lua
-- Mission persistence. Saves/loads mission JSON and handles versioned migration
-- on load.
--
-- MODERNIZED: the old index.json pool is GONE. CET exposes dir() to enumerate a
-- directory, so the missions/ folder itself is now the single source of truth —
-- no separate index to keep in sync, no drift. Save writes a file; load scans
-- the folder; delete removes the file. That's the whole model.
--
-- SETUP: create a "missions/" folder inside the CyberpunkContracts mod dir.
-- CET's io.open won't create it; if saves fail, that's the usual reason.
--
-- SANDBOX NOTES (CET):
--   * All io / dir pathing is RELATIVE to the mod folder (CET chroots it).
--   * json.decode is a CET global; jsonEncode below is ours (readable output).
--   * DELETE: os.remove may or may not be whitelisted in your CET build. We try
--     it first; if it's blocked, we fall back to a per-file TOMBSTONE marker
--     ("<file>.deleted") that the loader skips — so delete always works in-game,
--     index-free, with no central bookkeeping. (Run `print(type(os.remove))` in
--     the CET console to see which path your build takes.)
-- ============================================================================

return function(CC)

    local MISSIONS_DIR = "missions/"   -- trailing slash: used for io.open paths

    -- ------------------------------------------------------------------------
    -- Pretty JSON encoder (readable mission files — the file IS the editor).
    -- ------------------------------------------------------------------------
    local function jsonEncode(v, indent)
        indent = indent or 0
        local t = type(v)
        if t == "nil"     then return "null" end
        if t == "boolean" then return v and "true" or "false" end
        if t == "number"  then return tostring(v) end
        if t == "string"  then
            return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
        end
        if t == "table" then
            local isArray, n = true, 0
            for k, _ in pairs(v) do
                n = n + 1
                if type(k) ~= "number" then isArray = false end
            end
            if n == 0 then return "{}" end
            local pad, close = string.rep("  ", indent + 1), string.rep("  ", indent)
            local parts = {}
            if isArray then
                for i = 1, #v do parts[#parts + 1] = pad .. jsonEncode(v[i], indent + 1) end
            else
                for k, val in pairs(v) do
                    parts[#parts + 1] = pad .. '"' .. tostring(k) .. '": ' .. jsonEncode(val, indent + 1)
                end
            end
            local open, shut = isArray and "[" or "{", isArray and "]" or "}"
            return open .. "\n" .. table.concat(parts, ",\n") .. "\n" .. close .. shut
        end
        return "null"
    end

    -- ------------------------------------------------------------------------
    -- DIRECTORY SCAN — the replacement for index.json. Lists missions/ via CET's
    -- dir() and returns the mission filenames on disk, honoring tombstones.
    --
    -- dir()'s exact shape has varied across CET versions, so this is defensive:
    --   * tolerates entries that are tables ({name=..,type=..}) OR plain strings
    --   * tries the path with and without a trailing slash
    --   * filters on the ".json" name (no reliance on the entry's type string)
    --   * skips any "<file>.json" that has a sibling "<file>.json.deleted"
    -- ------------------------------------------------------------------------
    local function entryName(f)
        if type(f) == "string" then return f end
        if type(f) == "table"  then return f.name end
        return nil
    end

    local function scanMissionFiles()
        local files = {}

        if type(dir) ~= "function" then
            CC.logOnce("nodir",
                "filesystem: dir() not available on this CET build — can't list missions/. " ..
                "Update CET, or tell me and I'll add an index fallback.")
            return files
        end

        local entries = nil
        pcall(function() entries = dir("missions") end)            -- no trailing slash
        if not entries or #entries == 0 then
            pcall(function() entries = dir(MISSIONS_DIR) end)       -- with trailing slash
        end
        if not entries then
            CC.logOnce("emptymissions",
                "filesystem: dir() returned nothing for missions/ (folder missing or empty?)")
            return files
        end

        -- first pass: collect tombstones ("foo.json.deleted" -> mark "foo.json")
        local tombstoned = {}
        for _, f in ipairs(entries) do
            local name = entryName(f)
            if type(name) == "string" then
                local base = name:match("^(.+)%.deleted$")
                if base then tombstoned[base] = true end
            end
        end

        -- second pass: real, live mission files
        for _, f in ipairs(entries) do
            local name = entryName(f)
            if type(name) == "string" and name:match("%.json$") and not tombstoned[name] then
                files[#files + 1] = name
            end
        end
        return files
    end

    -- ------------------------------------------------------------------------
    -- VERSION MIGRATION (append-only, per our rule: one step per version bump).
    -- Keep migrations forever; never delete one. Returns the migrated mission.
    -- ------------------------------------------------------------------------
    function CC.migrateMission(m)
        if not m then return m end
        m.version = m.version or 1
        -- v4 -> v5: add the quest lifecycle envelope (setup/win/lose/finally).
        -- Append-only: old missions get an empty envelope and keep completing via
        -- objective.type (the legacy path stays live until Pass 2 wires this).
        m.lifecycle         = m.lifecycle or {}
        m.lifecycle.setup   = m.lifecycle.setup   or { actions = {} }
        m.lifecycle.win     = m.lifecycle.win     or { groups = {} }
        m.lifecycle.lose    = m.lifecycle.lose    or { groups = {} }
        m.lifecycle.finally = m.lifecycle.finally or { actions = {} }
        if (m.version or 1) < 5 then m.version = 5 end
        return m
    end

    -- ------------------------------------------------------------------------
    -- SAVE — just write the file. No index to touch. If this id was previously
    -- tombstoned (deleted while os.remove was blocked), clear the tombstone so
    -- the mission re-appears in the pool.
    -- ------------------------------------------------------------------------
    function CC.saveMission(mission)
        if not mission or not mission.mission_id then
            CC.log("save: mission needs a mission_id"); return false
        end
        local filename = mission.mission_id .. ".json"
        local f = io.open(MISSIONS_DIR .. filename, "w")
        if not f then
            CC.log("save failed (does missions/ exist?): " .. filename); return false
        end
        f:write(jsonEncode(mission, 0)); f:close()
        pcall(function()
            if os and os.remove then os.remove(MISSIONS_DIR .. filename .. ".deleted") end
        end)
        CC.log("saved mission: " .. filename)
        return true
    end

    -- ------------------------------------------------------------------------
    -- Mission shape check. A real mission is a JSON OBJECT carrying a non-empty
    -- string mission_id (saveMission guarantees one). This is what separates a
    -- genuine mission from any other .json that happens to sit in missions/ —
    -- most notably the deprecated index.json (a JSON ARRAY with no mission_id),
    -- which previously parsed "successfully" and polluted the pool.
    -- ------------------------------------------------------------------------
    local function isMission(m)
        return type(m) == "table"
           and type(m.mission_id) == "string"
           and m.mission_id ~= ""
    end

    -- ------------------------------------------------------------------------
    -- LOAD a single mission file by name. Validates in two stages; on EITHER
    -- failure it logs ONCE to the CET log (logOnce keeps a corrupt/stray file
    -- from spamming on every rescan) and returns nil, so loadMissionPool skips
    -- it instead of parking junk in the pool:
    --   1. must be valid JSON that decodes to a table
    --   2. must be mission-shaped (isMission) — this is the real fix
    -- ------------------------------------------------------------------------
    function CC.loadMission(filename)
        local f = io.open(MISSIONS_DIR .. filename, "r")
        if not f then return nil end
        local content = f:read("*a"); f:close()

        local ok, m = pcall(json.decode, content)
        if not ok or type(m) ~= "table" then
            CC.logOnce("badjson:" .. filename,
                "filesystem: SKIPPED '" .. filename .. "' — not valid JSON (" ..
                tostring(m) .. ")")
            return nil
        end
        if not isMission(m) then
            CC.logOnce("notmission:" .. filename,
                "filesystem: SKIPPED '" .. filename .. "' — valid JSON but not a " ..
                "mission (no mission_id). Stray file in missions/ (e.g. the old " ..
                "index.json) — safe to delete from disk.")
            return nil
        end
        return CC.migrateMission(m)
    end

    -- ------------------------------------------------------------------------
    -- DELETE — real removal first, tombstone fallback if the sandbox blocks it.
    -- Either way the mission is gone from the pool after the reload. NOT undoable
    -- (the undo stack only covers in-editor blueprint edits, never the disk).
    -- ------------------------------------------------------------------------
    function CC.deleteMission(filename)
        if not filename or filename == "" then
            CC.log("delete: no filename"); return false
        end
        local path = MISSIONS_DIR .. filename

        -- 1) try a real delete
        local removed = false
        pcall(function()
            if os and os.remove then removed = (os.remove(path) == true) end
        end)

        -- 2) verify: if the file no longer opens, it's genuinely gone
        if not removed then
            local fh = io.open(path, "r")
            if fh then fh:close() else removed = true end
        end

        if removed then
            -- clear any stale tombstone so a future save to this id is clean
            pcall(function()
                if os and os.remove then os.remove(path .. ".deleted") end
            end)
            CC.log("deleted mission file: " .. filename)
        else
            -- 3) sandbox blocked deletion: write a tombstone the loader will skip
            local t = io.open(path .. ".deleted", "w")
            if t then
                t:write("1"); t:close()
                CC.log("delete: os.remove blocked — tombstoned (file remains on disk): " .. filename)
            else
                CC.log("delete FAILED (no os.remove and can't write tombstone): " .. filename)
                return false
            end
        end

        if CC.loadMissionPool then CC.loadMissionPool() end   -- refresh the pool
        return true
    end

    -- ------------------------------------------------------------------------
    -- LOAD POOL — scan missions/ off disk and load every mission file found.
    -- CC.manifest now means "mission filenames currently on disk" (kept for any
    -- code that still reads it; state.lua declares it).
    -- ------------------------------------------------------------------------
    function CC.loadMissionPool()
        CC.missionPool = {}
        CC.manifest    = scanMissionFiles()
        for _, filename in ipairs(CC.manifest) do
            local m = CC.loadMission(filename)
            if m then CC.missionPool[#CC.missionPool + 1] = m end
        end
        CC.log("loaded " .. #CC.missionPool .. " mission(s) from missions/")
    end

end
