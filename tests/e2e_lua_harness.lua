#!/usr/bin/env lua
--[[
    End-to-End Lua Test Harness for wc3_interpreter.py
    
    This harness loads the REAL LiveCoding.lua and uses TestLib_mocks.lua to simulate
    the WC3 environment. It uses FILEIO_MIRROR_ROOT to write files to disk so that
    the Python interpreter can read them.
    
    Usage:
        lua e2e_lua_harness.lua <files_root> <test_name>
    
    The harness will:
    1. Load TestLib_mocks.lua for WC3 API simulation
    2. Set FILEIO_MIRROR_ROOT so FileIO.Save mirrors to real OS files
    3. Load the real LiveCoding.lua (not a reimplementation)
    4. Run the specified test which hits breakpoints
    5. Use processTimersAndCoroutines() to drive the system
]]

-- Get command line arguments
local filesRoot = arg[1]
local testName = arg[2]

if not filesRoot or not testName then
    print("Usage: lua e2e_lua_harness.lua <files_root> <test_name>")
    os.exit(1)
end

-- Ensure filesRoot ends with separator
if not filesRoot:match("[/\\]$") then
    filesRoot = filesRoot .. "/"
end

print("E2E Lua Harness starting...")
print("Files root: " .. filesRoot)
print("Test name: " .. testName)

-- Create directory if it doesn't exist
os.execute('mkdir -p "' .. filesRoot .. '"')
os.execute('mkdir -p "' .. filesRoot .. 'Interpreter/"')

-- Get the directory of this script
local scriptPath = debug.getinfo(1, "S").source:match("@(.*)$")
local scriptDir = scriptPath:match("(.*[\\/])") or "./"

-- ============================================================================
-- Load WC3 Mocks (from TestLib_mocks.lua)
-- ============================================================================

print("=== Loading TestLib_mocks.lua ===")
dofile(scriptDir .. "TestLib_mocks.lua")

-- Set up game status globals needed by LiveCoding.lua
GAME_STATUS_OFFLINE = 0
GAME_STATUS_ONLINE = 1
GAME_STATUS_REPLAY = 2
GameStatus = GAME_STATUS_OFFLINE
bj_isSinglePlayer = true

-- ============================================================================
-- Set up FILEIO_MIRROR_ROOT for real file I/O
-- ============================================================================

-- This global tells FileIO.lua to mirror all file writes to real OS files
-- so that the Python interpreter can read them
FILEIO_MIRROR_ROOT = filesRoot

print("=== FILEIO_MIRROR_ROOT set to: " .. FILEIO_MIRROR_ROOT .. " ===")

-- ============================================================================
-- Load Required Libraries (the REAL ones, not reimplementations)
-- ============================================================================

print("=== Loading StringEscape.lua ===")
dofile(scriptDir .. "../lua/MyLibs/StringEscape.lua")

print("=== Loading FileIO.lua ===")
dofile(scriptDir .. "../lua/MyLibs/FileIO.lua")

print("=== Loading LiveCoding.lua ===")
dofile(scriptDir .. "../lua/MyLibs/LiveCoding.lua")

print("=== Executing OnInit callbacks ===")
executeOnInitCallbacks()

print("=== Libraries loaded successfully ===")

-- ============================================================================
-- Test Functions
-- ============================================================================

local testResults = {
    passed = 0,
    failed = 0,
    errors = {}
}

-- Test: Basic breakpoint with locals
local function test_breakpoint_basic()
    print("Starting breakpoint_basic test...")
    
    -- Create a coroutine that hits a breakpoint
    local testComplete = false
    local co = coroutine.create(function()
        local playerGold = 1000
        local playerLevel = 5
        print("About to hit breakpoint with gold=" .. playerGold .. ", level=" .. playerLevel)
        -- Use the REAL Breakpoint function from LiveCoding.lua
        Breakpoint("basic_test", {gold = playerGold, level = playerLevel})
        print("Breakpoint continued!")
        testComplete = true
    end)
    
    -- Start the coroutine
    print("Starting coroutine...")
    local success, err = coroutine.resume(co)
    if not success then
        error("Coroutine failed to start: " .. tostring(err))
    end
    
    -- The coroutine should now be waiting at the breakpoint
    print("Coroutine started, waiting for Python to interact...")
    
    -- Poll and process timers/coroutines until test completes or timeout
    -- Use processTimersAndCoroutines from TestLib_mocks.lua
    local maxIterations = 600  -- 60 seconds at 0.1s per iteration
    local iteration = 0
    while not testComplete and iteration < maxIterations do
        -- Advance time and process timers/coroutines
        TriggerSleepAction(0.1)
        processTimersAndCoroutines()
        
        -- Check if coroutine is dead (test failed to complete)
        if coroutine.status(co) == "dead" and not testComplete then
            break
        end
        
        -- Small sleep to avoid busy waiting (real time, not simulated)
        os.execute("sleep 0.1")
        iteration = iteration + 1
    end
    
    if not testComplete then
        error("Test did not complete - breakpoint was not continued (iterations: " .. iteration .. ")")
    end
    
    print("Test completed successfully!")
end

-- Test: Conditional breakpoint (true condition)
local function test_breakpoint_conditional_true()
    print("Starting breakpoint_conditional_true test...")
    
    local testComplete = false
    local co = coroutine.create(function()
        local gold = 600
        print("About to hit conditional breakpoint with gold=" .. gold .. " (condition: gold > 500)")
        -- Use the REAL Breakpoint function from LiveCoding.lua
        Breakpoint("conditional_test", {gold = gold}, "return gold > 500")
        print("Conditional breakpoint continued!")
        testComplete = true
    end)
    
    local success, err = coroutine.resume(co)
    if not success then
        error("Coroutine failed to start: " .. tostring(err))
    end
    
    print("Coroutine started, waiting for Python to interact...")
    
    local maxIterations = 600
    local iteration = 0
    while not testComplete and iteration < maxIterations do
        TriggerSleepAction(0.1)
        processTimersAndCoroutines()
        if coroutine.status(co) == "dead" and not testComplete then
            break
        end
        os.execute("sleep 0.1")
        iteration = iteration + 1
    end
    
    if not testComplete then
        error("Test did not complete - breakpoint was not continued")
    end
    
    print("Test completed successfully!")
end

-- Test: Conditional breakpoint (false condition - should not block)
local function test_breakpoint_conditional_false()
    print("Starting breakpoint_conditional_false test...")
    
    local testComplete = false
    local co = coroutine.create(function()
        local gold = 400
        print("About to hit conditional breakpoint with gold=" .. gold .. " (condition: gold > 500)")
        -- Use the REAL Breakpoint function from LiveCoding.lua
        Breakpoint("conditional_false_test", {gold = gold}, "return gold > 500")
        print("Conditional breakpoint skipped (condition was false)!")
        testComplete = true
    end)
    
    local success, err = coroutine.resume(co)
    if not success then
        error("Coroutine failed to start: " .. tostring(err))
    end
    
    -- This should complete immediately since condition is false
    TriggerSleepAction(0.1)
    processTimersAndCoroutines()
    
    if not testComplete then
        error("Test did not complete - conditional breakpoint should have been skipped")
    end
    
    print("Test completed successfully!")
end

-- Test: Disabled breakpoint (should not block)
local function test_breakpoint_disabled()
    print("Starting breakpoint_disabled test...")
    
    local testComplete = false
    local co = coroutine.create(function()
        print("About to hit disabled breakpoint")
        -- Use the REAL Breakpoint function from LiveCoding.lua
        Breakpoint("disabled_test", nil, nil, false)  -- startsEnabled = false
        print("Disabled breakpoint skipped!")
        testComplete = true
    end)
    
    local success, err = coroutine.resume(co)
    if not success then
        error("Coroutine failed to start: " .. tostring(err))
    end
    
    -- This should complete immediately since breakpoint is disabled
    TriggerSleepAction(0.1)
    processTimersAndCoroutines()
    
    if not testComplete then
        error("Test did not complete - disabled breakpoint should have been skipped")
    end
    
    print("Test completed successfully!")
end

-- ============================================================================
-- Main Entry Point
-- ============================================================================

local function runTest(name, func)
    print("\n=== Running test: " .. name .. " ===")
    local success, err = pcall(func)
    if success then
        testResults.passed = testResults.passed + 1
        print("=== Test " .. name .. " PASSED ===")
    else
        testResults.failed = testResults.failed + 1
        table.insert(testResults.errors, {name = name, error = err})
        print("=== Test " .. name .. " FAILED: " .. tostring(err) .. " ===")
    end
end

print("\n=== E2E Lua Harness Ready ===")
print("Running test: " .. testName)

if testName == "breakpoint_basic" then
    runTest("breakpoint_basic", test_breakpoint_basic)
elseif testName == "breakpoint_conditional_true" then
    runTest("breakpoint_conditional_true", test_breakpoint_conditional_true)
elseif testName == "breakpoint_conditional_false" then
    runTest("breakpoint_conditional_false", test_breakpoint_conditional_false)
elseif testName == "breakpoint_disabled" then
    runTest("breakpoint_disabled", test_breakpoint_disabled)
else
    print("Unknown test: " .. testName)
    os.exit(1)
end

-- Print results
print("\n=== Test Results ===")
print("Passed: " .. testResults.passed)
print("Failed: " .. testResults.failed)

if testResults.failed > 0 then
    print("\nErrors:")
    for _, err in ipairs(testResults.errors) do
        print("  " .. err.name .. ": " .. err.error)
    end
    os.exit(1)
end

os.exit(0)
