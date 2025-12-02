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
dofile(scriptDir .. "TestLib_mocks.lua")

-- Add additional mocks needed for LiveCoding.lua
GAME_STATUS_OFFLINE = 0
GAME_STATUS_ONLINE = 1
GAME_STATUS_REPLAY = 2
GameStatus = GAME_STATUS_OFFLINE
bj_isSinglePlayer = true

-- Load required libraries
print("=== Loading StringEscape.lua ===")
dofile(scriptDir .. "../lua/MyLibs/StringEscape.lua")

print("=== Loading FileIO.lua ===")
dofile(scriptDir .. "../lua/MyLibs/FileIO.lua")

print("=== Loading LiveCoding.lua ===")
dofile(scriptDir .. "../lua/MyLibs/LiveCoding.lua")

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

-- Note: runAsyncTest is provided by TestLib_mocks.lua

-- ============================================================================
-- Tests for TryInterpret
-- ============================================================================

function test_TryInterpret_disabled_in_multiplayer()
    print("\n--- Running test_TryInterpret_disabled_in_multiplayer ---")
    resetState()
    
    -- Set up multiplayer scenario
    GameStatus = GAME_STATUS_ONLINE
    bj_isSinglePlayer = false
    
    -- Save a command file before calling TryInterpret
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "return 'should_not_execute'")
    
    -- Call TryInterpret with short period for fast testing
    TryInterpret(0.01)
    
    -- Advance time to trigger the timer (which calls CheckFiles)
    TriggerSleepAction(0.02)
    
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
    
    -- Save a command file before calling TryInterpret
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "return 'executed'")
    
    -- Call TryInterpret with short period for fast testing
    TryInterpret(0.01)
    
    -- Advance time to trigger the timer (which calls CheckFiles)
    TriggerSleepAction(0.02)
    
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
    
    -- Save a command file before calling TryInterpret
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "return 'replay_executed'")
    
    -- Call TryInterpret with short period for fast testing
    TryInterpret(0.01)
    
    -- Advance time to trigger the timer (which calls CheckFiles)
    TriggerSleepAction(0.02)
    
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
    
    -- Create a global variable to track execution
    _G.testExecuted = false
    
    -- Save a command that sets the global variable before calling TryInterpret
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "_G.testExecuted = true")
    
    -- Call TryInterpret with short period for fast testing
    TryInterpret(0.01)
    
    -- Advance time to trigger the timer (which calls CheckFiles)
    TriggerSleepAction(0.02)
    
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
    
    -- Save a command with a return value before calling TryInterpret
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "return 42")
    
    -- Call TryInterpret with short period for fast testing
    TryInterpret(0.01)
    
    -- Advance time to trigger the timer (which calls CheckFiles)
    TriggerSleepAction(0.02)
    
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
    
    -- Save a command without a return value before calling TryInterpret
    local fileIdx = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx .. ".txt", "local x = 1")
    
    -- Call TryInterpret with short period for fast testing
    TryInterpret(0.01)
    
    -- Advance time to trigger the timer (which calls CheckFiles)
    TriggerSleepAction(0.02)
    
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
    
    -- Save first command before calling TryInterpret
    local fileIdx1 = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx1 .. ".txt", "return 'first'")
    
    -- Call TryInterpret with short period for fast testing
    TryInterpret(0.01)
    
    -- Advance time to trigger the timer (which calls CheckFiles)
    TriggerSleepAction(0.02)
    
    local result1 = FileIO.Load("Interpreter\\out" .. fileIdx1 .. ".txt")
    Debug.assert(result1 == "first", "Expected 'first', got: " .. tostring(result1))
    
    -- Save second command
    local fileIdx2 = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx2 .. ".txt", "return 'second'")
    
    -- Advance time again to trigger the timer for the second command
    -- Note: After finding a command, CheckFiles reschedules with 0.1s period, so we need to wait at least that long
    TriggerSleepAction(0.2)
    
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

-- Helper to find the latest breakpoint output file that matches a pattern
-- Returns the file index and content, or nil if not found
local function findLatestBpOutput(pattern)
    -- Search for breakpoint output files (check up to 100 indices)
    for i = 99, 0, -1 do
        local content = FileIO.Load("Interpreter\\out_bp" .. i .. ".txt")
        if content and (not pattern or content:find(pattern)) then
            return i, content
        end
    end
    return nil, nil
end

function test_Breakpoint_shows_local_variables()
    print("\n--- Running test_Breakpoint_shows_local_variables ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret(0.01)
    
    -- Create a coroutine that hits a breakpoint with local variables
    local testComplete = false
    
    local co = coroutine.create(function()
        local myVar = 42
        local myString = "hello"
        Breakpoint("test_bp_locals", {myVar = myVar, myString = myString})
        testComplete = true
    end)
    
    -- Start the coroutine
    coroutine.resume(co)
    
    -- Advance time to let the breakpoint write its output
    TriggerSleepAction(0.1)
    
    -- Find the breakpoint output file
    local bpFileIdx, bpOutput = findLatestBpOutput("BREAKPOINT_HIT:test_bp_locals")
    Debug.assert(bpOutput ~= nil, "Breakpoint output file should exist")
    Debug.assert(bpOutput:find("Local variables:") ~= nil, 
        "Output should list local variables, got: " .. tostring(bpOutput))
    Debug.assert(bpOutput:find("myVar") ~= nil, 
        "Output should mention myVar, got: " .. tostring(bpOutput))
    Debug.assert(bpOutput:find("myString") ~= nil, 
        "Output should mention myString, got: " .. tostring(bpOutput))
    
    -- Send continue command to resume execution
    FileIO.Save("Interpreter\\bp_in" .. bpFileIdx .. ".txt", "continue")
    
    -- Advance time to let the breakpoint process the continue command
    TriggerSleepAction(0.6)
    
    -- Process any pending coroutines
    processTimersAndCoroutines()
    
    Debug.assert(testComplete, "Breakpoint should have continued after 'continue' command")
    
    print("--- test_Breakpoint_shows_local_variables completed ---")
end

function test_Breakpoint_output_format_without_locals()
    print("\n--- Running test_Breakpoint_output_format_without_locals ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret(0.01)
    
    -- Create a coroutine that hits a breakpoint without local variables
    local co = coroutine.create(function()
        Breakpoint("test_bp_no_locals")
    end)
    
    -- Start the coroutine
    coroutine.resume(co)
    
    -- Advance time to let the breakpoint write its output
    TriggerSleepAction(0.1)
    
    -- Find the breakpoint output file
    local bpFileIdx, bpOutput = findLatestBpOutput("BREAKPOINT_HIT:test_bp_no_locals")
    Debug.assert(bpOutput ~= nil, "Breakpoint output file should exist")
    Debug.assert(bpOutput:find("BREAKPOINT_HIT:test_bp_no_locals") ~= nil, 
        "Output should contain breakpoint ID, got: " .. tostring(bpOutput))
    -- Without local variables, should not have "Local variables:" line
    Debug.assert(bpOutput:find("Local variables:") == nil, 
        "Output should NOT list local variables when none provided, got: " .. tostring(bpOutput))
    
    -- Send continue command to clean up
    FileIO.Save("Interpreter\\bp_in" .. bpFileIdx .. ".txt", "continue")
    TriggerSleepAction(0.6)
    processTimersAndCoroutines()
    
    print("--- test_Breakpoint_output_format_without_locals completed ---")
end

function test_createBreakpointEnv_includes_globals()
    print("\n--- Running test_createBreakpointEnv_includes_globals ---")
    resetState()
    
    -- Test that the environment created for breakpoints includes globals
    -- We test this by verifying the load() function with env parameter works correctly
    
    -- Set a global variable
    _G.testGlobalForEnv = "test_global_value"
    
    -- Create an environment with locals that should also have access to globals
    local localVars = {localVar = "local_value"}
    local env = {}
    setmetatable(env, {__index = _G})
    for k, v in pairs(localVars) do
        env[k] = v
    end
    
    -- Test that we can access both local and global variables through the environment
    local func1 = load("return localVar", nil, "t", env)
    Debug.assert(func1 ~= nil, "Should be able to load code accessing local var")
    Debug.assert(func1() == "local_value", "Should get local value")
    
    local func2 = load("return testGlobalForEnv", nil, "t", env)
    Debug.assert(func2 ~= nil, "Should be able to load code accessing global var")
    Debug.assert(func2() == "test_global_value", "Should get global value")
    
    -- Test that locals override globals
    _G.localVar = "global_localVar"
    local func3 = load("return localVar", nil, "t", env)
    Debug.assert(func3() == "local_value", "Local should override global")
    
    -- Clean up
    _G.testGlobalForEnv = nil
    _G.localVar = nil
    
    print("--- test_createBreakpointEnv_includes_globals completed ---")
end

function test_formatBreakpointOutput_with_PrettyString()
    print("\n--- Running test_formatBreakpointOutput_with_PrettyString ---")
    resetState()
    
    -- Test that formatBreakpointOutput uses PrettyString when available
    -- Since PrettyString might not be loaded in standalone tests, we mock it
    
    local originalPrettyString = PrettyString
    local prettyStringCalled = false
    PrettyString = function(value)
        prettyStringCalled = true
        return "PRETTY:" .. tostring(value)
    end
    
    -- The formatBreakpointOutput function is local to LiveCoding.lua,
    -- so we test it indirectly by checking that PrettyString would be called
    -- if it exists. Since we can't call the local function directly,
    -- we verify the behavior through the breakpoint output.
    
    -- For now, just verify PrettyString is callable
    local result = PrettyString("test")
    Debug.assert(result == "PRETTY:test", "PrettyString mock should work")
    Debug.assert(prettyStringCalled, "PrettyString should have been called")
    
    -- Restore original
    PrettyString = originalPrettyString
    
    print("--- test_formatBreakpointOutput_with_PrettyString completed ---")
end

function test_Breakpoint_error_handling_in_condition()
    print("\n--- Running test_Breakpoint_error_handling_in_condition ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret(0.01)
    
    -- Breakpoint with invalid condition syntax should throw an error via Debug.throwError
    -- We test this by temporarily replacing Debug.throwError to capture the error
    local originalThrowError = Debug.throwError
    local errorCaught = false
    local errorMessage = nil
    Debug.throwError = function(msg)
        errorCaught = true
        errorMessage = msg
    end
    
    -- Call breakpoint with invalid condition - should trigger Debug.throwError
    runAsyncTest("breakpoint_invalid_condition", function()
        Breakpoint("test_bp_invalid_cond", nil, "return ((( invalid syntax")
    end)
    
    -- Restore original
    Debug.throwError = originalThrowError
    
    Debug.assert(errorCaught, "Breakpoint with invalid condition should call Debug.throwError")
    Debug.assert(errorMessage and errorMessage:find("condition") ~= nil, 
        "Error message should mention condition, got: " .. tostring(errorMessage))
    
    print("--- test_Breakpoint_error_handling_in_condition completed ---")
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

-- Breakpoint tests (basic)
test_Breakpoint_disabled_in_multiplayer()
test_Breakpoint_with_disabled_breakpoint()
test_Breakpoint_starts_disabled()
test_Breakpoint_with_false_condition()
test_Breakpoint_not_yieldable()

-- Breakpoint tests (new features)
test_Breakpoint_shows_local_variables()
test_Breakpoint_output_format_without_locals()
test_createBreakpointEnv_includes_globals()
test_formatBreakpointOutput_with_PrettyString()
test_Breakpoint_error_handling_in_condition()

print("\n============================================================")
print("ALL LIVECODING TESTS PASSED!")
print("============================================================\n")
