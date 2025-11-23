#!/usr/bin/env lua
--[[
    Standalone test file for Wc3Utils libraries
    This file can run on standard Lua without WC3 runtime

    Tests included:
    - test_AddEscaping (StringEscape)
    - test_RemoveEscaping (StringEscape)
    - test_roundtrip (StringEscape)
    - test_dumpLoad (Serializer)

    Tests NOT included (require WC3 runtime):
    - test_sync, test_saveLoad, testFileIO, TestOrigSync
]]

-- Get the directory of this script
local scriptPath = debug.getinfo(1, "S").source:match("@(.*)$")
local scriptDir = scriptPath:match("(.*[\\/])") or "./"

-- Mock WC3-specific functions and globals
Debug = {
    assert = function(condition, message)
        if not condition then
            error(message or "Assertion failed", 2)
        end
    end,
    throwError = function(...)
        error(table.concat({...}, " "), 2)
    end,
    beginFile = function() end,
    endFile = function() end,
    traceback = function()
        return debug.traceback("", 2)
    end
}

LogWrite = function(...)
    print(...)
end

LogWriteNoFlush = function(...)
    print(...)
end

-- Mock OnInit - store and execute functions when needed
local onInitCallbacks = {
    map = {},
    global = {},
    trig = {},
    final = {}
}

OnInit = {
    map = function(func) table.insert(onInitCallbacks.map, func) end,
    global = function(func) table.insert(onInitCallbacks.global, func) end,
    trig = function(func) table.insert(onInitCallbacks.trig, func) end,
    final = function(func) table.insert(onInitCallbacks.final, func) end
}

local function executeOnInitCallbacks()
    for _, func in ipairs(onInitCallbacks.map) do func() end
    for _, func in ipairs(onInitCallbacks.global) do func() end
    for _, func in ipairs(onInitCallbacks.trig) do func() end
    for _, func in ipairs(onInitCallbacks.final) do func() end
end

-- Mock WC3 constants
bj_MAX_PLAYER_SLOTS = 24

-- Mock Player objects
local playerObjects = {}
local function createPlayerObject(id)
    return {_id = id, _type = "player"}
end

for i = 0, bj_MAX_PLAYER_SLOTS - 1 do
    playerObjects[i] = createPlayerObject(i)
end

Player = function(id)
    -- Always return the same player object for a given ID
    if not playerObjects[id] then
        playerObjects[id] = createPlayerObject(id)
    end
    return playerObjects[id]
end

GetPlayerId = function(player)
    return player._id
end

GetLocalPlayer = function()
    -- Always return the same Player(0) object
    return Player(0)
end

GetPlayerName = function(player)
    return "Player " .. player._id
end

-- Mock coroutine/timer system
local activeTimers = {}
local currentTime = 0

CreateTimer = function()
    local timer = {
        _callback = nil,
        _timeout = 0,
        _periodic = false,
        _active = false,
        _nextTrigger = 0
    }
    return timer
end

TimerStart = function(timer, timeout, periodic, callback)
    timer._callback = callback
    timer._timeout = timeout
    timer._periodic = periodic
    timer._active = true
    timer._nextTrigger = currentTime + timeout
    -- Add timer to active timers list if not already there
    local found = false
    for _, t in ipairs(activeTimers) do
        if t == timer then
            found = true
            break
        end
    end
    if not found then
        table.insert(activeTimers, timer)
    end
end

PauseTimer = function(timer)
    timer._active = false
end

DestroyTimer = function(timer)
    for i, t in ipairs(activeTimers) do
        if t == timer then
            table.remove(activeTimers, i)
            break
        end
    end
end

-- Mock trigger system
local triggerIdCounter = 0
local activeTriggers = {}
local syncEventHandlers = {} -- Maps prefix -> list of {trigger, player}
local currentTriggerData = {
    player = nil,
    syncData = nil
}

CreateTrigger = function()
    triggerIdCounter = triggerIdCounter + 1
    local trigger = {
        _id = triggerIdCounter,
        _actions = {},
        _enabled = true
    }
    activeTriggers[trigger._id] = trigger
    return trigger
end

TriggerAddAction = function(trigger, action)
    table.insert(trigger._actions, action)
end

BlzTriggerRegisterPlayerSyncEvent = function(trigger, player, prefix, fromServer)
    if not syncEventHandlers[prefix] then
        syncEventHandlers[prefix] = {}
    end
    table.insert(syncEventHandlers[prefix], {trigger = trigger, player = player})
end

GetTriggerPlayer = function()
    return currentTriggerData.player
end

BlzGetTriggerSyncData = function()
    return currentTriggerData.syncData
end

DisableTrigger = function(trigger)
    trigger._enabled = false
end

DestroyTrigger = function(trigger)
    activeTriggers[trigger._id] = nil
end

-- Mock sync data system
BlzSendSyncData = function(prefix, data)
    -- In WC3, BlzSendSyncData sends data from the local player to all clients
    -- The trigger fires on all clients with GetTriggerPlayer() returning the sender
    local sender = GetLocalPlayer()
    
    -- Immediately trigger all registered handlers for this prefix
    local handlers = syncEventHandlers[prefix]
    if handlers then
        for _, handler in ipairs(handlers) do
            -- Only trigger if this handler is registered for the sender player
            if handler.trigger._enabled and handler.player == sender then
                -- Set the current trigger context
                currentTriggerData.player = sender
                currentTriggerData.syncData = data
                
                -- Execute all actions registered to this trigger
                for _, action in ipairs(handler.trigger._actions) do
                    action()
                end
                
                -- Clear the context
                currentTriggerData.player = nil
                currentTriggerData.syncData = nil
            end
        end
    end
    return true
end

-- Mock TriggerSleepAction with coroutine support
local runningCoroutines = {}

TriggerSleepAction = function(duration)
    local co = coroutine.running()
    
    -- Always advance time and process timers
    currentTime = currentTime + duration
    
    -- Process any timers that should fire
    for _, timer in ipairs(activeTimers) do
        while timer._active and timer._nextTrigger <= currentTime do
            if timer._callback then
                timer._callback()
            end
            if timer._periodic then
                timer._nextTrigger = timer._nextTrigger + timer._timeout
            else
                timer._active = false
                break
            end
        end
    end
    
    if not co then
        -- Not in a coroutine, just return
        return
    end
    
    -- In a coroutine, yield (time has already been advanced)
    table.insert(runningCoroutines, {co = co, resumeTime = currentTime})
    coroutine.yield()
end

-- Helper function to process timers and coroutines (no longer used since TriggerSleepAction handles it)
local function processTimersAndCoroutines()
    -- Process coroutines
    local i = 1
    while i <= #runningCoroutines do
        local coData = runningCoroutines[i]
        if coData.resumeTime <= currentTime then
            table.remove(runningCoroutines, i)
            local success, err = coroutine.resume(coData.co)
            if not success then
                error("Coroutine error: " .. tostring(err))
            end
        else
            i = i + 1
        end
    end
end

-- Mock file system for FileIO
local fileSystem = {}

Preload = function(data)
    -- Store data for the current file being written
    if not fileSystem._currentFile then
        fileSystem._currentFile = {}
    end
    table.insert(fileSystem._currentFile, data)
end

PreloadGenClear = function()
    fileSystem._currentFile = {}
end

PreloadGenEnd = function(filename)
    if fileSystem._currentFile then
        fileSystem[filename] = table.concat(fileSystem._currentFile)
        fileSystem._currentFile = nil
    end
end

Preloader = function(filename)
    local content = fileSystem[filename]
    if content then
        -- The WC3 Preloader format wraps the content in a function call
        -- We need to extract the executable Lua code from the format
        -- Format: ")\nendfunction\n//!beginusercode\n<LUA CODE>\n//!endusercode\nfunction a takes nothing returns nothing\n//"
        
        local startMarker = "//!beginusercode\n"
        local endMarker = "\n//!endusercode"
        local startPos = content:find(startMarker, 1, true)
        local endPos = content:find(endMarker, 1, true)
        
        if startPos and endPos then
            local luaCode = content:sub(startPos + #startMarker, endPos - 1)
            
            -- Execute the Lua code with access to BlzSetAbilityTooltip and ANdc
            -- ANdc is the FourCC code used by FileIO for the load ability
            local env = {
                BlzSetAbilityTooltip = BlzSetAbilityTooltip,
                ANdc = FourCC('ANdc'),  -- Provide the ability ID
                table = table,
                string = string,
                math = math,
                print = print
            }
            setmetatable(env, {__index = _G})
            local func, err = load(luaCode, filename, "t", env)
            if func then
                local success, execErr = pcall(func)
                if not success then
                    print("Error executing Preloader content:", execErr)
                end
            else
                print("Error loading Preloader content:", err)
            end
        end
    end
end

local abilityTooltips = {}

BlzGetAbilityTooltip = function(abilityId, level)
    return abilityTooltips[abilityId] or '!@#$, empty data'
end

BlzSetAbilityTooltip = function(abilityId, tooltip, level)
    abilityTooltips[abilityId] = tooltip
end

FourCC = function(code) return code end

-- Load libraries using dofile (no gsub stripping needed - Debug is mocked)
print("=== Loading StringEscape.lua ===")
dofile(scriptDir .. "lua/MyLibs/StringEscape.lua")

print("=== Loading FileIO.lua ===")
dofile(scriptDir .. "lua/MyLibs/FileIO.lua")

print("=== Loading SyncStream.lua ===")
dofile(scriptDir .. "lua/MyLibs/SyncStream.lua")

print("=== Loading Serializer.lua ===")
dofile(scriptDir .. "lua/MyLibs/Serializer.lua")

print("=== Loading TestLib.lua ===")
dofile(scriptDir .. "lua/TestLib.lua")

print("=== Executing OnInit callbacks ===")
executeOnInitCallbacks()

print("=== Libraries loaded successfully ===\n")

-- Modify origTable to remove negative numbers for 32-bit vs 64-bit compatibility
-- The Serializer uses bitwise operations that behave differently in 32-bit (WC3) vs 64-bit (standard) Lua
local origTable = {
    true,
    false,
    1,
    -- -1, -- removed: only works for 32 bit lua
    0,
    255,
    256^2 - 1,
    0x7FFFFFFF, -- the maximum positive integer
    0x7FFFFFFF, -- the maximum positive integer
    -- 0xFFFFFFFF, -- removed: -1 in 32-bit
    -- 0x80000000, -- removed: the minimum negative integer in 32-bit
    math.pi,
    "hello",
    "\0\10\13\91\92\93\248\249\250\251\252\253",
    string.rep("s", 257 ),
    "",
    "h",
    "ab!!",
    {},  -- Empty table
    { key1 = "value1", key2 = "value2" },  -- Table with string keys
    { 100, 200, 300 },  -- Table with only numeric values
    { 0, 1, 2, 1000, 256^3 },  -- Table with growing values
    { 256^3, 1000, 2, 1, 0 },  -- Table with decreasing values
    { [1] = "a", [3] = "c", [5] = "e" },  -- Sparse array
    { nested = { a = 1, b = { c = 2, d = { e = 3 } } } },  -- Deeply nested table
    { { { { { "deep" } } } } },  -- Extreme nesting level
    { special = { "\x0A", "\x09", "\x0D", "\x00", "\x5D", "\x5C" } },  -- Special characters (\n, \t, \r, \0, ], \)
    { mixed = { "string", 123, true, false, 0, { nested = "inside" } } },  -- Mixed types
    { largeNumbers = { 0x40000000, 0x7FFFFFFF } },  -- Large numbers (2^30, 2^31-1) - removed negative numbers
}

-- Helper function to run async tests in coroutines
local function runAsyncTest(testName, testFunc)
    print("\n--- Running " .. testName .. " ---")
    local co = coroutine.create(testFunc)
    local success, err = coroutine.resume(co)
    if not success then
        error("Test " .. testName .. " failed: " .. tostring(err))
    end
    
    -- Process coroutines until the test coroutine is done
    -- Note: TriggerSleepAction now handles time advancement and timer processing
    local maxIterations = 10000
    local iterations = 0
    while coroutine.status(co) ~= "dead" and iterations < maxIterations do
        -- Resume any coroutines that are ready
        local i = 1
        while i <= #runningCoroutines do
            local coData = runningCoroutines[i]
            if coData.resumeTime <= currentTime then
                table.remove(runningCoroutines, i)
                local success, err = coroutine.resume(coData.co)
                if not success then
                    error("Coroutine error: " .. tostring(err))
                end
            else
                i = i + 1
            end
        end
        
        -- If no coroutines are ready, we're stuck
        if coroutine.status(co) ~= "dead" and #runningCoroutines == 0 then
            error("Test " .. testName .. " is stuck with no coroutines waiting")
        end
        
        iterations = iterations + 1
    end
    
    if iterations >= maxIterations then
        error("Test " .. testName .. " timed out after " .. maxIterations .. " iterations")
    end
    
    -- Clean up any remaining coroutines after the test completes
    -- Note: Do NOT clear activeTimers as they may be needed by subsequent tests (e.g., SyncStream timer)
    runningCoroutines = {}
    
    print("--- " .. testName .. " completed ---")
end

-- Run the standalone-compatible tests
print("\n============================================================")
print("RUNNING STANDALONE TESTS FOR WC3UTILS")
print("============================================================")

test_AddEscaping()
test_RemoveEscaping()
test_roundtrip()
test_dumpLoad(origTable)

print("\n--- Running async tests ---")
runAsyncTest("test_sync", test_sync)
runAsyncTest("test_saveLoad", test_saveLoad)

print("\n============================================================")
print("ALL TESTS PASSED!")
print("============================================================\n")
