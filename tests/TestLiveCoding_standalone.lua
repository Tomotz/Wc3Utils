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
    
        -- The output file should not exist or not have the expected index because the interpreter is disabled
        -- Note: Output files are saved with isLoadable=false, so we use getRawFileContent
        local result = getRawFileContent("Interpreter\\out.txt")
        -- Either no file exists, or the index doesn't match (meaning our command wasn't processed)
        if result then
            local index = result:match("^(%d+)\n")
            Debug.assert(index ~= tostring(fileIdx), "Expected no output in multiplayer for index " .. fileIdx .. ", got index: " .. tostring(index))
        end
    
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
    
    -- The output file should exist with the result in new format: "index\nresult"
    -- Note: Output files are saved with isLoadable=false, so we use getRawFileContent
    local result = getRawFileContent("Interpreter\\out.txt")
    Debug.assert(result ~= nil, "Output file should exist")
    local index, value = result:match("^(%d+)\n(.*)$")
    Debug.assert(index == tostring(fileIdx), "Expected index " .. fileIdx .. ", got: " .. tostring(index))
    Debug.assert(value == "executed", "Expected 'executed', got: " .. tostring(value))
    
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
    
    -- The output file should exist with the result in new format: "index\nresult"
    -- Note: Output files are saved with isLoadable=false, so we use getRawFileContent
    local result = getRawFileContent("Interpreter\\out.txt")
    Debug.assert(result ~= nil, "Output file should exist")
    local index, value = result:match("^(%d+)\n(.*)$")
    Debug.assert(index == tostring(fileIdx), "Expected index " .. fileIdx .. ", got: " .. tostring(index))
    Debug.assert(value == "replay_executed", "Expected 'replay_executed', got: " .. tostring(value))
    
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
    
    -- Verify the output file contains the return value in new format: "index\nresult"
    -- Note: Output files are saved with isLoadable=false, so we use getRawFileContent
    local result = getRawFileContent("Interpreter\\out.txt")
    Debug.assert(result ~= nil, "Output file should exist")
    local index, value = result:match("^(%d+)\n(.*)$")
    Debug.assert(index == tostring(fileIdx), "Expected index " .. fileIdx .. ", got: " .. tostring(index))
    Debug.assert(value == "42", "Expected '42', got: " .. tostring(value))
    
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
    
    -- Verify the output file contains "nil" in new format: "index\nresult"
    -- Note: Output files are saved with isLoadable=false, so we use getRawFileContent
    local result = getRawFileContent("Interpreter\\out.txt")
    Debug.assert(result ~= nil, "Output file should exist")
    local index, value = result:match("^(%d+)\n(.*)$")
    Debug.assert(index == tostring(fileIdx), "Expected index " .. fileIdx .. ", got: " .. tostring(index))
    Debug.assert(value == "nil", "Expected 'nil', got: " .. tostring(value))
    
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
    
    -- Note: Output files are saved with isLoadable=false, so we use getRawFileContent
    local result1 = getRawFileContent("Interpreter\\out.txt")
    Debug.assert(result1 ~= nil, "Output file should exist")
    local index1, value1 = result1:match("^(%d+)\n(.*)$")
    Debug.assert(index1 == tostring(fileIdx1), "Expected index " .. fileIdx1 .. ", got: " .. tostring(index1))
    Debug.assert(value1 == "first", "Expected 'first', got: " .. tostring(value1))
    
    -- Save second command
    local fileIdx2 = getNextFileIndex()
    FileIO.Save("Interpreter\\in" .. fileIdx2 .. ".txt", "return 'second'")
    
    -- Advance time again to trigger the timer for the second command
    -- Note: After finding a command, CheckFiles reschedules with 0.1s period, so we need to wait at least that long
    TriggerSleepAction(0.2)
    
    -- Note: Output files are saved with isLoadable=false, so we use getRawFileContent
    local result2 = getRawFileContent("Interpreter\\out.txt")
    Debug.assert(result2 ~= nil, "Output file should exist")
    local index2, value2 = result2:match("^(%d+)\n(.*)$")
    Debug.assert(index2 == tostring(fileIdx2), "Expected index " .. fileIdx2 .. ", got: " .. tostring(index2))
    Debug.assert(value2 == "second", "Expected 'second', got: " .. tostring(value2))
    
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

-- Helper to get the list of threads currently in a breakpoint
local function getBreakpointThreads()
    -- Note: bp_threads.txt is saved with isLoadable=false, so we use getRawFileContent
    local content = getRawFileContent("Interpreter\\bp_threads.txt")
    if not content or content == "" then
        return {}
    end
    local threads = {}
    for thread in content:gmatch("[^\n]+") do
        table.insert(threads, thread)
    end
    return threads
end

-- Field separator for breakpoint data files (ASCII 31 = unit separator)
-- Must match FIELD_SEP in LiveCoding.lua
local FIELD_SEP = string.char(31)

-- Track breakpoint input file index (matches nextBpFile in LiveCoding.lua)
-- Per-thread command indices for bp_in files (maps threadId -> next index)
local bpCommandIndices = {}

-- Helper to get breakpoint data for a specific thread
-- Returns a table with bp_id, locals (list derived from locals_values keys), stack, and locals_values (table)
-- File format is a single FIELD_SEP-separated record:
--   bp_id<SEP>value<SEP>stack<SEP>stacktrace<SEP>var1<SEP>val1<SEP>var2<SEP>val2...
local function getBreakpointData(threadId)
    -- Note: bp_data files are saved with isLoadable=false, so we use getRawFileContent
    local content = getRawFileContent("Interpreter\\bp_data_" .. threadId .. ".txt")
    if not content or content == "" then
        return nil
    end
    local data = {locals_values = {}}
    -- Split by FIELD_SEP and parse in pairs
    local parts = {}
    for part in (content .. FIELD_SEP):gmatch("([^" .. FIELD_SEP .. "]*)" .. FIELD_SEP) do
        table.insert(parts, part)
    end
    -- Remove the last empty element from the trailing separator
    if #parts > 0 and parts[#parts] == "" then
        table.remove(parts)
    end
    
    local i = 1
    while i + 1 <= #parts do
        local key, value = parts[i], parts[i + 1]
        i = i + 2
        if key == "bp_id" then
            data.bp_id = value
        elseif key == "stack" then
            data.stack = value:gsub("\\n", "\n")
        elseif key then
            -- Local variable value
            data.locals_values[key] = value
        end
    end
    -- Derive locals list from locals_values keys
    data.locals = {}
    for k, _ in pairs(data.locals_values) do
        table.insert(data.locals, k)
    end
    return data
end

-- Helper to find a thread with a specific breakpoint ID
local function findThreadWithBreakpoint(bpId)
    local threads = getBreakpointThreads()
    for _, threadId in ipairs(threads) do
        local data = getBreakpointData(threadId)
        if data and data.bp_id == bpId then
            return threadId, data
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
    
    -- Find the thread with our breakpoint using new file format
    local threadId, bpData = findThreadWithBreakpoint("test_bp_locals")
    Debug.assert(threadId ~= nil, "Should find thread in breakpoint")
    Debug.assert(bpData ~= nil, "Breakpoint data file should exist")
    Debug.assert(bpData.bp_id == "test_bp_locals", "bp_id should match")
    Debug.assert(bpData.locals ~= nil, "Should have locals list")
    
    -- Check that local variables are listed
    local hasMyVar = false
    local hasMyString = false
    for _, var in ipairs(bpData.locals or {}) do
        if var == "myVar" then hasMyVar = true end
        if var == "myString" then hasMyString = true end
    end
    Debug.assert(hasMyVar, "Output should list myVar")
    Debug.assert(hasMyString, "Output should list myString")
    
    -- Check local variable values
    Debug.assert(bpData.locals_values["myVar"] == "42", 
        "myVar should be 42, got: " .. tostring(bpData.locals_values["myVar"]))
    Debug.assert(bpData.locals_values["myString"] == "hello", 
        "myString should be 'hello', got: " .. tostring(bpData.locals_values["myString"]))
    
    -- Send continue command to resume execution using per-thread bp_in files
    -- Format: bp_in_<threadId>_<idx>.txt with just the raw command
    local cmdIdx = bpCommandIndices[threadId] or 0
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "continue")
    bpCommandIndices[threadId] = cmdIdx + 1
    
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
    
    -- Find the thread with our breakpoint using new file format
    local threadId, bpData = findThreadWithBreakpoint("test_bp_no_locals")
    Debug.assert(threadId ~= nil, "Should find thread in breakpoint")
    Debug.assert(bpData ~= nil, "Breakpoint data file should exist")
    Debug.assert(bpData.bp_id == "test_bp_no_locals", "bp_id should match")
    -- Without local variables, locals list should be empty
    Debug.assert(bpData.locals ~= nil and #bpData.locals == 0, 
        "Output should have empty locals list when none provided")
    
    -- Send continue command to clean up using per-thread bp_in files
    -- Format: bp_in_<threadId>_<idx>.txt with just the raw command
    local cmdIdx = bpCommandIndices[threadId] or 0
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "continue")
    bpCommandIndices[threadId] = cmdIdx + 1
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
-- Breakpoint Test: Basic breakpoint with local variables
-- Tests:
-- 1. Breakpoint triggers and creates data file
-- 2. Inspect locals (return gold, return level)
-- 3. Modify variables (gold = 2000 then return gold)
-- 4. Continue execution
-- ============================================================================

function test_Breakpoint_basic_with_locals()
    print("\n--- Running test_Breakpoint_basic_with_locals ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret(0.01)
    
    local testComplete = false
    
    -- Create a coroutine that hits a basic breakpoint
    local co = coroutine.create(function()
        local playerGold = 1000
        local playerLevel = 5
        Breakpoint("basic_test", {gold = playerGold, level = playerLevel})
        testComplete = true
    end)
    
    -- Start the coroutine
    coroutine.resume(co)
    
    -- Advance time to let the breakpoint write its output
    TriggerSleepAction(0.1)
    
    -- Find the breakpoint
    local threadId, bpData = findThreadWithBreakpoint("basic_test")
    Debug.assert(threadId ~= nil, "Should find thread in basic_test breakpoint")
    Debug.assert(bpData ~= nil, "Breakpoint data file should exist for basic_test")
    Debug.assert(bpData.bp_id == "basic_test", "bp_id should be 'basic_test'")
    
    -- Test: Inspect locals - check gold value
    Debug.assert(bpData.locals_values["gold"] == "1000", 
        "gold should be 1000, got: " .. tostring(bpData.locals_values["gold"]))
    
    -- Test: Inspect locals - check level value
    Debug.assert(bpData.locals_values["level"] == "5", 
        "level should be 5, got: " .. tostring(bpData.locals_values["level"]))
    
    -- Test: Execute Lua code to inspect locals (return gold)
    local cmdIdx = bpCommandIndices[threadId] or 0
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "return gold")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.2)
    resumeOneCoroutine()  -- Resume breakpoint coroutine once to process command
    
    -- Note: bp_out.txt is saved with isLoadable=false, so we use getRawFileContent
    local bpOutContent = getRawFileContent("Interpreter\\bp_out.txt")
    Debug.assert(bpOutContent ~= nil, "bp_out.txt should exist after command")
    local outIndex, outResult = bpOutContent:match("^([^\n]+)\n(.*)$")
    Debug.assert(outResult == "1000", "return gold should give 1000, got: " .. tostring(outResult))
    
    -- Test: Execute Lua code to inspect locals (return level)
    cmdIdx = bpCommandIndices[threadId]
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "return level")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.2)
    resumeOneCoroutine()  -- Resume breakpoint coroutine once to process command
    
    -- Note: bp_out.txt is saved with isLoadable=false, so we use getRawFileContent
    bpOutContent = getRawFileContent("Interpreter\\bp_out.txt")
    outIndex, outResult = bpOutContent:match("^([^\n]+)\n(.*)$")
    Debug.assert(outResult == "5", "return level should give 5, got: " .. tostring(outResult))
    
    -- Test: Modify variables (gold = 2000 then return gold)
    cmdIdx = bpCommandIndices[threadId]
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "gold = 2000")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.2)
    resumeOneCoroutine()  -- Resume breakpoint coroutine once to process command
    
    cmdIdx = bpCommandIndices[threadId]
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "return gold")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.2)
    resumeOneCoroutine()  -- Resume breakpoint coroutine once to process command
    
    -- Note: bp_out.txt is saved with isLoadable=false, so we use getRawFileContent
    bpOutContent = getRawFileContent("Interpreter\\bp_out.txt")
    outIndex, outResult = bpOutContent:match("^([^\n]+)\n(.*)$")
    Debug.assert(outResult == "2000", "return gold after modification should give 2000, got: " .. tostring(outResult))
    
    -- Test: Continue execution
    cmdIdx = bpCommandIndices[threadId]
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "continue")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.6)
    resumeOneCoroutine()  -- Resume breakpoint coroutine once to process continue
    
    -- Verify test completed
    Debug.assert(testComplete, "Test function should have completed after continue")
    
    print("--- test_Breakpoint_basic_with_locals completed ---")
end

-- ============================================================================
-- Breakpoint Test: Conditional breakpoint (only triggers if condition is true)
-- ============================================================================

function test_Breakpoint_conditional_true()
    print("\n--- Running test_Breakpoint_conditional_true ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret(0.01)
    
    local testComplete = false
    
    -- Create a coroutine that hits a conditional breakpoint with true condition
    local co = coroutine.create(function()
        local gold = 600  -- Greater than 500, so condition should be true
        Breakpoint("conditional_true_test", {gold = gold}, "return gold > 500")
        testComplete = true
    end)
    
    -- Start the coroutine
    coroutine.resume(co)
    
    -- Advance time to let the breakpoint trigger
    TriggerSleepAction(0.1)
    
    -- The breakpoint should have triggered because gold (600) > 500
    local threadId, bpData = findThreadWithBreakpoint("conditional_true_test")
    Debug.assert(threadId ~= nil, "conditional_true_test should trigger (gold=600 > 500)")
    Debug.assert(bpData ~= nil, "Breakpoint data file should exist")
    Debug.assert(bpData.bp_id == "conditional_true_test", "bp_id should be 'conditional_true_test'")
    Debug.assert(bpData.locals_values["gold"] == "600", 
        "gold should be 600, got: " .. tostring(bpData.locals_values["gold"]))
    
    -- Continue from breakpoint
    local cmdIdx = bpCommandIndices[threadId] or 0
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "continue")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.6)
    resumeOneCoroutine()
    
    -- Verify test completed
    Debug.assert(testComplete, "Test should complete after continue")
    
    print("--- test_Breakpoint_conditional_true completed ---")
end

-- ============================================================================
-- Breakpoint Test: Dynamic enable/disable using EnabledBreakpoints
-- ============================================================================

function test_Breakpoint_dynamic_enable_disable()
    print("\n--- Running test_Breakpoint_dynamic_enable_disable ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret(0.01)
    
    local testComplete = false
    
    -- Create a coroutine that hits a dynamic breakpoint
    local co = coroutine.create(function()
        Breakpoint("dynamic_test", {status = "testing"})
        testComplete = true
    end)
    
    -- Start the coroutine
    coroutine.resume(co)
    
    -- Advance time to let the breakpoint trigger
    TriggerSleepAction(0.1)
    
    -- Find the breakpoint
    local threadId, bpData = findThreadWithBreakpoint("dynamic_test")
    Debug.assert(threadId ~= nil, "Should find thread in dynamic_test breakpoint")
    Debug.assert(bpData ~= nil, "Breakpoint data file should exist for dynamic_test")
    Debug.assert(bpData.bp_id == "dynamic_test", "bp_id should be 'dynamic_test'")
    Debug.assert(bpData.locals_values["status"] == "testing", 
        "status should be 'testing', got: " .. tostring(bpData.locals_values["status"]))
    
    -- Test: Disable the breakpoint dynamically using EnabledBreakpoints
    local cmdIdx = bpCommandIndices[threadId] or 0
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "EnabledBreakpoints.dynamic_test = false")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.2)
    resumeOneCoroutine()  -- Resume breakpoint coroutine once to process command
    
    -- Verify the breakpoint is now disabled
    cmdIdx = bpCommandIndices[threadId]
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "return EnabledBreakpoints.dynamic_test")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.2)
    resumeOneCoroutine()  -- Resume breakpoint coroutine once to process command
    
    -- Note: bp_out.txt is saved with isLoadable=false, so we use getRawFileContent
    local bpOutContent = getRawFileContent("Interpreter\\bp_out.txt")
    local outIndex, outResult = bpOutContent:match("^([^\n]+)\n(.*)$")
    Debug.assert(outResult == "false", "EnabledBreakpoints.dynamic_test should be false, got: " .. tostring(outResult))
    
    -- Continue from breakpoint
    cmdIdx = bpCommandIndices[threadId]
    FileIO.Save("Interpreter\\bp_in_" .. threadId .. "_" .. cmdIdx .. ".txt", "continue")
    bpCommandIndices[threadId] = cmdIdx + 1
    TriggerSleepAction(0.6)
    resumeOneCoroutine()  -- Resume breakpoint coroutine once to process continue
    
    -- Verify test completed
    Debug.assert(testComplete, "Test function should have completed after continue")
    
    -- Verify the breakpoint is still disabled (persists after continue)
    Debug.assert(EnabledBreakpoints["dynamic_test"] == false, "dynamic_test should remain disabled")
    
    print("--- test_Breakpoint_dynamic_enable_disable completed ---")
end

-- ============================================================================
-- Test conditional breakpoint with false condition (should not trigger)
-- ============================================================================

function test_Breakpoint_conditional_false()
    print("\n--- Running test_Breakpoint_conditional_false ---")
    resetState()
    
    -- Enable interpreter
    GameStatus = GAME_STATUS_OFFLINE
    bj_isSinglePlayer = true
    TryInterpret(0.01)
    
    local testComplete = false
    
    -- Create a coroutine that hits a conditional breakpoint that should NOT trigger
    local co = coroutine.create(function()
        local gold = 400  -- Less than 500, so condition should be false
        Breakpoint("conditional_false_test", {gold = gold}, "return gold > 500")
        testComplete = true
    end)
    
    -- Start the coroutine
    coroutine.resume(co)
    
    -- Advance time - the coroutine should complete immediately since condition is false
    TriggerSleepAction(0.2)
    
    -- The breakpoint should NOT have triggered because gold (400) is not > 500
    local threadId, bpData = findThreadWithBreakpoint("conditional_false_test")
    Debug.assert(threadId == nil, "conditional_false_test should NOT trigger (gold=400 < 500)")
    
    -- The test should have completed without blocking
    Debug.assert(testComplete, "Test should complete without blocking on false condition")
    
    print("--- test_Breakpoint_conditional_false completed ---")
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
test_Breakpoint_error_handling_in_condition()

-- Comprehensive breakpoint tests (each scenario tested separately)
test_Breakpoint_basic_with_locals()
test_Breakpoint_conditional_true()
test_Breakpoint_conditional_false()
test_Breakpoint_dynamic_enable_disable()

print("\n============================================================")
print("ALL LIVECODING TESTS PASSED!")
print("============================================================\n")
