-- ============================================================================
-- modules/projection.lua
-- The world -> screen primitive. ONE function (CC.project) turns a world position
-- into screen pixels; gizmos uses it for barks, nameplates, zone shapes, and
-- link beams. Camera fetch + NDC->pixel math are the CONFIRMED working lines from
-- the old bark renderer: the camera SYSTEM itself exposes ProjectPoint, and
-- GetDisplayResolution() gives the screen size.
-- ============================================================================

return function(CC)

    -- The camera system exposes ProjectPoint directly (confirmed in the old mod).
    local function getCamera()
        local cam = nil
        pcall(function() cam = Game.GetCameraSystem() end)
        return cam
    end

    -- Screen size in pixels (CET global).
    function CC.screenSize()
        local w, h = 1920.0, 1080.0
        pcall(function() w, h = GetDisplayResolution() end)
        if not w or w == 0 then w = 1920.0 end
        if not h or h == 0 then h = 1080.0 end
        return w, h
    end

    -- Project a world position ({x,y,z} or Vector4) to screen pixels.
    -- Returns { x, y, depth, onScreen } or nil. onScreen is false behind camera.
    function CC.project(worldPos)
        if not worldPos then return nil end
        local cam = getCamera()
        if not cam then return nil end
        local sp = nil
        pcall(function()
            sp = cam:ProjectPoint(CC.vec4(worldPos.x, worldPos.y, worldPos.z))
        end)
        if not sp then return nil end
        local w, h = CC.screenSize()
        return {
            x        = (sp.x + 1.0) * 0.5 * w,
            y        = (1.0 - ((sp.y + 1.0) * 0.5)) * h,
            depth    = sp.z,
            onScreen = (sp.z > 0),
        }
    end

end
