#!/usr/bin/env lua
--[[
    Standalone test file for Wc3Utils libraries
    This file can run on standard Lua without WC3 runtime

    Tests included:
    - test_AddEscaping (StringEscape)
    - test_RemoveEscaping (StringEscape)
    - test_roundtrip (StringEscape)
    - test_dumpLoad (Serializer)
    - test_sync (SyncStream)
    - test_saveLoad (Serializer with FileIO)

    All WC3 native functions are mocked in TestLib_mocks.lua
]]

-- Get the directory of this script
local scriptPath = debug.getinfo(1, "S").source:match("@(.*)$")
local scriptDir = scriptPath:match("(.*[\\/])") or "./"

-- Load WC3 mocks
dofile(scriptDir .. "TestLib_mocks.lua")

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
---@type any[]
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

---Helper function to run async tests in coroutines
---@param testName string
---@param testFunc fun()
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
        -- Resume any coroutines that are ready using the helper from mocks
        if coroutine.status(co) ~= "dead" and getRunningCoroutineCount() == 0 then
            error("Test " .. testName .. " is stuck with no coroutines waiting")
        end
        
        processTimersAndCoroutines()
        iterations = iterations + 1
    end
    
    if iterations >= maxIterations then
        error("Test " .. testName .. " timed out after " .. maxIterations .. " iterations")
    end
    
    -- Clean up any remaining coroutines after the test completes
    -- Note: Do NOT clear activeTimers as they may be needed by subsequent tests (e.g., SyncStream timer)
    clearRunningCoroutines()
    
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
runAsyncTest("test_saveLoad", function()
    test_saveLoad(origTable)
end)

print("\n============================================================")
print("ALL TESTS PASSED!")
print("============================================================\n")
