-- ============================================================================
-- modules/ui.lua  —  the window system
--
-- LAYOUT PHILOSOPHY (anti-clutter): ONE light main window ("Cyberpunk
-- Contracts") that is always available in the overlay: New / Save / Load,
-- mission metadata, and TOGGLE BUTTONS that show/hide every other window.
-- Heavy windows (Object Editor, Quest Hub, Inspector) are off by default.
--
-- Windows:
--   * Main        — metadata + file ops + toggles (this file)
--   * Object Editor — per-object tags/state machine (STUB, fleshed out next)
--   * Quest Hub — mission-wide object list + quest events (selection hub)
--   * Inspector   — live flags/rules (play-mode debugging)
--
-- UNDO: snapshot-based. CC.pushUndo() deep-copies the blueprint BEFORE a
-- structural change; the Undo button restores the latest of up to 5 snapshots.
-- Call pushUndo before adds/deletes/big edits — NOT on every keystroke.
-- ============================================================================

return function(CC)

    -- window visibility toggles (runtime only)
    CC.ui = CC.ui or {
        showVars         = false,
        showPlace        = false,
        showObjectEditor = false,
        showQuestMachine = false,
        showInspector    = false,
        showLifecycle    = false,
    }

    -- ------------------------------------------------------------------------
    -- deep copy (for undo snapshots; mission tables are plain data)
    -- ------------------------------------------------------------------------
    local function deepCopy(t)
        if type(t) ~= "table" then return t end
        local out = {}
        for k, v in pairs(t) do out[k] = deepCopy(v) end
        return out
    end

    -- ------------------------------------------------------------------------
    -- UNDO (last 5 blueprint snapshots)
    -- ------------------------------------------------------------------------
    CC.undoStack = CC.undoStack or {}

    function CC.pushUndo()
        local bp = CC.editor and CC.editor.blueprint
        if not bp then return end
        CC.undoStack[#CC.undoStack + 1] = deepCopy(bp)
        if #CC.undoStack > 5 then table.remove(CC.undoStack, 1) end
    end

    function CC.undo()
        local n = #CC.undoStack
        if n == 0 then CC.log("undo: nothing to undo"); return end
        CC.editor.blueprint = CC.undoStack[n]
        CC.undoStack[n] = nil
        CC.editor.dirty = true
        CC.log("undo: restored snapshot (" .. (n - 1) .. " left)")
    end

    -- ------------------------------------------------------------------------
    -- small helpers
    -- ------------------------------------------------------------------------
    local function inputText(label, value, maxLen)
        local newVal, changed = ImGui.InputText(label, value or "", maxLen or 256)
        if changed then return newVal, true end
        return value, false
    end

    -- every posture an object knows about: base + explicit tabs + any rule's
    -- posture. This derived list IS the posture registry — no free-text names.
    local function collectPostures(e)
        local set, list = {}, {}
        local function add(pn)
            if pn and pn ~= "" and not set[pn] then set[pn] = true; list[#list + 1] = pn end
        end
        add("default")
        add(e.basePosture)
        for _, pn in ipairs(e.postures or {}) do add(pn) end
        for _, ev in ipairs(e.events or {}) do add(ev.posture or "default") end
        return list
    end

    -- [?] help buttons: click to open a popup explaining the window. Keep these
    -- texts current when windows change — they are the in-game manual.
    local function helpButton(id, text)
        ImGui.SameLine()
        if ImGui.SmallButton("?##help_" .. id) then ImGui.OpenPopup("help_" .. id) end
        if ImGui.BeginPopup("help_" .. id) then
            ImGui.PushTextWrapPos(380)
            ImGui.TextColored(0.5, 0.9, 1.0, 1.0, "Help")
            ImGui.Separator()
            ImGui.Text(text)
            ImGui.PopTextWrapPos()
            ImGui.EndPopup()
        end
    end

    local HELP = {
        main = [[Mission hub. The TOP ROW shows/hides the
mod windows (green = open). NEW starts a blank
mission. LOAD picks a saved mission and opens it
for editing. SAVE writes missions/<id>.json and is
only active once a mission is loaded. In the
Mission section: DEPLOY/TEST runs the loaded
mission; DELETE removes its file (asks first).
UNDO (bottom-right) restores the last of 5
blueprint snapshots.]],
        place = [[Creates new objects at V's position,
facing V's heading. The Tag is the object's handle
everywhere (rules, flags, beams) - required and
unique. Zones: Sphere = radius trigger around the
point. Box = room/doorway trigger, base at your
feet rising by Height. NPCs spawn a live neutral
preview immediately.]],
        object = [[Edits the selected object (pick one in
the Quest Hub). NPC: start attitude applies on
deploy (previews are always neutral). Base posture
is the mode the object wakes up in.
POSTURES are tabs - each tab's rules only run
while the object is in that posture. PERSISTENT
rules run in every posture (death reactions live
here). set_posture knocks an object into a mode:
it cancels what it was doing, switches, and
re-arms that posture's rules. A new rule firing
on an object also replaces its current activity
(one activity per object, newest wins).
Amber fields = WHEN. Green fields = DO.
wait pauses a sequence; reorder actions with ^ v.
REPEATS: off = rule fires once. On = it re-arms
after the condition goes false again (so a zone
rule fires once per entry, a timer fires
periodically). Patrol loops need repeats ON.]],
        quest = [[Quest Hub. LEFT pane = the quest's
own phases & rules. RIGHT pane = the object list:
click an object to select it (highlights in-world,
opens the Object Editor on it). Quest-level rules
belong to the mission itself, not an object.]],
        inspector = [[Live mission debugger (play mode).
Shows every flag's current value and each rule's
state: armed (waiting for condition), waiting
(condition met, delay running), fired (done).
Posture flags appear as Label@posture.]],
        lifecycle = [[Quest lifecycle envelope. AUTHORING ONLY
for now - not wired to the engine yet (that's the
next pass). SETUP = actions that run on deploy.
WIN / LOSE = condition groups: the quest completes
(or fails) when ANY group is fully true - all
conditions in a group ANDed, groups ORed. FINALLY
= actions that run at the very end. The condition
rows are the same WHEN picker the rules use.]],
    }

    -- Confirmation gate for destructive actions. Set CC.editor.confirm =
    -- { text = "...", onYes = function() ... end } and the modal does the rest.
    local function drawConfirmModal()
        local c = CC.editor and CC.editor.confirm
        if not c then return end
        ImGui.OpenPopup("CC Confirm")
        if ImGui.BeginPopupModal("CC Confirm", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.TextColored(1.0, 0.6, 0.3, 1.0, c.text or "Are you sure?")
            ImGui.Spacing()
            if ImGui.Button("Yes, do it", 110, 0) then
                local fn = c.onYes
                CC.editor.confirm = nil
                ImGui.CloseCurrentPopup()
                if fn then pcall(fn) end
            end
            ImGui.SameLine()
            if ImGui.Button("Cancel", 110, 0) then
                CC.editor.confirm = nil
                ImGui.CloseCurrentPopup()
            end
            ImGui.EndPopup()
        end
    end

    -- "5" -> 5 (number), "redteam" -> "redteam" (text). One namespace, typed values.
    local function parseValue(txt)
        if txt == nil then return nil end
        local n = tonumber(txt)
        if n ~= nil then return n end
        if txt == "" then return nil end
        return txt
    end

    local function slug(title)
        return (title or "mission"):lower():gsub("%s+", "_"):gsub("[^%w_]", ""):sub(1, 40)
    end

    local OBJECTIVE_TYPES = { "kill_target", "kill_all", "reach_location", "survive" }
    local FIXERS = { "Wakako", "Regina", "Padre", "Dakota", "Rogue", "Mr. Hands", "Dino", "Muamar" }

    -- ========================================================================
    -- MAIN WINDOW (light)
    -- ========================================================================
    local function drawMain()
        -- Structured layout (not auto-resize): a fixed default size you can drag,
        -- so the top window-bar, the Mission section, and the pinned bottom-right
        -- Undo all keep stable positions.
        ImGui.SetNextWindowSize(440, 520, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(380, 460, 900, 1100)  -- CET: verify binding
        ImGui.Begin("Cyberpunk Contracts")

        local bp = CC.editor and CC.editor.blueprint

        -- a toggle button that turns GREEN while its window/flag is ON
        local function toggleBtn(label, isOn, w)
            if isOn then
                ImGui.PushStyleColor(ImGuiCol.Button,        0.16, 0.52, 0.20, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.20, 0.62, 0.25, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive,  0.24, 0.70, 0.30, 1.0)
            end
            local clicked = ImGui.Button(label, w or 0, 0)
            if isOn then ImGui.PopStyleColor(3) end
            return clicked
        end
        -- a button that greys out and ignores clicks when not enabled
        local function gatedBtn(label, enabled, w)
            if not enabled then
                ImGui.PushStyleColor(ImGuiCol.Button,        0.18, 0.18, 0.18, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.18, 0.18, 0.18, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive,  0.18, 0.18, 0.18, 1.0)
                ImGui.PushStyleColor(ImGuiCol.Text,          0.45, 0.45, 0.45, 1.0)
            end
            local clicked = ImGui.Button(label, w or 0, 0)
            if not enabled then ImGui.PopStyleColor(4); clicked = false end
            return clicked
        end

        -- ====================================================================
        -- TOP: window bar (green = open) + help as the final button
        -- ====================================================================
        local barW = 420
        pcall(function()
            local w = ImGui.GetContentRegionAvail()
            if w and w > 0 then barW = w end
        end)
        local bw = math.max(96, math.floor((barW - 16) / 3))   -- 3 buttons per row

        if toggleBtn("Quest Hub",     CC.ui.showQuestMachine, bw) then CC.ui.showQuestMachine = not CC.ui.showQuestMachine end
        ImGui.SameLine()
        if toggleBtn("Lifecycle",     CC.ui.showLifecycle, bw)    then CC.ui.showLifecycle    = not CC.ui.showLifecycle    end
        ImGui.SameLine()
        if toggleBtn("Place Object",  CC.ui.showPlace, bw)        then CC.ui.showPlace        = not CC.ui.showPlace        end

        if toggleBtn("Object Editor", CC.ui.showObjectEditor, bw) then CC.ui.showObjectEditor = not CC.ui.showObjectEditor end
        ImGui.SameLine()
        if toggleBtn("Variables", CC.ui.showVars, bw)      then CC.ui.showVars      = not CC.ui.showVars      end
        ImGui.SameLine()
        if toggleBtn("Inspect",   CC.ui.showInspector, bw) then CC.ui.showInspector = not CC.ui.showInspector end

        if toggleBtn("Debug",     CC.debug, bw)            then CC.debug = not CC.debug end

        -- help: the last button on the top bar, pushed to the right
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, barW - 24))
        if ImGui.SmallButton("?##help_main") then ImGui.OpenPopup("help_main") end
        if ImGui.BeginPopup("help_main") then
            ImGui.PushTextWrapPos(380)
            ImGui.TextColored(0.5, 0.9, 1.0, 1.0, "Help")
            ImGui.Separator()
            ImGui.Text(HELP.main)
            ImGui.PopTextWrapPos()
            ImGui.EndPopup()
        end

        ImGui.Separator()

        -- ====================================================================
        -- MODE + file actions: NEW / SAVE (gated) / LOAD (dropdown)
        -- ====================================================================
        ImGui.TextColored(1.0, 0.8, 0.0, 1.0, "MODE: " .. tostring(CC.mode))
        ImGui.SameLine()
        if ImGui.SmallButton(CC.mode == "editor" and "Exit Editor" or "Enter Editor") then
            CC.mode = (CC.mode == "editor") and "idle" or "editor"
        end

        if ImGui.Button("New") then
            CC.pushUndo()
            if CC.abortMission then CC.abortMission() end   -- despawn + clear activeMission
            CC.editor.blueprint = {
                version = 5, mission_id = "new_mission", title = "New Mission",
                fixer = "Wakako", briefing = "", reward_money = 1000, reward_xp = 250,
                objective = { type = "kill_target" },
                flags = {}, entities = {}, events = {},
                lifecycle = { setup = { actions = {} }, win = { groups = {} },
                              lose = { groups = {} }, finally = { actions = {} } },
            }
            CC.editor.selectedLabel = nil
            CC.editor.dirty = true
            CC.mode = "editor"
            bp = CC.editor.blueprint                        -- reflect immediately this frame
            CC.log("new mission blueprint created")
        end

        -- SAVE is active only once a mission is loaded (New or Load)
        ImGui.SameLine()
        if gatedBtn("Save", bp ~= nil) then
            bp.mission_id = slug(bp.title)
            if CC.saveMission and CC.saveMission(bp) then
                CC.editor.dirty = false
                if CC.loadMissionPool then CC.loadMissionPool() end   -- refresh pool
            end
        end
        if bp and CC.editor.dirty then
            ImGui.SameLine(); ImGui.TextColored(1.0, 0.5, 0.2, 1.0, "*unsaved")
        end

        -- LOAD: pick a saved mission from the dropdown; it opens for editing
        ImGui.SameLine()
        ImGui.SetNextItemWidth(150)
        local _loaded = CC.editor and CC.editor.blueprint and CC.editor.blueprint.title
        local _loadPreview = (_loaded and _loaded ~= "") and _loaded
                             or ("Load  (" .. #(CC.missionPool or {}) .. ")")
        if ImGui.BeginCombo("##load", _loadPreview) then
            local pool = CC.missionPool or {}
            if #pool == 0 then
                ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "(no saved missions)")
            else
                for i, m in ipairs(pool) do
                    local name = m.title or m.mission_id or ("mission " .. i)
                    if ImGui.Selectable(name .. "##load" .. i) then
                        CC.pushUndo()
                        if CC.abortMission then CC.abortMission() end
                        CC.editor.blueprint = deepCopy(m)   -- edit a copy; Save writes it back
                        CC.editor.selectedLabel = nil
                        CC.editor.dirty = false
                        CC.mode = "editor"
                        if CC.spawnEditorPreviews then CC.spawnEditorPreviews() end
                        bp = CC.editor.blueprint
                        CC.log("loaded: " .. name)
                    end
                end
            end
            ImGui.Separator()
            if ImGui.Selectable("rescan disk") and CC.loadMissionPool then CC.loadMissionPool() end
            ImGui.EndCombo()
        end

        -- ====================================================================
        -- MISSION — metadata for the loaded mission (clearly separated)
        -- ====================================================================
        ImGui.Separator()
        if not bp then
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "No mission loaded.")
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "New starts one; Load opens a saved one.")
        else
            ImGui.TextColored(0.5, 0.9, 1.0, 1.0, "Mission")
            local ch
            bp.title,    ch = inputText("Title", bp.title);            if ch then CC.editor.dirty = true end
            bp.briefing, ch = inputText("Briefing", bp.briefing, 512); if ch then CC.editor.dirty = true end

            if ImGui.BeginCombo("Fixer", bp.fixer or "Wakako") then
                for _, f in ipairs(FIXERS) do
                    if ImGui.Selectable(f, f == bp.fixer) and f ~= bp.fixer then bp.fixer = f; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end

            bp.objective = bp.objective or { type = "kill_target" }
            if ImGui.BeginCombo("Objective", bp.objective.type or "kill_target") then
                for _, o in ipairs(OBJECTIVE_TYPES) do
                    if ImGui.Selectable(o, o == bp.objective.type) and o ~= bp.objective.type then
                        bp.objective.type = o; CC.editor.dirty = true
                    end
                end
                ImGui.EndCombo()
            end

            local v, c
            v, c = ImGui.InputInt("Reward $", bp.reward_money or 0);  if c then bp.reward_money = v; CC.editor.dirty = true end
            v, c = ImGui.InputInt("Reward XP", bp.reward_xp or 0);    if c then bp.reward_xp = v;   CC.editor.dirty = true end

            ImGui.Spacing()
            -- DELETE removes the mission's saved file (deploy/abort live in Mission Control below)
            ImGui.PushStyleColor(ImGuiCol.Button,        0.55, 0.12, 0.12, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.66, 0.16, 0.16, 1.0)
            if ImGui.Button("Delete") then
                local delTitle = bp.title or bp.mission_id or "this mission"
                local delFile  = ((bp.mission_id and bp.mission_id ~= "") and bp.mission_id or slug(bp.title)) .. ".json"
                CC.editor.confirm = {
                    text = "Delete saved mission '" .. delTitle .. "'?\n" ..
                           "Removes missions/" .. delFile .. " from disk.\n" ..
                           "Undo will NOT bring it back.",
                    onYes = function()
                        if CC.deleteMission then CC.deleteMission(delFile) end
                    end,
                }
            end
            ImGui.PopStyleColor(2)
        end

        -- ====================================================================
        -- ACTIVE mission control (play mode)
        -- ====================================================================
        -- MISSION CONTROL: Deploy when idle, big red ABORT while a mission is running
        local _cbp = CC.editor and CC.editor.blueprint
        if CC.activeMission then
            ImGui.Separator()
            ImGui.TextColored(1.0, 0.85, 0.2, 1.0, "Running Mission: " .. (CC.activeMission.title or "?"))
            ImGui.PushStyleColor(ImGuiCol.Button,        0.70, 0.10, 0.10, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.86, 0.16, 0.16, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive,  0.60, 0.08, 0.08, 1.0)
            if ImGui.Button("ABORT MISSION", 240, 40) and CC.abortMission then CC.abortMission() end
            ImGui.PopStyleColor(3)
        elseif _cbp then
            ImGui.Separator()
            if ImGui.Button("Deploy / Test", 240, 32) and CC.deployMission then
                CC.deployMission(deepCopy(_cbp))   -- deepCopy so runtime never mutates the blueprint
            end
            ImGui.SameLine()
            if ImGui.SmallButton("Refresh objects") and CC.refreshPreviews then CC.refreshPreviews() end
        end

        -- ====================================================================
        -- UNDO — pinned bottom-right, orange, bigger; greyed when nothing to undo
        -- ====================================================================
        do
            local canUndo = (#(CC.undoStack or {}) > 0)
            local uW, uH = 96, 30
            local winW = ImGui.GetWindowWidth()
            local winH = ImGui.GetWindowHeight()
            ImGui.SetCursorPosY(math.max(ImGui.GetCursorPosY(), winH - uH - 12))
            ImGui.SetCursorPosX(math.max(8, winW - uW - 14))
            if canUndo then
                ImGui.PushStyleColor(ImGuiCol.Button,        0.85, 0.45, 0.10, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.95, 0.55, 0.15, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive,  1.00, 0.62, 0.20, 1.0)
                if ImGui.Button("Undo", uW, uH) then CC.undo() end
                ImGui.PopStyleColor(3)
            else
                ImGui.PushStyleColor(ImGuiCol.Button,        0.30, 0.22, 0.12, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.30, 0.22, 0.12, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive,  0.30, 0.22, 0.12, 1.0)
                ImGui.PushStyleColor(ImGuiCol.Text,          0.6, 0.55, 0.5, 1.0)
                ImGui.Button("Undo", uW, uH)
                ImGui.PopStyleColor(4)
            end
        end

        ImGui.End()
    end

    -- ========================================================================
    -- PLACE PALETTE — create new objects, dropped at V's position + facing.
    -- The label is the human handle for the whole system: required and unique.
    -- ========================================================================
    local PLACE_TYPES = { "Zone", "NPC", "Device" }
    local NPC_RECORDS = {                    -- starter list; grows from your catalog
        "Character.q001_scavenger_shotgun3",
        "(custom...)",
    }
    local place = { type = "Zone", label = "", record = NPC_RECORDS[1],
                    custom = "", shape = "Sphere", radius = 3.0,
                    sx = 4.0, sy = 4.0, sz = 3.0, err = nil }

    local function labelTaken(bp, label)
        for _, e in ipairs(bp.entities or {}) do
            if e.label == label then return true end
        end
        return false
    end

    -- ---- NPC record browser: search + faction filter over CC.npcRecords --------
    local NPC_FACTIONS = {
        { "All", {} }, { "Scav", { "scavenger" } }, { "Maelstrom", { "maelstrom" } },
        { "Tyger", { "tyger" } }, { "Valentino", { "valentino" } }, { "Voodoo", { "voodoo" } },
        { "Animals", { "animal" } }, { "Mox", { "mox" } }, { "6th St", { "sixth", "6th" } },
        { "Wraith", { "wraith" } }, { "Aldecaldo", { "aldecaldo" } }, { "Arasaka", { "arasaka" } },
        { "Militech", { "militech" } }, { "Kang Tao", { "kangtao", "kang_tao" } }, { "NCPD", { "ncpd" } },
        { "MaxTac", { "max_tac", "maxtac" } }, { "Netwatch", { "netwatch" } }, { "Trauma", { "trauma" } },
        { "Corpo", { "corpo" } },
    }
    local npcSearch, npcFaction = "", 1

    local function npcMatches(item)
        local fac = NPC_FACTIONS[npcFaction]
        if fac and #fac[2] > 0 then
            local low, hit = item.record:lower(), false
            for _, k in ipairs(fac[2]) do if low:find(k, 1, true) then hit = true; break end end
            if not hit then return false end
        end
        if npcSearch ~= "" then
            local q = npcSearch:lower()
            if not (item.name:lower():find(q, 1, true) or item.record:lower():find(q, 1, true)) then return false end
        end
        return true
    end

    -- Renders the browser popup (when open); calls onPick(record) on a selection.
    -- Searchable picker over CC.fxLibrary (the 1639 world-FX resource paths).
    local fxSearch = ""
    local function fxBrowserPopup(popupId, onPick)
        if not ImGui.BeginPopup(popupId) then return end
        local lib = CC.fxLibrary or {}
        ImGui.Text("Search " .. #lib .. " world-FX resources")
        ImGui.SetNextItemWidth(440)
        fxSearch = select(1, ImGui.InputText("##fxsearch", fxSearch, 96))
        ImGui.SameLine()
        if ImGui.SmallButton("clear##fxsclr") then fxSearch = "" end
        ImGui.Separator()
        ImGui.BeginChild("fxlist", 470, 340, true)
        if #lib == 0 then
            ImGui.TextColored(0.85, 0.5, 0.4, 1.0, "FX catalog not loaded.")
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "add modules/fxdata and register it in init.lua")
        else
            local q, shown = fxSearch:lower(), 0
            for _, path in ipairs(lib) do
                if q == "" or path:lower():find(q, 1, true) then
                    shown = shown + 1
                    if shown <= 300 then
                        local base = path:match("([^\\]+)$") or path
                        if ImGui.Selectable(base .. "##" .. path) then
                            onPick(path); ImGui.CloseCurrentPopup()
                        end
                    end
                end
            end
            if shown == 0 then ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "no matches") end
            if shown > 300 then ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "...refine search (" .. shown .. " matches)") end
        end
        ImGui.EndChild()
        ImGui.EndPopup()
    end

    local function npcBrowserPopup(popupId, onPick)
        if not ImGui.BeginPopup(popupId) then return end
        local recs = CC.npcRecords or {}
        ImGui.Text("Search " .. #recs .. " NPC records (name or record path)")
        ImGui.SetNextItemWidth(330)
        npcSearch = select(1, ImGui.InputText("##npcsearch", npcSearch, 64))
        ImGui.SameLine()
        if ImGui.SmallButton("clear##npcsclr") then npcSearch = "" end
        for i, fac in ipairs(NPC_FACTIONS) do
            if (i - 1) % 6 ~= 0 then ImGui.SameLine() end
            local on = (npcFaction == i)
            if on then ImGui.PushStyleColor(ImGuiCol.Button, 0.20, 0.45, 0.70, 1.0) end
            if ImGui.SmallButton(fac[1] .. "##fac" .. i) then npcFaction = i end
            if on then ImGui.PopStyleColor(1) end
        end
        ImGui.Separator()
        ImGui.BeginChild("npclist", 380, 320, true)
        if #recs == 0 then
            ImGui.TextColored(0.85, 0.5, 0.4, 1.0, "NPC catalog not loaded.")
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "add modules/npcdata and register it in init.lua")
        else
            local shown = 0
            for _, item in ipairs(recs) do
                if npcMatches(item) then
                    shown = shown + 1
                    -- prevention / MaxTac / NetWatch are system-spawned response units: the
                    -- crime-response AI re-claims the body, so they ignore move/patrol/face/follow.
                    local rl = item.record:lower()
                    local sysAI = rl:find("prevention", 1, true) or rl:find("maxtac", 1, true)
                                  or rl:find("netwatch", 1, true)
                    local tag = sysAI and "   [system AI]" or ""
                    if ImGui.Selectable(item.name .. "  ::  " .. item.record .. tag .. "##" .. item.record) then
                        onPick(item.record); ImGui.CloseCurrentPopup()
                    end
                    if sysAI and ImGui.IsItemHovered() then
                        ImGui.SetTooltip("Obeys freeze / hide / status / immortal, but move, patrol, face\n" ..
                            "and follow revert to police behavior. Use a non-prevention model\n" ..
                            "(Arasaka / Militech / corpo security / gangers) if you need to command it.")
                    end
                end
            end
            if shown == 0 then ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "no matches") end
        end
        ImGui.EndChild()
        ImGui.EndPopup()
    end

    local function drawPlace()
        ImGui.Begin("CC - Place Object", ImGuiWindowFlags.AlwaysAutoResize)
        helpButton("place", HELP.place)
        local bp = CC.editor and CC.editor.blueprint
        if not bp then
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "no blueprint (New or Load first)")
            ImGui.End(); return
        end

        -- type
        if ImGui.BeginCombo("Type", place.type) then
            for _, t in ipairs(PLACE_TYPES) do
                if ImGui.Selectable(t, t == place.type) and t ~= place.type then place.type = t end
            end
            ImGui.EndCombo()
        end

        -- label (the human handle — required, unique)
        place.label = select(1, ImGui.InputText("Tag / Label", place.label, 64))

        -- type-specific fields
        if place.type == "NPC" then
            ImGui.Text("Record: " .. tostring(place.record))
            if ImGui.Button("Browse " .. #(CC.npcRecords or {}) .. " NPCs##npcbrowse") then
                ImGui.OpenPopup("NPC Browser")
            end
            ImGui.SameLine()
            if ImGui.Button((place.record == "(custom...)") and "use list##npctog" or "custom##npctog") then
                if place.record == "(custom...)" then
                    place.record = (CC.npcRecords and CC.npcRecords[1] and CC.npcRecords[1].record)
                                   or "Character.q001_scavenger_shotgun3"
                else
                    place.record = "(custom...)"
                end
            end
            if place.record == "(custom...)" then
                place.custom = select(1, ImGui.InputText("Custom record", place.custom, 128))
            end
            npcBrowserPopup("NPC Browser", function(rec) place.record = rec end)
        elseif place.type == "Device" then
            ImGui.TextColored(0.7, 0.8, 0.9, 1.0, "Aim at a door / device, name it,")
            ImGui.TextColored(0.7, 0.8, 0.9, 1.0, "then Bind. Re-found by position at deploy.")
        else
            if ImGui.BeginCombo("Shape", place.shape) then
                for _, sh in ipairs({ "Sphere", "Box" }) do
                    if ImGui.Selectable(sh, sh == place.shape) and sh ~= place.shape then place.shape = sh end
                end
                ImGui.EndCombo()
            end
            local v, c
            if place.shape == "Box" then
                v, c = ImGui.InputFloat("Size X (m)", place.sx); if c then place.sx = v end
                v, c = ImGui.InputFloat("Size Y (m)", place.sy); if c then place.sy = v end
                v, c = ImGui.InputFloat("Height (m)", place.sz); if c then place.sz = v end
            else
                v, c = ImGui.InputFloat("Radius", place.radius); if c then place.radius = v end
            end
        end

        -- drop
        if ImGui.Button(place.type == "Device" and "Bind to crosshair" or "Drop at V") then
            place.err = nil
            local label = (place.label or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local record = (place.record == "(custom...)") and place.custom or place.record
            if label == "" then
                place.err = "label required — it's the handle for everything"
            elseif labelTaken(bp, label) then
                place.err = "label '" .. label .. "' already used"
            elseif place.type == "NPC" and (not record or record == "") then
                place.err = "record required"
            else
                local p = CC.worldPos(Game.GetPlayer())
                local fwd = nil
                pcall(function() fwd = Game.GetPlayer():GetWorldForward() end)
                local fx, fy = (fwd and fwd.x) or 1.0, (fwd and fwd.y) or 0.0
                local mag = math.sqrt(fx * fx + fy * fy)
                if mag < 0.01 then fx, fy = 1.0, 0.0 else fx, fy = fx / mag, fy / mag end

                if p then
                    local e = nil
                    local ok = true
                    if place.type == "Zone" then
                        if place.shape == "Box" then
                            e = { action = "zone", shape = "box", label = label,
                                  x = p.x, y = p.y, z = p.z,
                                  sx = place.sx, sy = place.sy, sz = place.sz }
                        else
                            e = { action = "zone", shape = "sphere", label = label,
                                  x = p.x, y = p.y, z = p.z, radius = place.radius }
                        end
                    elseif place.type == "Device" then
                        -- BIND the world object under the crosshair (shared capture
                        -- path with the bind hotkey -- one definition, no drift).
                        e, place.err = CC.captureDevice(label)
                        if not e then ok = false end
                    else
                        e = { id = record, label = label,
                              x = p.x, y = p.y, z = p.z,
                              fwd_x = fx, fwd_y = fy,           -- faces V's heading
                              startAttitude = "neutral" }
                        -- live preview so you see the body immediately
                        if CC.spawnRecord then
                            CC.spawnRecord({ id = record, label = label,
                                x = p.x, y = p.y, z = p.z, fwd_x = fx, fwd_y = fy,
                                startAttitude = "neutral" })
                        end
                    end
                    if ok and e then
                        CC.pushUndo()
                        bp.entities = bp.entities or {}
                        bp.entities[#bp.entities + 1] = e
                        CC.editor.dirty = true
                        CC.editor.selectedLabel = label
                        place.label = ""
                        CC.log("placed " .. place.type .. " '" .. label .. "'")
                    end
                end
            end
        end
        if place.err then ImGui.TextColored(1.0, 0.3, 0.3, 1.0, place.err) end

        ImGui.End()
    end

    -- ========================================================================
    -- SHARED RULE EDITOR — the posture tabs + rules + actions, for ANY machine.
    -- holder: the table with .events/.postures/.basePosture (an entity def, or
    -- the blueprint itself for the quest). ownerLabel: the machine's identity
    -- ("quest" for the mission). Used by the Object Editor AND Quest Hub —
    -- one editor, two owners, zero drift.
    -- ========================================================================
    -- ========================================================================
    -- SHARED CONDITION/ACTION ROW EDITORS
    -- One source of truth for the WHEN picker (amber) and the DO picker (green).
    -- Used by the rules editor (per-object) AND the lifecycle window (quest).
    -- Stored keys stay stable (saved missions never break); the editor shows the
    -- clear display names. "V" = player, "target" = watched object.
    -- ========================================================================
    local WHENS = { "on_enter", "posture", "inside", "dies", "health", "proximity",
                    "aggro", "flag", "timer", "interacted", "all_dead" }
    local RULE_WHENS = WHENS                          -- per-object rules: all of them
    local COND_WHENS = { "dies", "health", "proximity", "inside", "aggro", "all_dead",  -- lifecycle win/lose:
                         "flag", "timer", "interacted", "posture" }            -- no on_enter (rule-only)
    -- `repeats` re-fires only when a condition goes FALSE then TRUE again. These hold
    -- their state once true -- death is permanent; a flag keeps its value -- so repeats
    -- can never re-fire on them. Grey it out instead of letting it silently no-op.
    local NO_REPEAT = { dies = true, all_dead = true, flag = true }
    local WHEN_LBL = {
        on_enter   = "initial action",
        posture    = "posture check (other)",
        inside     = "target inside zone",
        dies       = "target dies",
        health     = "target health below %",
        proximity  = "V near target",
        aggro      = "target turns hostile",
        flag       = "flag equals",
        timer      = "timer elapsed",
        interacted = "V interacts with target",
        all_dead   = "all enemies dead",
    }
    local DOS   = { "speak", "set_attitude", "move_to", "face", "follow_player",
                    "stop_move", "hold", "look_at", "stop_look", "follow", "draw_weapon", "attack", "set_immortal",
                    "set_patrol", "wait", "set_posture", "set_flag",
                    "add_effect", "remove_effect", "play_fx", "explode", "apply_status", "remove_status",
                    "open", "quest_close", "lock", "unlock", "enable", "disable", "dispose",
                    "freeze", "unfreeze", "hide", "unhide",
                    "trigger", "complete", "fail" }
    local DO_LBL = {
        speak         = "say text",
        set_attitude  = "set attitude",
        move_to       = "walk to",
        face          = "face toward",
        follow_player = "follow V",
        stop_move     = "stop moving",
        set_patrol    = "patrol (walk a loop)",
        wait          = "wait (seconds)",
        set_posture   = "set posture",
        set_flag      = "set flag",
        hold          = "hold position (stay)",
        look_at       = "look at (head/eyes)",
        stop_look     = "stop looking",
        follow        = "follow target",
        draw_weapon   = "draw weapon",
        attack        = "attack target",
        set_immortal  = "set immortal",
        add_effect    = "VFX on NPC (follows)",
        remove_effect = "stop VFX on NPC",
        play_fx       = "world FX at point",
        explode       = "explode (FX + AoE dmg)",
        apply_status  = "apply status (fire/stun)",
        remove_status = "remove status",
        open          = "door: open",
        quest_close   = "door: close",
        lock          = "door: lock",
        unlock        = "door: unlock",
        enable        = "device: power on",
        disable       = "device: power off",
        dispose       = "destroy object (unstable)",
        freeze        = "freeze (stop in place)",
        unfreeze      = "unfreeze",
        hide          = "hide (make invisible)",
        unhide        = "unhide",
        trigger       = "fire another rule",
        complete      = "mission: complete",
        fail          = "mission: fail",
    }
    local ATTITUDES = { "hostile", "neutral", "friendly" }
    -- Quick-pick of confirmed-useful VFX names (full set lives in vfx_catalog.md).
    local FX_PICKS = { "status_burning", "status_electrocuted", "status_emp", "igni",
                       "status_smoke_bomb", "empExplosionDestruction", "w_expl_blackwall_shortcircuit",
                       "mask_explode", "black_wall", "glitch", "berserk", "optical_camo" }
    local STATUS_PICKS = { "BaseStatusEffect.BaseOverheat", "BaseStatusEffect.Bleeding",
                           "BaseStatusEffect.BaseEMP", "BaseStatusEffect.Stun", "BaseStatusEffect.Knockdown",
                           "BaseStatusEffect.SmokeBomb", "BaseStatusEffect.BerserkNPCBuff",
                           "BaseStatusEffect.Blind", "BaseStatusEffect.SandstormAbstract" }
    local WORLD_FX_PICKS = {
        { "base\\fx\\devices\\fuel_dispener\\d_fuel_dispener_explosion_001.effect", "explosion (fuel)" },
        { "base\\fx\\devices\\explosive_server\\d_explosive_server_explosion.effect", "explosion (server)" },
        { "base\\fx\\devices\\explosive_tank\\d_explosive_tank_gas_flames.effect", "fire (gas tank)" },
        { "base\\fx\\characters\\boss_cyberninja\\ch_cyberninja_mask_explode.effect", "explosion (mask)" },
        { "base\\fx\\characters\\npc\\_common\\status_burning.effect", "burning" },
        { "base\\fx\\characters\\boss_animals\\hammer\\hammer_throw_ground_smoke.effect", "ground smoke" },
    }

    -- label dropdown. selfLabel (the owning object) is pinned at the top in gold.
    local function labelCombo(id, current, selfLabel, bp, extra)
        local labels = {}
        for _, ent2 in ipairs(bp.entities or {}) do
            if ent2.label then labels[#labels + 1] = ent2.label end
        end
        local shown = current or "(pick)"
        if current and current == selfLabel then shown = "(*) " .. current end
        if ImGui.BeginCombo(id, shown) then
            if selfLabel then
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.85, 0.3, 1.0)
                if ImGui.Selectable("(*) " .. selfLabel, current == selfLabel) and current ~= selfLabel then
                    current = selfLabel; CC.editor.dirty = true
                end
                ImGui.PopStyleColor(1)
            end
            if extra then
                for _, x in ipairs(extra) do
                    if ImGui.Selectable(x, x == current) and x ~= current then current = x; CC.editor.dirty = true end
                end
            end
            for _, l in ipairs(labels) do
                if l ~= selfLabel then
                    if ImGui.Selectable(l, l == current) and l ~= current then current = l; CC.editor.dirty = true end
                end
            end
            ImGui.EndCombo()
        end
        return current
    end

    -- WHEN row (amber): the condition picker + its fields for one table `ev`.
    -- opts = { whens=<list>, postureContext=<pname|nil>, showRepeats=<bool> }
    local function drawWhenRow(ev, idtag, bp, ownerLabel, opts)
        opts = opts or {}
        local whens = opts.whens or WHENS
        ImGui.PushStyleColor(ImGuiCol.FrameBg,        0.42, 0.30, 0.08, 0.75)
        ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, 0.55, 0.40, 0.12, 0.85)
        ImGui.PushStyleColor(ImGuiCol.Text,           0.95, 0.85, 0.55, 1.0)

        local when = ev.when or ev.condition or "dies"
        if ImGui.BeginCombo("when##w" .. idtag, WHEN_LBL[when] or when) then
            for _, w in ipairs(whens) do
                if ImGui.Selectable(WHEN_LBL[w] or w, w == when) and w ~= when then ev.when = w; CC.editor.dirty = true end
            end
            ImGui.EndCombo()
        end
        when = ev.when or ev.condition or "dies"

        if when == "on_enter" then
            local pname = opts.postureContext
            if pname == nil or pname == "persistent" then
                ImGui.TextColored(1.0, 0.5, 0.3, 1.0, "on_enter fires once at deploy")
                ImGui.TextColored(1.0, 0.5, 0.3, 1.0, "(move it to a posture tab to scope it).")
            else
                ImGui.TextColored(0.75, 0.65, 0.4, 1.0,
                    "runs first, when (*) " .. tostring(ownerLabel) .. " enters '" .. pname .. "'")
            end
        elseif when == "posture" then
            ev.watch = labelCombo("watch##wa" .. idtag, ev.watch, ownerLabel, bp)
            local tdef2 = nil
            for _, ent5 in ipairs(bp.entities or {}) do
                if ent5.label == ev.watch then tdef2 = ent5 break end
            end
            local curp = ev.in_posture or "(pick)"
            if ImGui.BeginCombo("in posture##ip" .. idtag, curp) then
                if tdef2 then
                    for _, pn3 in ipairs(collectPostures(tdef2)) do
                        if ImGui.Selectable(pn3, pn3 == ev.in_posture) and pn3 ~= ev.in_posture then
                            ev.in_posture = pn3; CC.editor.dirty = true
                        end
                    end
                end
                ImGui.EndCombo()
            end
        elseif when == "inside" then
            ev.watch = labelCombo("who moves##im" .. idtag, ev.watch, ownerLabel, bp)
            ev.zone  = labelCombo("zone##iz" .. idtag, ev.zone, nil, bp)
        elseif when == "dies" or when == "proximity" or when == "aggro" or when == "interacted" then
            ev.watch = labelCombo("watch##wa" .. idtag, ev.watch, ownerLabel, bp)
        elseif when == "health" then
            ev.watch = labelCombo("watch##wa" .. idtag, ev.watch, ownerLabel, bp)
            local hv, hc = ImGui.InputFloat("below %##hp" .. idtag, ev.below or 50.0)
            if hc then ev.below = hv; CC.editor.dirty = true end
            ImGui.TextColored(0.70, 0.62, 0.42, 1.0, "fires once when HP drops past this (allows repeats)")
        elseif when == "flag" then
            local ch
            ev.flag, ch = inputText("variable##fk" .. idtag, ev.flag); if ch then CC.editor.dirty = true end
            local OPS = { "eq", "ne", "gt", "lt", "ge", "le" }
            local OP_LBL = { eq = "=", ne = "not =", gt = ">", lt = "<", ge = ">=", le = "<=" }
            local curop = ev.op or "eq"
            if ImGui.BeginCombo("is##op" .. idtag, OP_LBL[curop] or curop) then
                for _, o in ipairs(OPS) do
                    if ImGui.Selectable(OP_LBL[o], o == curop) and o ~= curop then ev.op = o; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end
            local mode = (ev.other and ev.other ~= "") and "variable" or "value"
            if ImGui.BeginCombo("compare to##cm" .. idtag, mode) then
                if ImGui.Selectable("value", mode == "value") and mode ~= "value" then ev.other = nil; CC.editor.dirty = true end
                if ImGui.Selectable("variable", mode == "variable") and mode ~= "variable" then ev.other = ev.other or ""; CC.editor.dirty = true end
                ImGui.EndCombo()
            end
            if ev.other ~= nil then
                ev.other, ch = inputText("other variable##ov" .. idtag, ev.other)
                if ch then CC.editor.dirty = true end
            else
                local vt
                vt, ch = inputText("value##vv" .. idtag,
                    ev.value ~= nil and tostring(ev.value) or (ev.eq ~= nil and tostring(ev.eq) or ""))
                if ch then ev.value = parseValue(vt); ev.eq = nil; CC.editor.dirty = true end
            end
        elseif when == "timer" then
            local v, c = ImGui.InputFloat("after (s)##af" .. idtag, ev.after or ev.delay or 5.0)
            if c then ev.after = v; CC.editor.dirty = true end
        end
        if opts.showRepeats then
            if NO_REPEAT[when] then
                -- condition holds once true -> repeats can't re-fire. Clear any stale
                -- checked value (it was a silent no-op) and render it disabled.
                if ev.repeats then ev.repeats = nil; CC.editor.dirty = true end
                local dis = (ImGui.BeginDisabled ~= nil)
                if dis then ImGui.BeginDisabled(true) end
                ImGui.Checkbox("repeats##rp" .. idtag, false)
                if dis then ImGui.EndDisabled() end
                ImGui.SameLine()
                ImGui.TextColored(0.70, 0.62, 0.42, 1.0,
                    "n/a: '" .. (WHEN_LBL[when] or when) .. "' stays true -- use 'timer' to loop")
            else
                local rv, rc = ImGui.Checkbox("repeats##rp" .. idtag, ev.repeats == true)
                if rc then ev.repeats = rv or nil; CC.editor.dirty = true end
            end
        end
        ImGui.PopStyleColor(3)
    end

    -- DO verb dropdown (shares a line with reorder/remove controls in the caller).
    -- Action category -> color, so the DO list reads in groups instead of one wall
    -- of green: NPC behavior / entity effects / state-machine flow / world+device /
    -- quest lifecycle. New verbs default to "npc" until categorized here.
    local DO_CAT = {
        speak="npc", set_attitude="npc", move_to="npc", face="npc", follow_player="npc",
        stop_move="npc", hold="npc", look_at="npc", stop_look="npc", follow="npc",
        draw_weapon="npc", attack="npc", set_patrol="npc",
        add_effect="effect", remove_effect="effect", apply_status="effect", remove_status="effect",
        freeze="effect", unfreeze="effect", hide="effect", unhide="effect",
        set_immortal="effect", dispose="effect",
        set_posture="flow", set_flag="flow", wait="flow", trigger="flow",
        play_fx="world", explode="world", open="world", quest_close="world",
        lock="world", unlock="world", enable="world", disable="world",
        complete="quest", fail="quest",
    }
    local CAT_COL = {
        npc    = { 0.50, 0.72, 1.00 },
        effect = { 0.40, 0.88, 0.88 },
        flow   = { 0.80, 0.58, 1.00 },
        world  = { 0.55, 0.90, 0.50 },
        quest  = { 1.00, 0.78, 0.35 },
    }
    local function catColor(verb)
        local c = CAT_COL[DO_CAT[verb] or "npc"]
        return c[1], c[2], c[3]
    end

    -- Clone-posture popup state + the copy itself. Collects copies BEFORE deleting
    -- the destination rules, so cloning a posture into itself is harmless. Self-
    -- references (labels pointing at the SOURCE object) are retargeted to the
    -- destination, so "copy this guard's behavior onto that guard" just works.
    local clonePopup = nil
    local function postureMatch(evp, pname)
        if pname == "persistent" then return evp == nil end
        return evp == pname
    end
    local function clonePostureInto(holder, pname, srcE, srcPosture, ownerLabel)
        local copies = {}
        for _, ev in ipairs(srcE.events or {}) do
            if postureMatch(ev.posture, srcPosture) then copies[#copies + 1] = deepCopy(ev) end
        end
        CC.pushUndo()
        for i = #holder.events, 1, -1 do
            if postureMatch(holder.events[i].posture, pname) then table.remove(holder.events, i) end
        end
        local srcLabel, n = srcE.label, 0
        for _, copy in ipairs(copies) do
            copy.posture = (pname ~= "persistent") and pname or nil
            n = n + 1
            copy.id = (ownerLabel or "obj") .. "_rule" .. (#holder.events + 1)
            if ownerLabel and srcLabel and ownerLabel ~= srcLabel then
                for _, key in ipairs({ "watch", "target", "at", "zone" }) do
                    if copy[key] == srcLabel then copy[key] = ownerLabel end
                end
                for _, act in ipairs(copy.actions or {}) do
                    for _, key in ipairs({ "target", "at", "watch" }) do
                        if act[key] == srcLabel then act[key] = ownerLabel end
                    end
                end
            end
            holder.events[#holder.events + 1] = copy
        end
        CC.editor.dirty = true
        CC.log(string.format("cloned %d rule(s) from %s '%s' into '%s'", n, tostring(srcLabel), tostring(srcPosture), tostring(pname)))
    end

    local function drawVerbCombo(a, idtag)
        local verb = a["do"] or a.action or "speak"
        local cr, cg, cb = catColor(verb)
        ImGui.PushStyleColor(ImGuiCol.FrameBg,        cr * 0.26, cg * 0.30, cb * 0.30, 0.80)
        ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, cr * 0.42, cg * 0.46, cb * 0.46, 0.90)
        if ImGui.BeginCombo("##verb" .. idtag, DO_LBL[verb] or verb) then
            for _, d in ipairs(DOS) do
                if ImGui.Selectable(DO_LBL[d] or d, d == verb) and d ~= verb then a["do"] = d; a.action = nil; CC.editor.dirty = true end
            end
            ImGui.EndCombo()
        end
        ImGui.PopStyleColor(2)
    end

    -- DO fields (green): the per-verb parameter widgets for one action `a`.
    -- holderEvents = the rule list whose ids `trigger` can point at.
    local function drawDoFields(a, idtag, bp, ownerLabel, holderEvents)
        local labels = {}
        for _, ent in ipairs(bp.entities or {}) do
            if ent.label then labels[#labels + 1] = ent.label end
        end
        local verb = a["do"] or a.action or "speak"
        ImGui.Indent(14)
        local wid = idtag
        if verb == "speak" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            local ch
            a.text, ch = inputText("text##" .. wid, a.text, 256); if ch then CC.editor.dirty = true end
        elseif verb == "set_attitude" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp, { "all_npcs" })
            -- materialize the default so "shown" == "stored": a bare combo only
            -- writes on a CHANGE, so the displayed default would otherwise never be
            -- saved and the action would go out with attitude = nil.
            a.attitude = a.attitude or "hostile"
            if ImGui.BeginCombo("attitude##" .. wid, a.attitude) then
                for _, t2 in ipairs(ATTITUDES) do
                    if ImGui.Selectable(t2, t2 == a.attitude) and t2 ~= a.attitude then a.attitude = t2; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end
        elseif verb == "move_to" then
            a.target      = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            a.destination = labelCombo("to##" .. wid, a.destination, ownerLabel, bp)
            local fshown = a.face or "(none)"
            if ImGui.BeginCombo("arrive facing##" .. wid, fshown) then
                if ImGui.Selectable("(none)", a.face == nil) and a.face ~= nil then a.face = nil; CC.editor.dirty = true end
                if ImGui.Selectable("V", a.face == "V") and a.face ~= "V" then a.face = "V"; CC.editor.dirty = true end
                for _, l in ipairs(labels) do
                    if ImGui.Selectable(l, l == a.face) and l ~= a.face then a.face = l; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end
        elseif verb == "face" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            a.at     = labelCombo("face##" .. wid, a.at, nil, bp, { "V" })
        elseif verb == "follow_player" or verb == "stop_move" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
        elseif verb == "hold" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            local hv, hc = ImGui.InputFloat("seconds##" .. wid, a.duration or 8.0)
            if hc then a.duration = hv; CC.editor.dirty = true end
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "resumes after; use a big number to stay put")
        elseif verb == "attack" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            a.at     = labelCombo("attacks##" .. wid, a.at, nil, bp, { "V" })
        elseif verb == "look_at" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            a.at     = labelCombo("looks at##" .. wid, a.at, nil, bp, { "V" })
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "head/eyes glance -- use 'face' to turn the whole body")
        elseif verb == "follow" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            a.at     = labelCombo("follows##" .. wid, a.at, nil, bp, { "V" })
            local rv, rc = ImGui.Checkbox("run##" .. wid, a.run == true)
            if rc then a.run = rv; CC.editor.dirty = true end
        elseif verb == "draw_weapon" or verb == "stop_look" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
        elseif verb == "set_immortal" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            local iv, ic = ImGui.Checkbox("immortal##" .. wid, a.immortal ~= false)
            if ic then a.immortal = iv; CC.editor.dirty = true end
        elseif verb == "set_patrol" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            a.nodes = a.nodes or {}
            local lv, lc = ImGui.Checkbox("loop##" .. wid, a.loop ~= false)
            if lc then a.loop = lv; CC.editor.dirty = true end
            ImGui.SameLine()
            local rv, rc = ImGui.Checkbox("run##" .. wid, a.run == true)
            if rc then a.run = rv or nil; CC.editor.dirty = true end
            local rmN, mf, mt = nil, nil, nil
            for k = 1, #a.nodes do
                ImGui.PushID("pnode" .. k)
                a.nodes[k] = labelCombo("node " .. k .. "##" .. wid, a.nodes[k], nil, bp)
                ImGui.SameLine()
                if ImGui.SmallButton("^") and k > 1 then mf, mt = k, k - 1 end
                ImGui.SameLine()
                if ImGui.SmallButton("v") and k < #a.nodes then mf, mt = k, k + 1 end
                ImGui.SameLine()
                if ImGui.SmallButton("x") then rmN = k end
                ImGui.PopID()
            end
            if mf then a.nodes[mf], a.nodes[mt] = a.nodes[mt], a.nodes[mf]; CC.editor.dirty = true end
            if rmN then table.remove(a.nodes, rmN); CC.editor.dirty = true end
            if ImGui.SmallButton("+ node##" .. wid) then a.nodes[#a.nodes + 1] = false; CC.editor.dirty = true end
        elseif verb == "wait" then
            local v, c = ImGui.InputFloat("seconds##" .. wid, a.seconds or 5.0)
            if c then a.seconds = v; CC.editor.dirty = true end
        elseif verb == "set_posture" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            local tdef = nil
            for _, ent3 in ipairs(bp.entities or {}) do
                if ent3.label == a.target then tdef = ent3 break end
            end
            local cur = a.posture or "(pick)"
            if ImGui.BeginCombo("posture##" .. wid, cur) then
                if tdef then
                    for _, pn2 in ipairs(collectPostures(tdef)) do
                        if ImGui.Selectable(pn2, pn2 == a.posture) and pn2 ~= a.posture then a.posture = pn2; CC.editor.dirty = true end
                    end
                end
                ImGui.EndCombo()
            end
        elseif verb == "add_effect" or verb == "remove_effect" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            local ch
            a.fx, ch = inputText("vfx name##" .. wid, a.fx); if ch then CC.editor.dirty = true end
            if ImGui.BeginCombo("pick##" .. wid, "catalog...") then
                for _, nm in ipairs(FX_PICKS) do
                    if ImGui.Selectable(nm, nm == a.fx) then a.fx = nm; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end
        elseif verb == "play_fx" or verb == "explode" then
            a.target = labelCombo("at##" .. wid, a.target, ownerLabel, bp)
            local ch
            a.fx, ch = inputText("fx path##" .. wid, a.fx); if ch then CC.editor.dirty = true end
            if ImGui.SmallButton("Browse " .. #(CC.fxLibrary or {}) .. " FX##" .. wid) then ImGui.OpenPopup("FX Browser " .. wid) end
            ImGui.SameLine()
            if ImGui.BeginCombo("quick##" .. wid, "explosions...") then
                for _, pp in ipairs(WORLD_FX_PICKS) do
                    if ImGui.Selectable(pp[2], pp[1] == a.fx) then a.fx = pp[1]; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end
            fxBrowserPopup("FX Browser " .. wid, function(p) a.fx = p; CC.editor.dirty = true end)
            if verb == "explode" then
                local rv, rc = ImGui.InputFloat("radius m##" .. wid, a.radius or 6.0)
                if rc then a.radius = rv; CC.editor.dirty = true end
                local dv, dc = ImGui.InputInt("damage##" .. wid, a.damage or 50)
                if dc then a.damage = dv; CC.editor.dirty = true end
                ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0 damage = visual only")
            end
        elseif verb == "apply_status" or verb == "remove_status" then
            a.target = labelCombo("who##" .. wid, a.target, ownerLabel, bp)
            local ch
            a.status, ch = inputText("status record##" .. wid, a.status); if ch then CC.editor.dirty = true end
            if ImGui.BeginCombo("pick##" .. wid, "common...") then
                for _, rec in ipairs(STATUS_PICKS) do
                    if ImGui.Selectable(rec, rec == a.status) then a.status = rec; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end
        elseif verb == "set_flag" then
            local ch
            a.flag, ch = inputText("variable##" .. wid, a.flag or a.key); if ch then a.key = nil; CC.editor.dirty = true end
            local FOPS = { "set", "add", "sub", "random" }
            local FOP_LBL = { set = "=", add = "+", sub = "-", random = "= random" }
            local cop = a.op or "set"
            if ImGui.BeginCombo("op##" .. wid, FOP_LBL[cop] or cop) then
                for _, o in ipairs(FOPS) do
                    if ImGui.Selectable(FOP_LBL[o], o == cop) and o ~= cop then a.op = o; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end
            if cop == "random" then
                -- materialize defaults so the SHOWN value is the STORED value; an
                -- untouched field would otherwise stay nil and collapse the roll to min.
                if a.min == nil then a.min = 1; CC.editor.dirty = true end
                if a.max == nil then a.max = 5; CC.editor.dirty = true end
                local mn, mc = ImGui.InputInt("min##" .. wid, math.floor(tonumber(a.min) or 1))
                if mc then a.min = mn; CC.editor.dirty = true end
                local mx, xc = ImGui.InputInt("max##" .. wid, math.floor(tonumber(a.max) or 5))
                if xc then a.max = mx; CC.editor.dirty = true end
                ImGui.TextColored(0.6, 0.8, 0.95, 1.0, "rolls an integer min..max at deploy")
            else
                local vt
                vt, ch = inputText("value##" .. wid, a.value ~= nil and tostring(a.value) or "")
                if ch then a.value = parseValue(vt); CC.editor.dirty = true end
                if (a.op == "add" or a.op == "sub") and a.value ~= nil and tonumber(a.value) == nil then
                    ImGui.TextColored(1.0, 0.4, 0.4, 1.0, "+/- needs a number")
                end
            end
        elseif verb == "trigger" then
            local ids = {}
            for _, ev2 in ipairs(holderEvents or {}) do
                if ev2.id then ids[#ids + 1] = ev2.id end
            end
            local cur = a.target or "(pick rule)"
            if ImGui.BeginCombo("rule##" .. wid, cur) then
                for _, rid in ipairs(ids) do
                    if ImGui.Selectable(rid, rid == a.target) and rid ~= a.target then a.target = rid; CC.editor.dirty = true end
                end
                ImGui.EndCombo()
            end
        elseif verb == "freeze" or verb == "unfreeze" or verb == "hide" or verb == "unhide" then
            a.target = labelCombo("target##" .. wid, a.target, ownerLabel, bp)
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "(runtime only -- resets on save/reload)")
        elseif verb == "open" or verb == "quest_close" or verb == "lock"
            or verb == "unlock" or verb == "enable" or verb == "disable" or verb == "dispose" then
            a.target = labelCombo("device##" .. wid, a.target, ownerLabel, bp, { "all_devices" })
            if verb == "dispose" then
                ImGui.TextColored(1.0, 0.55, 0.2, 1.0, "(!) unstable: deletes the object from the world.")
                ImGui.TextColored(1.0, 0.55, 0.2, 1.0, "non-persistent -- it returns on save/reload.")
            end
        end
        ImGui.Unindent(14)
    end

    local function drawRulesEditor(holder, ownerLabel, bp)
            -- ---- per-object rules, organized as POSTURE TABS -----------------
            -- A posture is a tab; the rules inside belong to it (no per-rule
            -- posture field — the tab assigns it). LAYER COLOR KEY: rule header
            -- cyan, WHEN fields amber, DO fields green.
            ImGui.Separator()
            ImGui.TextColored(0.8, 0.8, 0.3, 1.0, "Postures & Rules")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(110)
            CC.editor.newPosture = select(1, ImGui.InputText("##newposture", CC.editor.newPosture or "", 48))
            ImGui.SameLine()
            if ImGui.SmallButton("+ Posture") then
                local pn = (CC.editor.newPosture or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if pn ~= "" and pn ~= "persistent" then
                    holder.postures = holder.postures or {}
                    local exists = false
                    for _, x in ipairs(holder.postures) do if x == pn then exists = true end end
                    if not exists then
                        CC.pushUndo()
                        holder.postures[#holder.postures + 1] = pn
                        CC.editor.dirty = true
                    end
                    CC.editor.newPosture = ""
                end
            end


            holder.events = holder.events or {}
            -- "persistent" is a pseudo-posture: its rules have NO posture scope,
            -- so the runtime runs them in EVERY posture (death reactions etc).
            local plist = { "persistent" }
            for _, pn in ipairs(collectPostures(holder)) do plist[#plist + 1] = pn end

            ImGui.TextColored(0.55, 0.55, 0.55, 1.0, "actions:")
            ImGui.SameLine(); ImGui.TextColored(0.50, 0.72, 1.00, 1.0, "NPC")
            ImGui.SameLine(); ImGui.TextColored(0.40, 0.88, 0.88, 1.0, "effect")
            ImGui.SameLine(); ImGui.TextColored(0.80, 0.58, 1.00, 1.0, "flow")
            ImGui.SameLine(); ImGui.TextColored(0.55, 0.90, 0.50, 1.0, "world")
            ImGui.SameLine(); ImGui.TextColored(1.00, 0.78, 0.35, 1.0, "quest")
            if ImGui.BeginTabBar("##postures") then
                for _, pname in ipairs(plist) do
                    if ImGui.BeginTabItem(pname) then

                        local removeRule = nil
                        -- initial-action rules always render at the top of the tab
                        local ordered = {}
                        local function inThisTab(ev)
                            if pname == "persistent" then return ev.posture == nil end
                            return ev.posture == pname
                        end
                        for i, ev in ipairs(holder.events) do
                            if inThisTab(ev) and (ev.when or ev.condition) == "on_enter" then
                                ordered[#ordered + 1] = i
                            end
                        end
                        for i, ev in ipairs(holder.events) do
                            if inThisTab(ev) and (ev.when or ev.condition) ~= "on_enter" then
                                ordered[#ordered + 1] = i
                            end
                        end
                        for _, i in ipairs(ordered) do
                            local ev = holder.events[i]
                            do
                                ImGui.PushID("rule" .. i)

                                ImGui.Spacing()
                                ImGui.TextColored(0.25, 0.55, 0.65, 1.0,
                                    "==========================================")
                                ImGui.TextColored(0.3, 0.9, 1.0, 1.0, "RULE  " .. (ev.id or ("rule " .. i)))
                                ImGui.SameLine()
                                if ImGui.SmallButton("X") then removeRule = i end

                                -- WHEN layer (amber)
                                ImGui.Indent(14)
                                drawWhenRow(ev, tostring(i), bp, ownerLabel,
                                    { whens = RULE_WHENS, postureContext = pname, showRepeats = true })

                                -- DO layer (green)
                                ImGui.Indent(14)
                                ImGui.PushStyleColor(ImGuiCol.FrameBg,        0.08, 0.34, 0.16, 0.75)
                                ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, 0.12, 0.46, 0.22, 0.85)
                                ImGui.PushStyleColor(ImGuiCol.Text,           0.62, 0.95, 0.68, 1.0)

                                ev.actions = ev.actions or {}
                                local removeAct, moveFrom, moveTo = nil, nil, nil
                                for j, a in ipairs(ev.actions) do
                                    ImGui.PushID("act" .. j)
                                    local verb = a["do"] or a.action or "speak"
                                    local cr, cg, cb = catColor(verb)
                                    ImGui.TextColored(cr, cg, cb, 1.0, "do " .. j .. ":")
                                    ImGui.SameLine()
                                    drawVerbCombo(a, i .. "_" .. j)
                                    ImGui.SameLine()
                                    if ImGui.SmallButton("^") and j > 1 then moveFrom, moveTo = j, j - 1 end
                                    ImGui.SameLine()
                                    if ImGui.SmallButton("v") and j < #ev.actions then moveFrom, moveTo = j, j + 1 end
                                    ImGui.SameLine()
                                    if ImGui.SmallButton("x") then removeAct = j end
                                    verb = a["do"] or a.action or "speak"

                                    drawDoFields(a, i .. "_" .. j, bp, ownerLabel, holder.events)
                                    ImGui.PopID()
                                end
                                if moveFrom then
                                    CC.pushUndo()
                                    ev.actions[moveFrom], ev.actions[moveTo] = ev.actions[moveTo], ev.actions[moveFrom]
                                    CC.editor.dirty = true
                                end
                                if removeAct then
                                    CC.pushUndo()
                                    table.remove(ev.actions, removeAct)
                                    CC.editor.dirty = true
                                end
                                if ImGui.SmallButton("+ action") then
                                    CC.pushUndo()
                                    ev.actions[#ev.actions + 1] = { ["do"] = "speak", target = ownerLabel }
                                    CC.editor.dirty = true
                                end
                                ImGui.PopStyleColor(3)
                                ImGui.Unindent(28)
                                ImGui.PopID()
                            end
                        end
                        if removeRule then
                            CC.pushUndo()
                            table.remove(holder.events, removeRule)
                            CC.editor.dirty = true
                        end

                        ImGui.Spacing()
                        if pname ~= "persistent" and pname ~= "default" then
                            ImGui.PushStyleColor(ImGuiCol.Button, 0.55, 0.12, 0.12, 1.0)
                            if ImGui.SmallButton("Delete Posture '" .. pname .. "'") then
                                local delP = pname
                                local nRules = 0
                                for _, ev3 in ipairs(holder.events) do
                                    if ev3.posture == delP then nRules = nRules + 1 end
                                end
                                CC.editor.confirm = {
                                    text = "Delete posture '" .. delP .. "' and its " ..
                                           nRules .. " rule(s)?\n" ..
                                           "set_posture actions pointing at it will\n" ..
                                           "dangle. (Undo restores.)",
                                    onYes = function()
                                        CC.pushUndo()
                                        for i3 = #holder.events, 1, -1 do
                                            if holder.events[i3].posture == delP then table.remove(holder.events, i3) end
                                        end
                                        if holder.postures then
                                            for i3 = #holder.postures, 1, -1 do
                                                if holder.postures[i3] == delP then table.remove(holder.postures, i3) end
                                            end
                                        end
                                        if holder.basePosture == delP then holder.basePosture = "default" end
                                        CC.editor.dirty = true
                                        CC.log("deleted posture '" .. delP .. "'")
                                    end,
                                }
                            end
                            ImGui.PopStyleColor(1)
                            ImGui.SameLine()
                        end
                        if ImGui.SmallButton("+ Add Rule") then
                            CC.pushUndo()
                            local newWhen = "dies"
                            if pname ~= "persistent" and pname ~= (holder.basePosture or "default") then
                                newWhen = "on_enter"
                            end
                            holder.events[#holder.events + 1] = {
                                id = (ownerLabel or "obj") .. "_rule" .. (#holder.events + 1),
                                when = newWhen, watch = ownerLabel, actions = {},
                                -- the tab assigns the scope; persistent = none (runs always)
                                posture = (pname ~= "persistent") and pname or nil,
                            }
                            CC.editor.dirty = true
                        end
                        ImGui.SameLine()
                        if ImGui.SmallButton("Clone from...") then
                            clonePopup = { pname = pname, ownerLabel = ownerLabel, srcLabel = nil, srcPosture = nil }
                            ImGui.OpenPopup("ClonePosture##" .. pname)
                        end
                        if ImGui.BeginPopup("ClonePosture##" .. pname) then
                            if clonePopup then
                                ImGui.TextColored(0.8, 0.9, 1.0, 1.0, "Replace '" .. pname .. "' with another object's posture")
                                ImGui.TextColored(0.75, 0.55, 0.55, 1.0, "(REPLACES the current rules in this tab)")
                                ImGui.Separator()
                                if ImGui.BeginCombo("from object##cl", clonePopup.srcLabel or "(pick)") then
                                    for _, e2 in ipairs(bp.entities or {}) do
                                        if e2.label and ImGui.Selectable(e2.label, e2.label == clonePopup.srcLabel) then
                                            clonePopup.srcLabel = e2.label; clonePopup.srcPosture = nil
                                        end
                                    end
                                    ImGui.EndCombo()
                                end
                                local srcE
                                for _, e2 in ipairs(bp.entities or {}) do
                                    if e2.label == clonePopup.srcLabel then srcE = e2 break end
                                end
                                if srcE then
                                    local splist = { "persistent" }
                                    for _, pn4 in ipairs(collectPostures(srcE)) do splist[#splist + 1] = pn4 end
                                    if ImGui.BeginCombo("posture##cl", clonePopup.srcPosture or "(pick)") then
                                        for _, pn4 in ipairs(splist) do
                                            if ImGui.Selectable(pn4, pn4 == clonePopup.srcPosture) then clonePopup.srcPosture = pn4 end
                                        end
                                        ImGui.EndCombo()
                                    end
                                end
                                ImGui.Separator()
                                if srcE and clonePopup.srcPosture then
                                    ImGui.PushStyleColor(ImGuiCol.Button, 0.15, 0.45, 0.20, 1.0)
                                    if ImGui.Button("Replace") then
                                        clonePostureInto(holder, pname, srcE, clonePopup.srcPosture, clonePopup.ownerLabel)
                                        clonePopup = nil; ImGui.CloseCurrentPopup()
                                    end
                                    ImGui.PopStyleColor(1)
                                    ImGui.SameLine()
                                end
                                if ImGui.Button("Cancel") then clonePopup = nil; ImGui.CloseCurrentPopup() end
                            end
                            ImGui.EndPopup()
                        end

                        ImGui.EndTabItem()
                    end
                end
                ImGui.EndTabBar()
            end

    end

    -- Rewrite EVERY label reference oldLabel -> newLabel across the blueprint,
    -- then the object's own label. Exact-match only, so a `trigger` action's
    -- rule-id target (not an object label) is never touched, and flag names in a
    -- separate namespace are left alone unless they exactly equal the old label.
    -- Validates first (non-empty, not already in use); snapshots Undo on success.
    local function renameEntity(bp, oldLabel, newLabel)
        if not bp or not oldLabel then return false, "no object" end
        newLabel = (newLabel or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if newLabel == "" then return false, "name can't be empty" end
        if newLabel == oldLabel then return true end
        for _, ent in ipairs(bp.entities or {}) do
            if ent.label == newLabel then return false, "name already in use" end
        end
        if CC and CC.pushUndo then CC.pushUndo() end      -- pre-mutation snapshot, success only

        local function fixRef(v) if v == oldLabel then return newLabel end return v end
        local function fixAction(a)
            if type(a) ~= "table" then return end
            a.target, a.destination, a.to = fixRef(a.target), fixRef(a.destination), fixRef(a.to)
            if type(a.nodes) == "table" then
                for k, n in ipairs(a.nodes) do a.nodes[k] = fixRef(n) end
            end
        end
        local function fixCond(c)
            if type(c) ~= "table" then return end
            c.watch, c.zone = fixRef(c.watch), fixRef(c.zone)
        end
        local function fixRule(r)
            if type(r) ~= "table" then return end
            fixCond(r)                                     -- the rule's own WHEN
            for _, a in ipairs(r.actions or {}) do fixAction(a) end
        end
        local function fixHolder(h)
            if type(h) == "table" then for _, r in ipairs(h.events or {}) do fixRule(r) end end
        end

        for _, ent in ipairs(bp.entities or {}) do fixHolder(ent) end   -- per-object rules
        fixHolder(bp)                                                   -- quest-level rules

        local lc = bp.lifecycle                                         -- lifecycle slots
        if type(lc) == "table" then
            for _, slot in ipairs({ lc.setup, lc.finally }) do
                if type(slot) == "table" then for _, a in ipairs(slot.actions or {}) do fixAction(a) end end
            end
            for _, box in ipairs({ lc.win, lc.lose }) do
                if type(box) == "table" then
                    for _, grp in ipairs(box.groups or {}) do
                        for _, c in ipairs(grp or {}) do fixCond(c) end
                    end
                end
            end
        end

        for _, ent in ipairs(bp.entities or {}) do                     -- finally, identity
            if ent.label == oldLabel then ent.label = newLabel end
        end
        return true
    end

    -- ========================================================================
    -- OBJECT EDITOR (STUB — per-object identity + state machine, detail next)
    -- ========================================================================
    local function drawObjectEditor()
        -- Resizable, not auto-grow. AlwaysAutoResize made this balloon to fit
        -- ALL content and only scrolled once it hit the screen edge (the "goofy"
        -- scrollbar). A default size + min/max constraints = a normal,
        -- drag-resizable window with a well-behaved internal scrollbar.
        ImGui.SetNextWindowSize(420, 560, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(320, 200, 1000, 1300)  -- CET: verify binding
        ImGui.Begin("CC - Object Editor")
        helpButton("object", HELP.object)
        local bp  = CC.editor and CC.editor.blueprint
        local sel = CC.editor and CC.editor.selectedLabel
        local e   = nil
        if bp and sel then
            for _, ent in ipairs(bp.entities or {}) do
                if ent.label == sel then e = ent break end
            end
        end
        if CC.editor.renaming and CC.editor.renaming ~= sel then
            CC.editor.renaming, CC.editor.renameErr = nil, nil      -- left the object mid-rename: drop it
        end
        if not e then
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "no object selected")
            ImGui.Text("(select one in the Quest Hub window)")
        else
            -- Label is rename-MODE, not live-edit: typing never re-keys the
            -- selection mid-edit, and committing rewrites every reference first
            -- then re-points the selection at the new name.
            local renaming = (CC.editor.renaming == e.label)
            if renaming then
                ImGui.SetNextItemWidth(200)
                CC.editor.renameBuf = select(1, ImGui.InputText("##rename", CC.editor.renameBuf or e.label, 64))
                ImGui.SameLine()
                if ImGui.SmallButton("save") then
                    local rok, rerr = renameEntity(bp, e.label, CC.editor.renameBuf or "")
                    if rok then
                        CC.editor.selectedLabel = (CC.editor.renameBuf or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        CC.editor.renaming, CC.editor.renameErr = nil, nil
                        CC.editor.dirty = true
                        CC.log("renamed -> '" .. CC.editor.selectedLabel .. "'")
                    else
                        CC.editor.renameErr = rerr
                    end
                end
                ImGui.SameLine()
                if ImGui.SmallButton("cancel") then CC.editor.renaming, CC.editor.renameErr = nil, nil end
            else
                ImGui.Text("Label: " .. tostring(e.label))
                ImGui.SameLine()
                if ImGui.SmallButton("Rename") then
                    CC.editor.renaming, CC.editor.renameBuf, CC.editor.renameErr = e.label, e.label, nil
                end
            end
            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Button, 0.55, 0.12, 0.12, 1.0)
            if ImGui.SmallButton("Delete") then
                local delLabel = e.label
                CC.editor.confirm = {
                    text = "Delete object '" .. tostring(delLabel) .. "'?\n" ..
                           "Its rules go with it. Other rules that\n" ..
                           "reference it will dangle. (Undo restores.)",
                    onYes = function()
                        CC.pushUndo()
                        for i2, ent4 in ipairs(bp.entities or {}) do
                            if ent4.label == delLabel then table.remove(bp.entities, i2) break end
                        end
                        if CC.despawnOne then CC.despawnOne(delLabel) end
                        if CC.editor.selectedLabel == delLabel then CC.editor.selectedLabel = nil end
                        CC.editor.dirty = true
                        CC.log("deleted object '" .. tostring(delLabel) .. "'")
                    end,
                }
            end
            ImGui.PopStyleColor(1)
            -- Duplicate: deep copy incl. postures + rules, under a fresh label, with
            -- the copy's OWN self-references repointed to the new label.
            if ImGui.SmallButton("Duplicate") then
                CC.pushUndo()
                local copy = deepCopy(e)
                local base = (e.label or "object") .. " copy"
                local name, k = base, 1
                local function taken(n)
                    for _, x in ipairs(bp.entities or {}) do if x.label == n then return true end end
                    return false
                end
                while taken(name) do k = k + 1; name = base .. " " .. k end
                copy.label = name
                -- drop the copy at V's position + facing (not stacked on the original)
                local pp = CC.worldPos(Game.GetPlayer())
                if pp then
                    copy.x, copy.y, copy.z = pp.x, pp.y, pp.z
                    local pf = nil; pcall(function() pf = Game.GetPlayer():GetWorldForward() end)
                    if pf then copy.fwd_x, copy.fwd_y = pf.x, pf.y end
                elseif copy.x then
                    copy.x = copy.x + 1.0                           -- fallback nudge
                end
                local function fixv(v) return (v == e.label) and name or v end
                for _, r in ipairs(copy.events or {}) do
                    if type(r) == "table" then
                        r.watch, r.zone = fixv(r.watch), fixv(r.zone)
                        for _, a in ipairs(r.actions or {}) do
                            a.target, a.destination, a.to = fixv(a.target), fixv(a.destination), fixv(a.to)
                            if type(a.nodes) == "table" then
                                for ni, nn in ipairs(a.nodes) do a.nodes[ni] = fixv(nn) end
                            end
                        end
                    end
                end
                bp.entities[#bp.entities + 1] = copy
                -- spawn the copy's actor NOW so it shows without a map reload (NPCs only;
                -- zones/devices are gizmo overlays that redraw from the blueprint live).
                if copy.id and string.find(copy.id, "Character%.") and CC.spawnRecord then
                    CC.spawnRecord({
                        id = copy.id, label = copy.label, appearance = copy.appearance,
                        x = copy.x, y = copy.y, z = copy.z,
                        fwd_x = copy.fwd_x, fwd_y = copy.fwd_y, startAttitude = "neutral",
                    })
                end
                CC.editor.selectedLabel = name
                CC.editor.dirty = true
                CC.log("duplicated '" .. tostring(e.label) .. "' -> '" .. name .. "'")
            end
            -- Change model (NPC record) via the same browser, distinct popup id.
            if e.id and e.action ~= "zone" and e.action ~= "device" then
                ImGui.SameLine()
                if ImGui.SmallButton("Change Model") then ImGui.OpenPopup("Change NPC Model") end
                npcBrowserPopup("Change NPC Model", function(rec)
                    e.id = rec; CC.editor.dirty = true; CC.log("model -> " .. tostring(rec))
                end)
            end
            -- Move ANY object (NPC / zone / device) to V's position + facing.
            if e.label then
                ImGui.SameLine()
                if ImGui.SmallButton("Move to V") then
                    local mp = CC.worldPos(Game.GetPlayer())
                    if mp then
                        CC.pushUndo()
                        e.x, e.y, e.z = mp.x, mp.y, mp.z
                        local mf = nil; pcall(function() mf = Game.GetPlayer():GetWorldForward() end)
                        if mf then e.fwd_x, e.fwd_y = mf.x, mf.y end
                        if CC.movePreview then CC.movePreview(e) end
                        CC.editor.dirty = true
                        CC.log("moved '" .. tostring(e.label) .. "' to V")
                    end
                end
            end
            if renaming and CC.editor.renameErr then
                ImGui.TextColored(1.0, 0.45, 0.3, 1.0, "rename: " .. tostring(CC.editor.renameErr))
            end
            if e.action == "device" then
                ImGui.TextColored(0.6, 0.85, 1.0, 1.0, "Device (bound world object)")
                ImGui.Text("Record: " .. tostring(e.record or "?"))
                ImGui.Text("Class:  " .. tostring(e.class or "?"))
                ImGui.Text("Hash:   " .. tostring(e.hash or "(none)"))
            else
                ImGui.Text("Record: " .. tostring(e.id or "(zone)"))
            end
            if e.x then ImGui.Text(string.format("Pos: %.1f, %.1f, %.1f", e.x, e.y, e.z)) end
            local v, c
            if e.action == "zone" then
                if e.shape == "box" then
                    v, c = ImGui.InputFloat("Size X (m)", e.sx or 4.0); if c then e.sx = v; CC.editor.dirty = true end
                    v, c = ImGui.InputFloat("Size Y (m)", e.sy or 4.0); if c then e.sy = v; CC.editor.dirty = true end
                    v, c = ImGui.InputFloat("Height (m)", e.sz or 3.0); if c then e.sz = v; CC.editor.dirty = true end
                else
                    v, c = ImGui.InputFloat("Radius", e.radius or 3.0); if c then e.radius = v; CC.editor.dirty = true end
                end
            end

            -- ---- NPC fields ------------------------------------------------
            if e.id and e.id:find("Character%.") then
                ImGui.Separator()
                ImGui.TextColored(0.8, 0.8, 0.3, 1.0, "NPC")
                local att = e.startAttitude or "neutral"
                if ImGui.BeginCombo("Start attitude", att) then
                    for _, a in ipairs({ "neutral", "hostile", "friendly" }) do
                        if ImGui.Selectable(a, a == att) and a ~= att then e.startAttitude = a; CC.editor.dirty = true end
                    end
                    ImGui.EndCombo()
                end
                -- the posture this object wakes up in (always has one)
                local basep = e.basePosture or "default"
                if ImGui.BeginCombo("Base posture", basep) then
                    for _, pn in ipairs(collectPostures(e)) do
                        if ImGui.Selectable(pn, pn == basep) and pn ~= basep then e.basePosture = pn; CC.editor.dirty = true end
                    end
                    ImGui.EndCombo()
                end
                -- STUBS: stored in the def now, runtime support to follow
                e.community, c = inputText("Community (stub)", e.community)
                if c then CC.editor.dirty = true end
                v, c = ImGui.InputInt("Health pct (stub)", e.healthPct or 100)
                if c then e.healthPct = v; CC.editor.dirty = true end
                v, c = ImGui.InputInt("XP on kill (stub)", e.xpOnKill or 0)
                if c then e.xpOnKill = v; CC.editor.dirty = true end
            end

            drawRulesEditor(e, e.label, bp)
        end
        ImGui.End()
    end

    -- ========================================================================
    -- QUEST MACHINE (object list = selection hub, + quest-level rules)
    -- ========================================================================
    local function drawQuestMachine()
        -- Two-pane hub: LEFT = quest phases & rules, RIGHT = object browser.
        -- Needs a bounded, RESIZABLE window (NOT AlwaysAutoResize) so each pane
        -- owns its own scroll region instead of the whole window ballooning.
        ImGui.SetNextWindowSize(760, 540, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(560, 320, 1600, 1200)  -- CET: verify binding

        -- Title shows the live quest name; the window ID is pinned with
        -- "###cc_quest_hub" so retitling (as you type a Title) never resets the
        -- window's size/position or spawns a duplicate window.
        local bp    = CC.editor and CC.editor.blueprint
        local qname = (bp and bp.title and bp.title ~= "") and bp.title or "no quest"
        ImGui.Begin("CC - Quest Hub (" .. qname .. ")###cc_quest_hub")
        helpButton("quest", HELP.quest)

        -- Editor flycam: fly + noclip from one teleport-based mechanism (see player.lua).
        do
            local fly = CC.fly or {}
            -- CET ImGui.Checkbox returns (value, changed). Key off `changed`, not the
            -- value -- otherwise the `if` is true every frame the box is checked and
            -- immediately toggles back off.
            local newOn, chOn = ImGui.Checkbox("Fly / noclip##flycam", fly.active == true)
            if chOn and CC.toggleFly then CC.toggleFly(newOn) end
            ImGui.SameLine()
            local newLV, chLV = ImGui.Checkbox("lock vertical##flyLV", fly.lockVertical == true)
            if chLV then fly.lockVertical = newLV end
            ImGui.SameLine()
            ImGui.SetNextItemWidth(110)
            local sv, sc = ImGui.SliderFloat("speed##flySpd", fly.speed or 1.0, 0.1, 6.0)
            if sc then fly.speed = sv end
            if fly.active then
                ImGui.TextColored(0.40, 0.90, 0.50, 1.0,
                    "FLYING  --  WASD move, Space up, Sprint down, mouse to steer")
            end
        end
        ImGui.Separator()

        if not bp then
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "no blueprint (New or Load first)")
            ImGui.End(); return
        end

        -- usable width inside the window; the fallback keeps both panes alive if
        -- the binding ever returns nil.
        local availW = 740
        pcall(function()
            local w = ImGui.GetContentRegionAvail()
            if w and w > 0 then availW = w end
        end)
        local rightW = 250                                  -- object list column
        local leftW  = math.max(300, availW - rightW - 12)  -- rules pane gets the rest

        -- ---- LEFT PANE: quest phases & rules -------------------------------
        ImGui.BeginChild("##quest_left", leftW, 0, true)
            ImGui.TextColored(0.5, 0.9, 1.0, 1.0, "QUEST — phases & rules")
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "the mission is a machine too; its postures are PHASES")
            -- the quest machine's base phase (what the mission starts in)
            local qbase = bp.basePosture or "default"
            if ImGui.BeginCombo("Start phase", qbase) then
                for _, pn in ipairs(collectPostures(bp)) do
                    if ImGui.Selectable(pn, pn == qbase) and pn ~= qbase then
                        bp.basePosture = pn; CC.editor.dirty = true
                    end
                end
                ImGui.EndCombo()
            end
            drawRulesEditor(bp, "quest", bp)
        ImGui.EndChild()

        ImGui.SameLine()

        -- ---- RIGHT PANE: object browser (selection hub) --------------------
        ImGui.BeginChild("##quest_right", rightW, 0, true)
            ImGui.TextColored(0.5, 0.9, 1.0, 1.0, "Objects (" .. #(bp.entities or {}) .. ")")
            ImGui.Separator()
            for i, e in ipairs(bp.entities or {}) do
                local tag = (e.label or ("object " .. i))
                    .. "  [" .. (e.action == "device" and "Device"
                        or e.action == "zone" and "Zone"
                        or (e.id and e.id:find("Character%.")) and "NPC" or "Obj") .. "]"
                local selected = CC.editor.selectedLabel == e.label
                if ImGui.Selectable(tag .. "##obj" .. i, selected) and not selected then
                    CC.editor.selectedLabel = e.label
                    CC.ui.showObjectEditor = true   -- selecting opens the editor on it
                end
            end
            if #(bp.entities or {}) == 0 then
                ImGui.TextColored(0.5, 0.5, 0.5, 1.0, "(empty — place objects in the Placer)")
            end
        ImGui.EndChild()

        ImGui.End()
    end

    -- ========================================================================
    -- INSPECTOR (live flags + rule states — play-mode debugging)
    -- ========================================================================
    local function drawInspector()
        ImGui.SetNextWindowSize(260, 220, ImGuiCond.FirstUseEver)
        ImGui.Begin("CC - Inspect")
        helpButton("inspector", HELP.inspector)
        if CC.mode ~= "play" then
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "Live mission debugger.")
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "Deploy a mission to watch")
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "flags + rule states here.")
            ImGui.End(); return
        end
        ImGui.TextColored(0.8, 0.8, 0.3, 1.0, "Flags")
        local any = false
        for k, v in pairs(CC.flags or {}) do
            ImGui.BulletText(tostring(k) .. " = " .. tostring(v)); any = true
        end
        if not any then ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "(none)") end
        ImGui.Spacing()
        ImGui.TextColored(0.8, 0.8, 0.3, 1.0, "Rules")
        for _, r in ipairs(CC.rules or {}) do
            local st = r.rt.fired and "fired" or (r.rt.conditionMet and "waiting" or "armed")
            ImGui.BulletText((r.def.id or "?") .. " (" .. tostring(r.def.when or r.def.condition) .. ") [" .. st .. "]")
        end
        ImGui.End()
    end

    -- ========================================================================
    -- VARIABLES BROWSER — every live flag (vars, stages, postures), filtered.
    -- ========================================================================
    local varsFilter = ""
    local function drawVars()
        ImGui.SetNextWindowSize(280, 320, ImGuiCond.FirstUseEver)
        ImGui.Begin("CC - Variables")
        helpButton("vars", [[Live view of every variable in the
running mission: your text/number vars,
object stages (Label), and postures
(Label@posture). One namespace - object
vars by convention are "Label.varname".
Filter narrows by substring.]])
        varsFilter = select(1, ImGui.InputText("filter##vars", varsFilter, 64))
        ImGui.Separator()
        if CC.mode ~= "play" then
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "deploy a mission to see live values")
        else
            local keys = {}
            for k, _ in pairs(CC.flags or {}) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            local shown = 0
            for _, k in ipairs(keys) do
                if varsFilter == "" or k:lower():find(varsFilter:lower(), 1, true) then
                    local v = CC.flags[k]
                    local isNum = type(v) == "number"
                    if isNum then ImGui.TextColored(0.6, 0.95, 0.7, 1.0, k .. " = " .. tostring(v))
                    else ImGui.TextColored(0.95, 0.85, 0.55, 1.0, k .. ' = "' .. tostring(v) .. '"') end
                    shown = shown + 1
                end
            end
            if shown == 0 then ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "(none)") end
        end
        ImGui.End()
    end

    -- ========================================================================
    -- DRAW (init.lua calls this every frame; windows gate on the overlay)
    -- ========================================================================
    -- ========================================================================
    -- LIFECYCLE WINDOW  (Setup / Win / Lose / Finally)
    -- Setup + Finally are ACTION lists; Win + Lose are OR-of-AND condition
    -- groups (DNF). All four reuse the shared row editors above.
    -- ========================================================================

    -- An ordered action list with add / reorder / remove (Setup, Finally).
    local function drawActionList(box, idtag, bp, ownerLabel)
        box.actions = box.actions or {}
        ImGui.PushStyleColor(ImGuiCol.FrameBg,        0.08, 0.34, 0.16, 0.75)
        ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, 0.12, 0.46, 0.22, 0.85)
        ImGui.PushStyleColor(ImGuiCol.Text,           0.62, 0.95, 0.68, 1.0)
        local removeAct, moveFrom, moveTo = nil, nil, nil
        for j, a in ipairs(box.actions) do
            ImGui.PushID(idtag .. "act" .. j)
            local cr, cg, cb = catColor(a["do"] or a.action or "speak")
            ImGui.TextColored(cr, cg, cb, 1.0, "do " .. j .. ":")
            ImGui.SameLine()
            drawVerbCombo(a, idtag .. "_" .. j)
            ImGui.SameLine()
            if ImGui.SmallButton("^") and j > 1 then moveFrom, moveTo = j, j - 1 end
            ImGui.SameLine()
            if ImGui.SmallButton("v") and j < #box.actions then moveFrom, moveTo = j, j + 1 end
            ImGui.SameLine()
            if ImGui.SmallButton("x") then removeAct = j end
            drawDoFields(a, idtag .. "_" .. j, bp, ownerLabel, bp.events)
            ImGui.PopID()
        end
        if moveFrom then
            CC.pushUndo()
            box.actions[moveFrom], box.actions[moveTo] = box.actions[moveTo], box.actions[moveFrom]
            CC.editor.dirty = true
        end
        if removeAct then
            CC.pushUndo(); table.remove(box.actions, removeAct); CC.editor.dirty = true
        end
        if ImGui.SmallButton("+ action##" .. idtag) then
            CC.pushUndo()
            box.actions[#box.actions + 1] = { ["do"] = "set_flag", flag = "", op = "set", value = 1 }
            CC.editor.dirty = true
        end
        ImGui.PopStyleColor(3)
    end

    -- DNF condition groups: WIN/LOSE are true when ANY group is fully met.
    local function drawConditionGroups(box, idtag, bp)
        box.groups = box.groups or {}
        local removeGroup = nil
        for g, group in ipairs(box.groups) do
            ImGui.PushID(idtag .. "grp" .. g)
            if g > 1 then ImGui.TextColored(1.0, 0.7, 0.2, 1.0, "------  OR  ------") end
            ImGui.TextColored(0.6, 0.8, 0.95, 1.0, "Group " .. g .. "  (all true together)")
            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Button, 0.55, 0.12, 0.12, 1.0)
            if ImGui.SmallButton("x group##" .. idtag .. g) then removeGroup = g end
            ImGui.PopStyleColor(1)
            local removeCond = nil
            for ci, cond in ipairs(group) do
                ImGui.PushID("c" .. ci)
                ImGui.Indent(14)
                ImGui.TextColored(0.75, 0.7, 0.45, 1.0, ci == 1 and "when:" or "AND when:")
                ImGui.SameLine()
                if ImGui.SmallButton("x") then removeCond = ci end
                drawWhenRow(cond, idtag .. "_" .. g .. "_" .. ci, bp, "quest",
                    { whens = COND_WHENS, showRepeats = false })
                ImGui.Unindent(14)
                ImGui.PopID()
            end
            if removeCond then CC.pushUndo(); table.remove(group, removeCond); CC.editor.dirty = true end
            ImGui.Indent(14)
            if ImGui.SmallButton("+ AND condition##" .. idtag .. g) then
                CC.pushUndo(); group[#group + 1] = { when = "dies" }; CC.editor.dirty = true
            end
            ImGui.Unindent(14)
            ImGui.Spacing()
            ImGui.PopID()
        end
        if removeGroup then CC.pushUndo(); table.remove(box.groups, removeGroup); CC.editor.dirty = true end
        if #box.groups == 0 then
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "(no conditions yet)")
        end
        if ImGui.SmallButton("+ OR group##" .. idtag) then
            CC.pushUndo(); box.groups[#box.groups + 1] = { { when = "dies" } }; CC.editor.dirty = true
        end
    end

    local function drawLifecycle()
        ImGui.SetNextWindowSize(520, 600, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(420, 360, 1200, 1300)  -- CET: verify binding
        ImGui.Begin("CC - Lifecycle")
        helpButton("lifecycle", HELP.lifecycle)

        local bp = CC.editor and CC.editor.blueprint
        if not bp then
            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "No mission loaded (New or Load first).")
            ImGui.End(); return
        end

        bp.lifecycle = bp.lifecycle or {}
        local lc = bp.lifecycle
        lc.setup   = lc.setup   or { actions = {} }
        lc.win     = lc.win     or { groups = {} }
        lc.lose    = lc.lose    or { groups = {} }
        lc.finally = lc.finally or { actions = {} }

        ImGui.TextColored(0.5, 0.9, 1.0, 1.0, "Lifecycle: " .. (bp.title or "?"))
        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "enter -> win / lose -> exit  (authoring only - not wired yet)")
        ImGui.Separator()

        if ImGui.CollapsingHeader("SETUP   (entry actions, run on deploy)") then
            ImGui.Indent(8); drawActionList(lc.setup, "setup", bp, "quest"); ImGui.Unindent(8)
        end
        if ImGui.CollapsingHeader("WIN   (complete when ANY group is met)") then
            ImGui.Indent(8); drawConditionGroups(lc.win, "win", bp); ImGui.Unindent(8)
        end
        if ImGui.CollapsingHeader("LOSE   (fail when ANY group is met)") then
            ImGui.Indent(8); drawConditionGroups(lc.lose, "lose", bp); ImGui.Unindent(8)
        end
        if ImGui.CollapsingHeader("FINALLY   (exit actions, run at the end)") then
            ImGui.Indent(8); drawActionList(lc.finally, "finally", bp, "quest"); ImGui.Unindent(8)
        end

        ImGui.End()
    end

    function CC.DrawUI()
        if not CC.isOverlayOpen then return end
        pcall(drawMain)
        pcall(drawConfirmModal)
        if CC.ui.showPlace        then pcall(drawPlace)        end
        if CC.ui.showObjectEditor then pcall(drawObjectEditor) end
        if CC.ui.showQuestMachine then pcall(drawQuestMachine) end
        if CC.ui.showInspector    then pcall(drawInspector)    end
        if CC.ui.showVars         then pcall(drawVars)         end
        if CC.ui.showLifecycle    then pcall(drawLifecycle)    end
    end

end
