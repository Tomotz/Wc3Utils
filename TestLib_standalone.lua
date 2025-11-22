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
    endFile = function() end
}

LogWrite = function(...)
    print(...)
end

LogWriteNoFlush = function(...)
    print(...)
end

-- Mock OnInit - just store functions but don't execute them
OnInit = {
    map = function(func) end,
    global = function(func) end,
    trig = function(func) end,
    final = function(func) end
}

-- Mock WC3 natives needed for library loading
FourCC = function(code) return 0 end
Preload = function(data) end
PreloadGenClear = function() end
PreloadGenEnd = function(filename) end
Preloader = function(filename) end
BlzGetAbilityTooltip = function(abilityId, level) return '!@#$, empty data' end
BlzSetAbilityTooltip = function(abilityId, tooltip, level) end

-- Load libraries using dofile (no gsub stripping needed - Debug is mocked)
print("=== Loading StringEscape.lua ===")
dofile(scriptDir .. "lua/MyLibs/StringEscape.lua")

print("=== Loading FileIO.lua ===")
dofile(scriptDir .. "lua/MyLibs/FileIO.lua")

print("=== Loading Serializer.lua ===")
dofile(scriptDir .. "lua/MyLibs/Serializer.lua")

print("=== Loading TestLib.lua ===")
dofile(scriptDir .. "lua/TestLib.lua")

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

-- Run the standalone-compatible tests
print("\n============================================================")
print("RUNNING STANDALONE TESTS FOR WC3UTILS")
print("============================================================")

test_AddEscaping()
test_RemoveEscaping()
test_roundtrip()
test_dumpLoad(origTable)

print("\n============================================================")
print("ALL TESTS PASSED!")
print("============================================================\n")
