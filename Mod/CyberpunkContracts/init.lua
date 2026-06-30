-- ============================================================================
-- CYBERPUNK CONTRACTS
-- A mission editor + player for Cyberpunk 2077.
--
-- init.lua  —  the entry point. Kept deliberately THIN. It owns only three things:
--
--   1. MODULE LOADING. Boots every file in modules/. A module that is broken or
--      not-yet-written is logged and skipped, never crashing the mod — so we can
--      build one module at a time and read the console to see exactly where we are.
--
--   2. THE CET LIFECYCLE. onInit / onUpdate / onDraw / onShutdown. None of these
--      handlers contain logic themselves; each one calls named functions that the
--      modules attach (see the LIFECYCLE SLOTS section).
--
--   3. MODE DISPATCH. EDITOR mode vs PLAY mode, so update/draw run the correct
--      half of the system.
--
-- ALL real logic lives in the module files. To add a feature:
--   * add its path to the MODULES list below, and
--   * in that file, attach functions to CC (see the LIFECYCLE SLOTS comment).
-- Nothing else in this file needs to change.
-- ============================================================================

local MOD_NAME    = "Cyberpunk Contracts"
local MOD_TAG     = "CyberpunkContracts"   -- console prefix AND our namespace
local MOD_VERSION = "0.1.0"                 -- the MOD version.
                                            -- NOTE: the saved-mission SCHEMA version
                                            -- is a SEPARATE number that lives in
                                            -- modules/filesystem. Per our versioning
                                            -- rule, the mod version and the file
                                            -- version move independently of each other.

print("[" .. MOD_TAG .. "] boot — " .. MOD_NAME .. " v" .. MOD_VERSION)

-- ----------------------------------------------------------------------------
-- CC : THE SINGLE SHARED TABLE
-- Every module receives this, hangs its state and functions off of it, and reads
-- the other modules through it. There is exactly ONE of these — no second copy of
-- any state or logic anywhere (our "single source of truth" rule).
-- ----------------------------------------------------------------------------
local CC = {
    name    = MOD_NAME,
    tag     = MOD_TAG,
    version = MOD_VERSION,

    -- Current runtime mode. Decides what onUpdate/onDraw actually do:
    --   "idle"   — nothing deployed, not editing
    --   "editor" — building a mission live in the world
    --   "play"   — a mission is deployed and running
    mode = "idle",

    isOverlayOpen  = false,  -- true while the CET overlay (F12) is open
    isShuttingDown = false,  -- true once shutting down; every loop bails on this
    playerReady    = false,  -- true once Game.GetPlayer() exists this session
}

-- ----------------------------------------------------------------------------
-- LOGGING
--   CC.log     — always print, prefixed with our tag.
--   CC.logOnce — print a given key only once, so a per-frame error logs a single
--                line instead of flooding the console.
-- (modules/utils may extend these once it loads, e.g. add a debug-only channel.)
-- ----------------------------------------------------------------------------
function CC.log(msg)
    print("[" .. CC.tag .. "] " .. tostring(msg))
end

local _loggedOnce = {}
function CC.logOnce(key, msg)
    if _loggedOnce[key] then return end
    _loggedOnce[key] = true
    CC.log(msg)
end

-- Wipe the once-log so errors can re-surface after a save load (fresh slate).
function CC.clearLogOnce()
    _loggedOnce = {}
end

-- ----------------------------------------------------------------------------
-- MODULE LOADING
--
-- OUR module convention — a module file returns a function that takes CC:
--
--     return function(CC)
--         CC.someState = {}               -- attach state
--         function CC.DoThing() ... end   -- attach logic
--     end
--
-- loadModule() pcall-wraps BOTH the require and the function call, so a missing
-- file ("not built yet") or a syntax error in one module is reported and skipped
-- without taking down the rest of the mod.
-- ----------------------------------------------------------------------------
local function loadModule(path)
    local ok, mod = pcall(require, path)
    if not ok then
        -- During early dev the usual reason is simply that the file doesn't exist.
        CC.log("module '" .. path .. "' not loaded (" .. tostring(mod) .. ")")
        return false
    end
    if type(mod) ~= "function" then
        CC.log("module '" .. path .. "' did not return function(CC) — skipped")
        return false
    end
    local okRun, err = pcall(mod, CC)
    if not okRun then
        CC.log("module '" .. path .. "' ERRORED on load — " .. tostring(err))
        return false
    end
    CC.log("module '" .. path .. "' OK")
    return true
end

-- A vendored library has a different shape (returns a plain table, not function(CC)).
-- We attach it under CC[key] by hand. interactionUI is one of these.
local function loadLibrary(path, key)
    local ok, lib = pcall(require, path)
    if ok and type(lib) == "table" then
        CC[key] = lib
        CC.log("library '" .. path .. "' OK -> CC." .. key)
    else
        CC.log("library '" .. path .. "' not loaded (" .. tostring(lib) .. ")")
    end
end

-- ----------------------------------------------------------------------------
-- MODULE MANIFEST
-- Load order matters: foundations first, then the layers built on top of them.
-- A path whose file you haven't written yet just logs "not loaded" until the
-- file exists — that is your live build checklist.
-- ----------------------------------------------------------------------------
local MODULES = {
    -- foundation -------------------------------------------------------------
    "modules/state",      -- every state variable + its default, in one place
    "modules/utils",      -- distance, hash bridge, math, small shared helpers
    "modules/npcdata",    -- NPC record catalog (629) for the placement browser
    "modules/fxdata",     -- world-FX resource catalog (1639) for play_fx / explode
    "modules/nativeio",   -- native byte read/write + DumpClassNative offset
                          --   resolution. Handle with care: everything risky
                          --   funnels through here so it can be validated/logged.

    -- data -------------------------------------------------------------------
    "modules/filesystem", -- mission save/load, schema versioning + migration

    -- shared rendering (ONE projection primitive draws everything below) ------
    "modules/projection", -- world point -> screen point (the core renderer)
    "modules/gizmos",     -- nameplates, zone boxes, link beams, speech barks

    -- shared world (editor AND player both go through this) -------------------
    "modules/spawn",      -- spawn/place entities, apply rotation, T-pose markers

    -- mission runtime (the PLAY half) ----------------------------------------
    "modules/conditions", -- WHEN: proximity, dies, aggro, flag-equals, timer...
    "modules/actions",    -- DO: speak, move, follow, set_flag, set_attitude...
    "modules/machine",    -- the state-machine tick + flag bus
    "modules/player",     -- deploy, objectives, completion, fixer/wake

    -- editor half ------------------------------------------------------------
    "modules/editor",     -- in-world placement, selection, editor logic
    "modules/ui",         -- ImGui: main panel, editor panels, live inspector

    -- hotkeys (registers CET hotkeys; kept out of THIS file) -----------------
    "modules/hotkeys",
}

for _, path in ipairs(MODULES) do
    loadModule(path)
end

-- Vendored libraries (different shape — loaded and attached by hand) ----------
loadLibrary("modules/interactionUI", "interactionUI")  -- dialogue choice hubs

-- ----------------------------------------------------------------------------
-- LIFECYCLE SLOTS
-- The handlers below call these named functions IF a module has attached them.
-- A module fills whichever slots it cares about; unfilled slots simply no-op.
-- This is the entire contract between init.lua and every module:
--
--   CC.Init()             — game-ready setup (load missions, register hooks, etc.)
--   CC.OnGameLoaded()     — fired once each time a save finishes loading
--   CC.TickAlways(dt)     — every frame, in every mode
--   CC.TickEditor(dt)     — every frame, EDITOR mode only
--   CC.TickPlayer(dt)     — every frame, PLAY mode (objectives, wake, completion)
--   CC.TickMachines(dt)   — every frame, PLAY mode (the state-machine engine)
--   CC.DrawEditorGizmos() — EDITOR-mode world draw (nameplates / zones / beams)
--   CC.DrawBarks()        — PLAY-mode world draw (speech bubbles)
--   CC.DrawObjectiveHUD() — PLAY-mode HUD
--   CC.DrawUI()           — ImGui windows (every mode; gate on CC.isOverlayOpen)
--   CC.OnShutdown()       — teardown
--
-- NOTE on timing: modules/state should set DEFAULT values at load time. Anything
-- that needs the game to be ready (blackboards, loading the mission pool) goes in
-- CC.Init, which fires on onInit.
-- ----------------------------------------------------------------------------

-- Calls CC[fnName](...) if it exists, swallowing + de-duping errors so one bad
-- module can never crash the frame or flood the console.
local function call(fnName, ...)
    local fn = CC[fnName]
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        CC.logOnce("err:" .. fnName, fnName .. " error — " .. tostring(err))
    end
end

-- ----------------------------------------------------------------------------
-- CET LIFECYCLE
-- ----------------------------------------------------------------------------
registerForEvent("onOverlayOpen",  function() CC.isOverlayOpen = true  end)
registerForEvent("onOverlayClose", function() CC.isOverlayOpen = false end)

registerForEvent("onInit", function()
    CC.log("onInit — game systems ready")
    if CC.interactionUI and CC.interactionUI.init then CC.interactionUI.init() end
    call("Init")
end)

registerForEvent("onUpdate", function(dt)
    if CC.isShuttingDown then return end

    -- No player = loading screen / main menu. Do nothing this frame.
    local player = nil
    pcall(function() player = Game.GetPlayer() end)
    if not player then
        CC.playerReady = false
        return
    end

    -- player went absent -> present means a save just finished loading. Let modules
    -- reset so we never keep running on stale state across a load.
    if not CC.playerReady then
        CC.playerReady = true
        CC.clearLogOnce()
        call("OnGameLoaded")
    end

    -- vendored interactionUI keeps its own per-frame update.
    if CC.interactionUI and CC.interactionUI.update then CC.interactionUI.update() end

    call("TickAlways", dt)

    if CC.mode == "editor" then
        call("TickEditor", dt)
    elseif CC.mode == "play" then
        call("TickPlayer", dt)
        call("TickMachines", dt)
    end
end)

registerForEvent("onDraw", function()
    if CC.isShuttingDown then return end
    if not CC.playerReady then return end

    if CC.mode == "editor" then
        call("DrawEditorGizmos")
        call("DrawEditor")
    elseif CC.mode == "play" then
        call("DrawBarks")
        call("DrawObjectiveHUD")
    end

    call("DrawUI")  -- windows gate themselves on CC.isOverlayOpen
end)

registerForEvent("onShutdown", function()
    CC.isShuttingDown = true
    call("OnShutdown")
end)

-- ----------------------------------------------------------------------------
-- BOOTSTRAP HOTKEY
-- Only ONE lives here, because flipping in/out of editor mode is a lifecycle
-- concern. Every OTHER hotkey belongs in modules/hotkeys.
-- (Reminder: a CET hotkey must be bound to a key in the CET "Bindings" tab
--  before it will fire.)
-- ----------------------------------------------------------------------------
registerHotkey("CCToggleEditor", "CC: Toggle Editor Mode", function()
    if CC.mode == "editor" then
        CC.mode = "idle"
        CC.log("editor mode OFF")
    else
        CC.mode = "editor"
        CC.log("editor mode ON")
    end
end)
