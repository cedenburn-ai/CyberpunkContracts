-- ============================================================================
-- modules/gizmos.lua  —  the visible layer (PRODUCTION)
--
-- Two render mechanisms, each used where it's right:
--   * LINES — ImGui.ImDrawListAddLine(drawList, x1,y1,x2,y2, color, thickness)
--     on the FOREGROUND draw list. NOTE: in CET this is a FREE FUNCTION taking
--     the draw list as the first argument — NOT a method on the draw list.
--     (dl:AddLine(...) does not exist; calling it inside pcall was why lines
--     were invisible for so long. Don't pcall-wrap draw calls.)
--   * WINDOWS — floating ImGui windows at projected coords (barks, nameplates,
--     tag panels). The proven bark mechanism.
--
-- Colors are hand-packed 0xAABBGGRR via colU32 — ImGui.GetColorU32 is not
-- reliable in this build.
--
-- Everything re-projects every frame, so all of it tracks V's camera for free.
-- ============================================================================

return function(CC)

    CC.barks = CC.barks or {}   -- { label, text, expireAt }

    -- ------------------------------------------------------------------------
    -- COLOR — manual U32 packing (0xAABBGGRR)
    -- ------------------------------------------------------------------------
    local function colU32(r, g, b, a)
        local R = math.floor((r or 1.0) * 255 + 0.5)
        local G = math.floor((g or 1.0) * 255 + 0.5)
        local B = math.floor((b or 1.0) * 255 + 0.5)
        local A = math.floor((a or 1.0) * 255 + 0.5)
        return A * 16777216 + B * 65536 + G * 256 + R   -- A<<24 | B<<16 | G<<8 | R
    end
    CC.colU32 = colU32   -- exported: other modules (editor) draw with this too

    -- standard gizmo palette, one place
    local COL = {
        zone   = function(a) return colU32(0.20, 0.80, 1.00, a or 0.90) end,  -- cyan
        beam   = function(a) return colU32(1.00, 0.78, 0.20, a or 0.90) end,  -- amber
        select = function(a) return colU32(1.00, 0.90, 0.30, a or 0.95) end,  -- yellow
    }

    -- ------------------------------------------------------------------------
    -- FLOATING TEXT WINDOW (barks / nameplates / tag panels)
    -- ------------------------------------------------------------------------
    local function floatingText(id, sx, sy, text, alpha, r, g, b)
        ImGui.SetNextWindowPos(sx, sy, ImGuiCond.Always, 0.5, 1.0)
        ImGui.PushStyleColor(ImGuiCol.WindowBg, 0.02, 0.02, 0.05, 0.82 * alpha)
        ImGui.PushStyleColor(ImGuiCol.Text, r or 0.9, g or 0.95, b or 1.0, alpha)
        ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 5.0)
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 8.0, 5.0)
        ImGui.Begin("##gz_" .. id, true, bit32.bor(
            ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.NoResize, ImGuiWindowFlags.NoMove,
            ImGuiWindowFlags.NoInputs, ImGuiWindowFlags.NoNav, ImGuiWindowFlags.NoScrollbar,
            ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoFocusOnAppearing))
        ImGui.Text(text)
        ImGui.End()
        ImGui.PopStyleVar(2)
        ImGui.PopStyleColor(2)
    end
    CC.floatingText = floatingText   -- exported for other modules

    -- ------------------------------------------------------------------------
    -- BARKS  (the `speak` verb routes here; rendered in PLAY mode)
    -- ------------------------------------------------------------------------
    function CC.addBark(label, text, duration)
        if not label then return end
        CC.barks[#CC.barks + 1] = {
            label = label, text = text or "", expireAt = os.clock() + (duration or 6.0),
        }
    end

    -- Group active barks BY SPEAKER, then draw each speaker's lines as one vertical
    -- stack rising above their head -- newest nearest the head, older ones climbing
    -- above it -- so multiple bubbles from the same NPC never pile onto one pixel.
    -- Off-screen speakers are pinned to the screen edge (in-front ones clamp to the
    -- nearest side; behind-camera ones flip to a bottom band) so a bark is never
    -- silently dropped just because the speaker walked off-camera.
    local MAX_STACK = 5     -- most lines shown per speaker at once

    function CC.DrawBarks()
        if #CC.barks == 0 then return end
        local now   = os.clock()
        local keep  = {}
        local group = {}        -- label -> ordered list of that speaker's live barks
        local order = {}        -- speaker labels in first-seen order (stable draw order)
        for _, b in ipairs(CC.barks) do
            if now < b.expireAt then
                keep[#keep + 1] = b
                local g = group[b.label]
                if not g then g = {}; group[b.label] = g; order[#order + 1] = b.label end
                g[#g + 1] = b
            end
        end
        CC.barks = keep
        if #order == 0 then return end

        local w, h   = CC.screenSize()
        local margin = 14.0

        for _, label in ipairs(order) do
            local list = group[label]
            local pos  = CC.labelPos(label)
            if pos then
                local sp = CC.project({ x = pos.x, y = pos.y, z = pos.z + 2.0 })  -- head height
                if sp then
                    -- anchor = bottom of the newest bubble. clamp it on-screen so an
                    -- off-camera speaker surfaces at the edge instead of vanishing.
                    local ax, ay = sp.x, sp.y
                    if not sp.onScreen then            -- behind camera: mirror + drop to a bottom band
                        ax, ay = w - sp.x, h - margin
                    end
                    ax = math.max(margin, math.min(w - margin, ax))
                    ay = math.max(margin + 28.0, math.min(h - margin, ay))   -- leave room for the stack

                    local first = math.max(1, #list - MAX_STACK + 1)   -- cap visible lines
                    local yacc  = 0.0
                    for k = #list, first, -1 do
                        local bk    = list[k]
                        local alpha = math.min(1.0, bk.expireAt - now)
                        local lineH = 22.0
                        pcall(function()
                            local _, ty = ImGui.CalcTextSize(bk.text)
                            if ty and ty > 0 then lineH = ty + 10.0 end   -- + window padding
                        end)
                        floatingText("bark_" .. label .. "_" .. k, ax, ay - yacc, bk.text, alpha)
                        yacc = yacc + lineH + 4.0
                    end
                end
            end
        end
    end

    -- ------------------------------------------------------------------------
    -- WORLD-DRAW SURFACE — a fullscreen, transparent, click-through window kept
    -- at the BACK of the ImGui z-order. Its draw list renders at the window's
    -- depth, so everything painted here appears UNDER the CET panels (unlike the
    -- foreground draw list, which paints over all UI). fn receives the draw list.
    -- ------------------------------------------------------------------------
    local function withWorldDrawList(fn)
        local w, h = CC.screenSize()
        ImGui.SetNextWindowPos(0, 0, ImGuiCond.Always)
        ImGui.SetNextWindowSize(w, h, ImGuiCond.Always)
        ImGui.PushStyleColor(ImGuiCol.WindowBg, 0.0, 0.0, 0.0, 0.0)
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 0.0, 0.0)
        ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0.0)
        ImGui.Begin("##cc_world", true, bit32.bor(
            ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.NoResize, ImGuiWindowFlags.NoMove,
            ImGuiWindowFlags.NoInputs, ImGuiWindowFlags.NoNav, ImGuiWindowFlags.NoScrollbar,
            ImGuiWindowFlags.NoFocusOnAppearing, ImGuiWindowFlags.NoBringToFrontOnFocus))
        local dl = ImGui.GetWindowDrawList()
        if dl then fn(dl) end
        ImGui.End()
        ImGui.PopStyleVar(2)
        ImGui.PopStyleColor(1)
    end

    -- ------------------------------------------------------------------------
    -- LINE SHAPES — all take the draw list `dl` first; get it per frame with
    -- ImGui.GetForegroundDrawList() and pass it through (one fetch per frame).
    -- ------------------------------------------------------------------------

    -- straight segment between two projected world points
    local function seg(dl, a, b, col, th)
        if a and b and a.onScreen and b.onScreen then
            ImGui.ImDrawListAddLine(dl, a.x, a.y, b.x, b.y, col, th or 2.0)
        end
    end

    -- flat ground ring
    function CC.drawZoneCircle(dl, cx, cy, cz, radius, col, segs)
        segs = segs or 40
        col  = col or COL.zone()
        local prev = nil
        for n = 0, segs do
            local t  = (n / segs) * 6.2831853
            local sp = CC.project({ x = cx + radius * math.cos(t), y = cy + radius * math.sin(t), z = cz })
            seg(dl, prev, sp, col, 2.0)
            prev = sp
        end
    end

    -- volumetric wireframe box; (cx,cy,cz) is the ground center, rises by height
    function CC.drawZoneBox(dl, cx, cy, cz, hx, hy, height, col)
        col = col or COL.zone()
        local function corner(xi, yi, zi)
            return CC.project({
                x = cx + (xi == 1 and hx or -hx),
                y = cy + (yi == 1 and hy or -hy),
                z = cz + (zi == 1 and height or 0.0),
            })
        end
        local c = {
            corner(0,0,0), corner(1,0,0), corner(1,1,0), corner(0,1,0),   -- bottom
            corner(0,0,1), corner(1,0,1), corner(1,1,1), corner(0,1,1),   -- top
        }
        local edges = {
            {1,2},{2,3},{3,4},{4,1}, {5,6},{6,7},{7,8},{8,5}, {1,5},{2,6},{3,7},{4,8},
        }
        for _, e in ipairs(edges) do seg(dl, c[e[1]], c[e[2]], col, 2.0) end
    end

    -- volumetric cylinder for a zone: base + top rings, intermediate rings every
    -- ~0.75m, and four vertical connectors so it reads as a volume.
    function CC.drawZoneCylinder(dl, cx, cy, cz, radius, height, col)
        col    = col or COL.zone()
        height = height or 2.0
        local step = 0.75
        local z = 0.0
        while z < height do
            CC.drawZoneCircle(dl, cx, cy, cz + z, radius,
                (z == 0.0) and col or COL.zone(0.45))   -- base bright, mids faint
            z = z + step
        end
        CC.drawZoneCircle(dl, cx, cy, cz + height, radius, col)  -- top bright
        -- vertical connectors at the four compass points
        for _, ang in ipairs({ 0.0, 1.5708, 3.14159, 4.71239 }) do
            local px, py = cx + radius * math.cos(ang), cy + radius * math.sin(ang)
            seg(dl, CC.project({ x = px, y = py, z = cz }),
                    CC.project({ x = px, y = py, z = cz + height }), COL.zone(0.55), 1.5)
        end
    end

    -- wireframe SPHERE for a proximity trigger (the check IS a 3D sphere, so this
    -- renders the truth). Horizontal latitude rings whose radius follows the
    -- surface (sqrt(R^2 - z^2)) + two vertical great circles through the poles.
    function CC.drawZoneSphere(dl, cx, cy, cz, radius, col)
        col = col or COL.zone()
        -- latitude rings: equator bright, others fainter; ~5 bands
        local bands = 5
        for i = 0, bands do
            local f  = (i / bands) * 2.0 - 1.0          -- -1 .. +1 across the sphere
            local z  = f * radius * 0.92                 -- stop short of the poles
            local rr = math.sqrt(math.max(0.0, radius * radius - z * z))
            local c  = (math.abs(f) < 0.01) and col or COL.zone(0.4)
            CC.drawZoneCircle(dl, cx, cy, cz + z, rr, c, 36)
        end
        -- two vertical great circles (XZ plane and YZ plane)
        for plane = 1, 2 do
            local prev = nil
            for n = 0, 36 do
                local t = (n / 36) * 6.2831853
                local px, py
                if plane == 1 then px, py = cx + radius * math.cos(t), cy
                else               px, py = cx, cy + radius * math.cos(t) end
                local sp = CC.project({ x = px, y = py, z = cz + radius * math.sin(t) })
                seg(dl, prev, sp, COL.zone(0.55), 1.5)
                prev = sp
            end
        end
    end

    -- arced beam between two world points (lifts in the middle, pulses)
    function CC.drawBeam(dl, ax, ay, az, bx, by, bz, segs)
        segs = segs or 18
        local puls = 0.65 + 0.30 * math.sin(os.clock() * 3.0)
        local col  = COL.beam(puls)
        local lift = 1.5 + CC.dist3({x=ax,y=ay,z=az}, {x=bx,y=by,z=bz}) * 0.15
        local prev = nil
        for n = 0, segs do
            local t  = n / segs
            local sp = CC.project({
                x = ax + (bx - ax) * t,
                y = ay + (by - ay) * t,
                z = az + (bz - az) * t + lift * math.sin(t * 3.14159265),
            })
            seg(dl, prev, sp, col, 2.5)
            prev = sp
        end
    end

    -- tag panel floating just above a box/zone's top face
    function CC.drawTag(label, cx, cy, topZ, selected)
        local sp = CC.project({ x = cx, y = cy, z = topZ + 0.35 })
        if not sp or not sp.onScreen then return end
        local r, g, b = 0.4, 0.9, 1.0
        if selected then r, g, b = 1.0, 0.9, 0.3 end
        floatingText("tag_" .. label, sp.x, sp.y, label, 1.0, r, g, b)
    end

    -- ------------------------------------------------------------------------
    -- NAMEPLATE  (entity identity: label + type + live stage)
    -- ------------------------------------------------------------------------
    local function nameplate(e, pos)
        local sp = CC.project({ x = pos.x, y = pos.y, z = pos.z + 2.0 })
        if not sp or not sp.onScreen then return end
        local typeName = (e.action == "zone") and "Zone"
            or (e.id and e.id:find("Vehicle%.")) and "Vehicle"
            or (e.id and e.id:find("Character%.")) and "NPC" or "Object"
        local hasRules = e.events and #e.events > 0
        local stage = e.label and CC.flags and CC.flags[e.label]
        local text = (e.label or "?") .. "  [" .. typeName .. "]"
        if stage ~= nil then text = text .. "  stage=" .. tostring(stage) end
        local selected = CC.editor and CC.editor.selectedLabel == e.label
        local r, g, b
        if selected then r, g, b = 1.0, 0.9, 0.3
        elseif hasRules then r, g, b = 0.4, 0.9, 1.0
        else r, g, b = 0.7, 0.7, 0.7 end
        floatingText("np_" .. (e.label or tostring(sp.x)), sp.x, sp.y, text, 1.0, r, g, b)
    end

    -- ------------------------------------------------------------------------
    -- EDITOR DRAW — zones as wireframes with tags, entities as nameplates.
    -- ------------------------------------------------------------------------
    function CC.DrawEditorGizmos()
        withWorldDrawList(function(dl)

        -- concept test: two tagged boxes + a beam (toggle hotkey below)
        if CC.testBeam then
            local t = CC.testBeam
            CC.drawZoneBox(dl, t.a.x, t.a.y, t.a.z, 1.5, 1.5, 2.0)
            CC.drawZoneBox(dl, t.b.x, t.b.y, t.b.z, 1.5, 1.5, 2.0)
            CC.drawBeam(dl, t.a.x, t.a.y, t.a.z + 1.0, t.b.x, t.b.y, t.b.z + 1.0)
            CC.drawTag("ZoneAlpha", t.a.x, t.a.y, t.a.z + 2.0)
            CC.drawTag("ZoneBravo", t.b.x, t.b.y, t.b.z + 2.0)
        end

        -- mission content — in EDITOR the blueprint is the truth; a (stale or
        -- running) activeMission is only the fallback when nothing is being edited
        local m = (CC.editor and CC.editor.blueprint) or CC.activeMission
        if not m or not m.entities then return end
        for _, e in ipairs(m.entities) do
            local pos = CC.labelPos(e.label)
            if not pos and e.x then pos = { x = e.x, y = e.y, z = e.z } end
            if pos then
                local selected = CC.editor and CC.editor.selectedLabel == e.label
                if e.action == "zone" then
                    local zcol = selected and COL.select() or COL.zone()
                    if e.shape == "box" then
                        local sx, sy, sz = e.sx or 4.0, e.sy or 4.0, e.sz or 3.0
                        CC.drawZoneBox(dl, pos.x, pos.y, pos.z, sx * 0.5, sy * 0.5, sz, zcol)
                        if e.label then CC.drawTag(e.label, pos.x, pos.y, pos.z + sz, selected) end
                    else
                        local r = e.radius or CC.config.defaultProximity
                        CC.drawZoneSphere(dl, pos.x, pos.y, pos.z, r, zcol)
                        if e.label then CC.drawTag(e.label, pos.x, pos.y, pos.z + r, selected) end
                    end
                else
                    nameplate(e, pos)
                end
            end
        end

        end)   -- /withWorldDrawList
    end

    -- ------------------------------------------------------------------------
    -- CONCEPT TEST HOTKEY — simple toggle now: place / clear.
    -- ------------------------------------------------------------------------
    registerHotkey("CCTestBeam", "CC: Test Box Beam", function()
        if CC.testBeam then
            CC.testBeam = nil
            CC.mode = "idle"
            CC.log("test beam cleared")
            return
        end
        local p = CC.worldPos(Game.GetPlayer())
        if not p then CC.log("no player"); return end
        local fwd = nil
        pcall(function() fwd = Game.GetPlayer():GetWorldForward() end)
        local fx, fy = (fwd and fwd.x) or 1.0, (fwd and fwd.y) or 0.0
        local mag = math.sqrt(fx * fx + fy * fy)
        if mag < 0.01 then fx, fy = 1.0, 0.0 else fx, fy = fx / mag, fy / mag end
        local lx, ly = -fy, fx
        CC.testBeam = {
            a = { x = p.x + fx * 6.0 + lx * 3.0, y = p.y + fy * 6.0 + ly * 3.0, z = p.z },
            b = { x = p.x + fx * 6.0 - lx * 3.0, y = p.y + fy * 6.0 - ly * 3.0, z = p.z },
        }
        CC.mode = "editor"
        CC.log("test beam placed (lines) — press again to clear")
    end)

end
