#!/usr/bin/env lua
--[[
    Standalone test file for LiveCoding.lua
    This file can run on standard Lua without WC3 runtime

    Tests included:
    - test_TryInterpret_disabled_in_multiplayer
    - test_TryInterpret_enabled_in_singleplayer
    - test_TryInterpret_enabled_in_replay
    - test_CheckFiles_executes_command
    - test_CheckFiles_handles_return_value
    - test_Breakpoint_disabled_in_multiplayer
    - test_Breakpoint_with_condition

    All WC3 native functions are mocked in TestLib_mocks.lua
]]

-- Get the directory of this script
local scriptPath = debug.getinfo(1, "S").source:match("@(.*)$")
local scriptDir = scriptPath:match("(.*[\\/])") or "./"

-- Load WC3 mocks
dofile(scriptDir .. "../TestLib_mocks.lua")

-- Add additional mocks needed for LiveCoding.lua
GAME_STATUS_OFFLINE = 0
GAME_STATUS_ONLINE = 1
GAME_STATUS_REPLAY = 2
GameStatus = GAME_STATUS_OFFLINE
bj_isSinglePlayer = true

-- Load required libraries
print("=== Loading StringEscape.lua ===")
dofile(scriptDir .. "MyLibs/StringEscape.lua")

print("=== Loading FileIO.lua ===")
dofile(scriptDir .. "MyLibs/FileIO.lua")

print("=== Loading LiveCoding.lua ===")
dofile(scriptDir .. "MyLibs/LiveCoding.lua")

print("=== Executing OnInit callbacks ===")
executeOnInitCallbacks()

print("=== Libraries loaded successfully ===\n")

-- Track the current file index (mirrors nextFile in LiveCoding.lua)
local currentFileIndex = 0

-- Test helper to reset state between tests
local function resetState()
    -- Reset game status
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    -- Reset breakpoint state
    EnabledBreakpoints = {}
    -- Clear any running coroutines
    clearRunningCoroutines()
end

-- Helper to get the next file index and increment it
local function getNextFileIndex()
    local idx = currentFileIndex
    currentFileIndex = currentFileIndex + 1
    return idx
end

-- Helper function to run async tests in coroutines
local function runAsyncTest(testName, testFunc)
    print("\n--- Running " .. testName .. " ---")
    local co = coroutine.create(testFunc)
    local success, err = coroutine.resume(co)
    if not success then
        error("Test " .. testName .. " failed: " .. tostring(err))
    end
    
    local maxIterations = 10000
    local iterations = 0
    while coroutine.status(co) ~= "dead" and iterations < maxIterations do
        if coroutine.status(co) ~= "dead" and getRunningCoroutineCount() == 0 then
            error("Test " .. testName .. " is stuck with no coroutines waiting")
        end
        
        processTimersAndCoroutines()
        iterations = iterations + 1
    end
    
    if iterations >= maxIterations then
        error("Test " .. testName .. " timed out after " .. maxIterations .. " iterations")
    end
    
    clearRunningCoroutines()
    print("--- " .. testName .. " completed ---")
end

-- ============================================================================
-- Tests for TryInterpret
-- ============================================================================

function test_TryInterpret_disabled_in_multiplayer()
    print("\n--- Running test_TryInterpret_disabled_in_multiplayer ---")
    resetState()
    
    -- Set up multiplayer scenario
    GameStatus = GAME_STATUS_ONLINE
    bj_isSinglePlayer = false
    
    -- Call TryInterpret
    TryInterpret()
    
    -- The interpreter should be disabled (isDisabled is local, so we test indirectly)
    -- We can test by checking that CheckFiles returns early without doing anything
    -- Save a command file and verify it's not executed
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "return 'should_not_execute'")
    
    -- Run CheckFiles
    CheckFiles()
    
    -- The output file should not exist because the interpreter is disabled
    local result = FileIO.Load("Interpreter\\out" .. fileIdx .. ".txt")
    Debug.assert(result == nil, "Expected no output in multiplayer, got: " .. tostring(result))
    
    -- Decrement file index since the command was not processed
    currentFileIndex = currentFileIndex - 1
    
    print("--- test_TryInterpret_disabled_in_multiplayer completed ---")
end

function test_TryInterpret_enabled_in_singleplayer()
    print("\n--- Running test_TryInterpret_enabled_in_singleplayer ---")
    resetState()
    
    -- Set up singleplayer scenario
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    
    -- Call TryInterpret
    TryInterpret()
    
    -- Save a command file
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "return 'executed'")
    
    -- Run CheckFiles
    CheckFiles()
    
    -- The output file should exist with the result
    local result = FileIO.Load("Interpreter\\out" .. fileIdx .. ".txt")
    Debug.assert(result == "executed", "Expected 'executed', got: " .. tostring(result))
    
    print("--- test_TryInterpret_enabled_in_singleplayer completed ---")
end

function test_TryInterpret_enabled_in_replay()
    print("\n--- Running test_TryInterpret_enabled_in_replay ---")
    resetState()
    
    -- Set up replay scenario
    GameStatus = GAME_STATUS_REPLAY
    bj_isSinglePlayer = false
    
    -- Call TryInterpret
    TryInterpret()
    
    -- Save a command file
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "return 'replay_executed'")
    
    -- Run CheckFiles
    CheckFiles()
    
    -- The output file should exist with the result
    local result = FileIO.Load("Interpreter\\out" .. fileIdx .. ".txt")
    Debug.assert(result == "replay_executed", "Expected 'replay_executed', got: " .. tostring(result))
    
    print("--- test_TryInterpret_enabled_in_replay completed ---")
end

-- ============================================================================
-- Tests for CheckFiles
-- ============================================================================

function test_CheckFiles_executes_command()
    print("\n--- Running test_CheckFiles_executes_command ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret()
    
    -- Create a global variable to track execution
    _G.testExecuted = false
    
    -- Save a command that sets the global variable
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "_G.testExecuted = true")
    
    -- Run CheckFiles
    CheckFiles()
    
    -- Verify the command was executed
    Debug.assert(_G.testExecuted == true, "Command was not executed")
    
    -- Clean up
    _G.testExecuted = nil
    
    print("--- test_CheckFiles_executes_command completed ---")
end

function test_CheckFiles_handles_return_value()
    print("\n--- Running test_CheckFiles_handles_return_value ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret()
    
    -- Save a command with a return value
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "return 42")
    
    -- Run CheckFiles
    CheckFiles()
    
    -- Verify the output file contains the return value
    local result = FileIO.Load("Interpreter\\out" .. fileIdx .. ".txt")
    Debug.assert(result == "42", "Expected '42', got: " .. tostring(result))
    
    print("--- test_CheckFiles_handles_return_value completed ---")
end

function test_CheckFiles_handles_nil_return()
    print("\n--- Running test_CheckFiles_handles_nil_return ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret()
    
    -- Save a command without a return value
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "local x = 1")
    
    -- Run CheckFiles
    CheckFiles()
    
    -- Verify the output file contains "nil"
    local result = FileIO.Load("Interpreter\\out" .. fileIdx .. ".txt")
    Debug.assert(result == "nil", "Expected 'nil', got: " .. tostring(result))
    
    print("--- test_CheckFiles_handles_nil_return completed ---")
end

function test_CheckFiles_sequential_commands()
    print("\n--- Running test_CheckFiles_sequential_commands ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret()
    
    -- Save first command
    local fileIdx1 = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx1 .. ".txt", "return 'first'")
    CheckFiles()
    local result1 = FileIO.Load("Interpreter\\out" .. fileIdx1 .. ".txt")
    Debug.assert(result1 == "first", "Expected 'first', got: " .. tostring(result1))
    
    -- Save second command
    local fileIdx2 = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx2 .. ".txt", "return 'second'")
    CheckFiles()
    local result2 = FileIO.Load("Interpreter\\out" .. fileIdx2 .. ".txt")
    Debug.assert(result2 == "second", "Expected 'second', got: " .. tostring(result2))
    
    print("--- test_CheckFiles_sequential_commands completed ---")
end

-- ============================================================================
-- Tests for Breakpoint
-- ============================================================================

function test_Breakpoint_disabled_in_multiplayer()
    print("\n--- Running test_Breakpoint_disabled_in_multiplayer ---")
    resetState()
    
    -- Set up multiplayer scenario
    GameStatus = GAME_STATUS_ONLINE
    bj_isSinglePlayer = false
    TryInterpret()
    
    -- Breakpoint should return immediately without blocking
    local executed = false
    runAsyncTest("breakpoint_multiplayer", function()
        Breakpoint("test_bp_1")
        executed = true
    end)
    
    Debug.assert(executed, "Breakpoint should not block in multiplayer")
    
    print("--- test_Breakpoint_disabled_in_multiplayer completed ---")
end

function test_Breakpoint_with_disabled_breakpoint()
    print("\n--- Running test_Breakpoint_with_disabled_breakpoint ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret()
    
    -- Disable the breakpoint before calling it
    EnabledBreakpoints["test_bp_disabled"] = false
    
    -- Breakpoint should return immediately because it's disabled
    local executed = false
    runAsyncTest("breakpoint_disabled", function()
        Breakpoint("test_bp_disabled")
        executed = true
    end)
    
    Debug.assert(executed, "Disabled breakpoint should not block")
    
    print("--- test_Breakpoint_with_disabled_breakpoint completed ---")
end

function test_Breakpoint_starts_disabled()
    print("\n--- Running test_Breakpoint_starts_disabled ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret()
    
    -- Breakpoint with startsEnabled=false should not block
    local executed = false
    runAsyncTest("breakpoint_starts_disabled", function()
        Breakpoint("test_bp_starts_disabled", nil, nil, false)
        executed = true
    end)
    
    Debug.assert(executed, "Breakpoint with startsEnabled=false should not block")
    Debug.assert(EnabledBreakpoints["test_bp_starts_disabled"] == false, "Breakpoint should be disabled")
    
    print("--- test_Breakpoint_starts_disabled completed ---")
end

function test_Breakpoint_with_false_condition()
    print("\n--- Running test_Breakpoint_with_false_condition ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret()
    
    -- Breakpoint with false condition should not block
    local executed = false
    runAsyncTest("breakpoint_false_condition", function()
        Breakpoint("test_bp_condition", nil, "return false")
        executed = true
    end)
    
    Debug.assert(executed, "Breakpoint with false condition should not block")
    
    print("--- test_Breakpoint_with_false_condition completed ---")
end

function test_Breakpoint_not_yieldable()
    print("\n--- Running test_Breakpoint_not_yieldable ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret()
    
    -- Call Breakpoint outside of a coroutine (not yieldable)
    -- It should throw an error because coroutine.isyieldable() returns false
    local success, err = pcall(function()
        Breakpoint("test_bp_not_yieldable")
    end)
    
    -- The breakpoint should throw an error when not in yieldable context
    Debug.assert(not success, "Breakpoint should throw error in non-yieldable context")
    Debug.assert(err:find("yieldable") ~= nil, "Error should mention 'yieldable', got: " .. tostring(err))
    
    print("--- test_Breakpoint_not_yieldable completed ---")
end

-- ============================================================================
-- Run all tests
-- ============================================================================

print("\n============================================================")
print("RUNNING STANDALONE TESTS FOR LIVECODING.LUA")
print("============================================================")

-- TryInterpret tests
test_TryInterpret_disabled_in_multiplayer()
test_TryInterpret_enabled_in_singleplayer()
test_TryInterpret_enabled_in_replay()

-- CheckFiles tests
test_CheckFiles_executes_command()
test_CheckFiles_handles_return_value()
test_CheckFiles_handles_nil_return()
test_CheckFiles_sequential_commands()

-- Breakpoint tests
test_Breakpoint_disabled_in_multiplayer()
test_Breakpoint_with_disabled_breakpoint()
test_Breakpoint_starts_disabled()
test_Breakpoint_with_false_condition()
test_Breakpoint_not_yieldable()

print("\n============================================================")
print("ALL LIVECODING TESTS PASSED!")
print("============================================================\n")
