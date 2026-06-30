-- ============================================================================
-- modules/editor.lua
-- The in-world editor — first piece: the FOCUS INSPECTOR. A no-input HUD that
-- shows, live, whatever is under V's crosshair, with everything relevant to
-- building a mission from it: what it is, the record to spawn it, where it is,
-- which way it faces, its attitude/state, and whether it's already tagged.
--
-- Renders only in editor mode (init.lua onDraw -> CC.DrawEditor). Enter editor
-- mode with the "CC: Toggle Editor Mode" hotkey or the panel button, close the
-- CET overlay, and look around — the HUD tracks your crosshair.
--
-- (Placement / capture / tagging are the next editor pieces; this is read-only
--  intel for now.)
-- ============================================================================

return function(CC)

    local function row(label, value)
        ImGui.Text(label .. ": " .. tostring(value))
    end

    function CC.DrawEditor()
        -- visible crosshair at screen center (the game's own crosshair is hidden
        -- outside combat, and the focus inspector needs a precise aim point)
        pcall(function()
            local w, h = CC.screenSize()
            local cx, cy = w * 0.5, h * 0.5
            local dl  = ImGui.GetForegroundDrawList()
            local col = CC.colU32 and CC.colU32(0.2, 0.9, 1.0, 0.9) or 4294967295
            ImGui.ImDrawListAddLine(dl, cx - 10, cy, cx - 3, cy, col, 1.5)
            ImGui.ImDrawListAddLine(dl, cx + 3,  cy, cx + 10, cy, col, 1.5)
            ImGui.ImDrawListAddLine(dl, cx, cy - 10, cx, cy - 3, col, 1.5)
            ImGui.ImDrawListAddLine(dl, cx, cy + 3,  cx, cy + 10, col, 1.5)
            ImGui.ImDrawListAddLine(dl, cx - 1, cy, cx + 1, cy, col, 2.0)  -- center dot
        end)

        pcall(function()
            local ent = CC.lookAt()

            ImGui.SetNextWindowPos(20, 90, ImGuiCond.FirstUseEver)
            ImGui.PushStyleColor(ImGuiCol.WindowBg, 0.03, 0.03, 0.06, 0.88)
            ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 6.0)
            ImGui.Begin("CC Focus", bit32.bor(
                ImGuiWindowFlags.NoInputs, ImGuiWindowFlags.NoNav,
                ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoFocusOnAppearing))

            ImGui.TextColored(1.0, 0.8, 0.0, 1.0, "FOCUS  ·  crosshair")
            ImGui.Separator()

            if not ent then
                ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "look at an entity")
            else
                -- class / type
                local cls = "?"
                pcall(function() cls = tostring(ent:GetClassName()) end)
                local typeName =
                      cls:find("Puppet")        and "NPC"
                   or cls:find("[Vv]ehicle")    and "Vehicle"
                   or cls:find("[Dd]evice")     and "Device"
                   or "Object"
                row("Type", typeName)
                row("Class", cls)

                -- record id — the thing you'd spawn it from
                local rec = nil
                pcall(function() rec = tostring(ent:GetRecordID()) end)
                if rec and rec ~= "nil" then
                    ImGui.TextColored(0.5, 0.9, 1.0, 1.0, "Record: " .. rec)
                end

                -- position + distance (placement)
                local pos = CC.worldPos(ent)
                if pos then
                    row("Pos", string.format("%.1f, %.1f, %.1f", pos.x, pos.y, pos.z))
                    local d = CC.distToPlayer(pos)
                    if d then row("Dist", string.format("%.1f m", d)) end
                end

                -- facing (for rotation capture)
                pcall(function()
                    local f = ent:GetWorldForward()
                    if f then row("Fwd", string.format("%.2f, %.2f", f.x, f.y)) end
                end)

                -- NPC: attitude / group / alive
                if typeName == "NPC" then
                    pcall(function()
                        local agent  = ent:GetAttitudeAgent()
                        local pagent = Game.GetPlayer():GetAttitudeAgent()
                        row("Toward", tostring(agent:GetAttitudeTowards(pagent)))
                        row("Group", tostring(agent:GetAttitudeGroup()))
                    end)
                    pcall(function() row("Dead", tostring(ent:IsDead())) end)
                end

                -- device: PS class + state (for the welded-door work)
                pcall(function()
                    local ps = ent:GetDevicePS()
                    if ps then
                        row("PS", tostring(ps:GetClassName()))
                        pcall(function()
                            row("State", string.format("ON=%s locked=%s sealed=%s",
                                tostring(ps:IsON()), tostring(ps:IsLocked()), tostring(ps:IsSealed())))
                        end)
                    end
                end)

                -- already tagged in the active mission?
                local entId = nil
                pcall(function() entId = ent:GetEntityID() end)
                if entId then
                    local hash = tostring(entId.hash)
                    for label, id in pairs(CC.labelToEntityId or {}) do
                        if tostring(id.hash) == hash then
                            ImGui.Separator()
                            ImGui.TextColored(0.4, 1.0, 0.4, 1.0, "tagged as: " .. label)
                            break
                        end
                    end
                end
            end

            ImGui.End()
            ImGui.PopStyleVar(1)
            ImGui.PopStyleColor(1)
        end)
    end

end
