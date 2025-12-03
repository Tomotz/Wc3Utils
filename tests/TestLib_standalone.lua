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
dofile(scriptDir .. "../lua/MyLibs/StringEscape.lua")

print("=== Loading FileIO.lua ===")
dofile(scriptDir .. "../lua/MyLibs/FileIO.lua")

print("=== Loading SyncStream.lua ===")
dofile(scriptDir .. "../lua/MyLibs/SyncStream.lua")

print("=== Loading Serializer.lua ===")
dofile(scriptDir .. "../lua/MyLibs/Serializer.lua")

print("=== Loading TestLib.lua ===")
dofile(scriptDir .. "../lua/TestLib.lua")

print("=== Executing OnInit callbacks ===")
executeOnInitCallbacks()

print("=== Libraries loaded successfully ===\n")

-- Get the standalone-compatible origTable from TestLib.lua
-- This avoids duplicating the table definition and ensures consistency
local origTable = TestLib_getStandaloneOrigTable()

-- Run the standalone-compatible tests
-- Note: runAsyncTest is provided by TestLib_mocks.lua
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
