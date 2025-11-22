#!/usr/bin/env lua
--[[
    Standalone test file for Wc3Utils libraries
    This file can run on standard Lua without WC3 runtime
    
    Tests included:
    - test_AddEscaping (StringEscape)
    - test_RemoveEscaping (StringEscape)
    - test_roundtrip (StringEscape)
    - test_dumpLoad (Serializer)
]]

-- Mock Debug and LogWrite for standard Lua
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

-- Mock OnInit (not needed for these tests but included for compatibility)
OnInit = {
    final = function(func) end,
    global = function(func) end
}

-- Define FileIO_unsupportedLoadChars and FileIO_unsupportedSaveChars to match the actual library
-- These are the real values from FileIO.lua
FileIO_unsupportedLoadChars = {0, 10, 13, 92, 93} -- null terminator, line feed, carriage return, backslash, closing square bracket
FileIO_unsupportedSaveChars = {0} -- only null terminator

-- Define test-specific arrays for comprehensive StringEscape testing
-- These test a broader set of characters including opening bracket (91) and backslash in save mode (92)
local TEST_unsupportedLoadChars = {0, 10, 13, 91, 92, 93} -- includes opening bracket for testing
local TEST_unsupportedSaveChars = {0, 92} -- includes backslash for testing

-- Get the directory of this script
local scriptPath = debug.getinfo(1, "S").source:match("@(.*)$")
local scriptDir = scriptPath:match("(.*[\\/])") or "./"

print("=== Loading StringEscape.lua ===")
-- Load StringEscape library
do
    local stringEscapeFile = io.open(scriptDir .. "MyLibs/StringEscape.lua", "r")
    if not stringEscapeFile then
        error("Could not open StringEscape.lua at " .. scriptDir .. "MyLibs/StringEscape.lua")
    end
    local content = stringEscapeFile:read("*all")
    stringEscapeFile:close()
    
    -- Remove the Debug.beginFile/endFile wrappers
    content = content:gsub("if Debug then Debug%.beginFile%([^)]+%) end\n?", "")
    content = content:gsub("if Debug then Debug%.endFile%(%%) end\n?", "")
    
    local func, err = load(content, "StringEscape.lua")
    if not func then
        error("Failed to load StringEscape.lua: " .. tostring(err))
    end
    func()
end

print("=== Loading Serializer.lua ===")
-- Load Serializer library
do
    local serializerFile = io.open(scriptDir .. "MyLibs/Serializer.lua", "r")
    if not serializerFile then
        error("Could not open Serializer.lua at " .. scriptDir .. "MyLibs/Serializer.lua")
    end
    local content = serializerFile:read("*all")
    serializerFile:close()
    
    -- Remove the Debug.beginFile/endFile wrappers
    content = content:gsub("if Debug then Debug%.beginFile%([^)]+%) end\n?", "")
    content = content:gsub("if Debug then Debug%.endFile%(%%) end\n?", "")
    
    local func, err = load(content, "Serializer.lua")
    if not func then
        error("Failed to load Serializer.lua: " .. tostring(err))
    end
    func()
end

print("=== Libraries loaded successfully ===\n")

-- Helper function from TestLib.lua
--- Recursively compares two tables for deep equality.
---@param t1 table
---@param t2 table
---@param visited table? -- Used internally to track already compared tables
---@return boolean
function deepCompare(t1, t2, visited)
    -- If both are not tables, compare directly
    if type(t1) ~= type(t2) then
        Debug.throwError("deepCompare: tables not equal: " .. tostring(t1) .. " and " .. tostring(t2))
        return false
    end
    if type(t1) ~= "table" then
        if t1 == t2 then
            return true
        elseif type(t1) == "number" and math.abs(t1 - t2) < 0.00001 then
            return true
        end

        Debug.throwError("deepCompare: tables not equal: " .. tostring(t1) .. " and " .. tostring(t2))
        return false
    end

    -- Prevent infinite loops by tracking already visited tables
    visited = visited or {}
    if visited[t1] and visited[t2] then
        return true
    end
    visited[t1], visited[t2] = true, true

    -- Compare number of keys
    local keys1, keys2 = {}, {}
    local hasNil1, hasNil2 = false, false
    for k in pairs(t1) do
        if type(k) == "number" and math.floor(k) ~= k then
            --floats might lose some precision when converted to string, so we round them to 5 decimal places
            keys1[string.format("%.5f", k)] = true
        elseif type(k) == "nil" then
            hasNil1 = true
        else
            keys1[k] = true
        end
    end
    for k in pairs(t2) do
        if type(k) == "number" and math.floor(k) ~= k then
            --floats might lose some precision when converted to string, so we round them to 5 decimal places
            keys2[string.format("%.5f", k)] = true
        elseif type(k) == "nil" then
            hasNil2 = true
        else
            keys2[k] = true
        end
    end
    for k in pairs(keys1) do
        if not keys2[k] then
            Debug.throwError("deepCompare: tables not equal: key " .. tostring(k) .. " not found in second table")
            return false
        end
        if not deepCompare(t1[k], t2[k], visited) then return false end
    end
    if hasNil1 ~= hasNil2 then
        local which = hasNil1 and "first" or "second"
        Debug.throwError("deepCompare: tables not equal: " .. which .. " has nil keys and the other doesn't")
        return false
    end
    for k in pairs(keys2) do
        if not keys1[k] then
            Debug.throwError("deepCompare: tables not equal: key " .. tostring(k) .. " not found in first table")
            return false
        end
    end

    return true
end

-- Test functions from TestLib.lua

function test_AddEscaping()
    print("\n=== Running test_AddEscaping ===")
    local tests = {
        -- input, output with load chars escaped, output with save chars escaped
        {"hello", "hello", "hello"},
        {"\0\10\13\91\92\93", "\248\249\250\251\252\253", "\248\10\13\91\249\93"}, -- test_unsupported_chars replaced
        {"\247", "\247\247", "\247\247"}, -- escape_char doubled
        {"\248", "\247\248", "\247\248"},-- unprintable_replacables escaped
        {"\250", "\247\250", "\250"},
        {"hello\n\247\0world", "hello\249\247\247\248world", "hello\n\247\247\248world"},
        {"hello\250world", "hello\247\250world", "hello\250world"}
    }

    for i, test in ipairs(tests) do
        local input, expected1, expected2 = test[1], test[2], test[3]
        -- Use TEST_ arrays for comprehensive testing
        local result1 = AddEscaping(input, TEST_unsupportedLoadChars)
        Debug.assert(result1 == expected1, string.format("AddEscaping failed on test %d", i))
        
        local result2 = AddEscaping(input, TEST_unsupportedSaveChars)
        Debug.assert(result2 == expected2, string.format("AddEscaping failed on test %d", i))
    end
    LogWrite("All AddEscaping tests passed!")
end

function test_RemoveEscaping()
    print("\n=== Running test_RemoveEscaping ===")
    local tests = {
        {"hello", "hello", "hello"},
        {"\248\249\250\251\252\253", "\0\10\13\91\92\93", "\0\92\250\251\252\253"}, -- reversed replacements
        {"\247\247", "\247", "\247"}, -- double escape_char restored
        {"\247\248", "\248", "\248"}, -- escaped chars restored
        {"hello\249\247\247\248world", "hello\n\247\0world", "hello\92\247\0world"},
        {"hello\247\248world", "hello\248world", "hello\248world"}
    }

    for i, test in ipairs(tests) do
        local input, expected1, expected2 = test[1], test[2], test[3]
        -- Use TEST_ arrays for comprehensive testing
        local result = RemoveEscaping(input, TEST_unsupportedLoadChars)
        Debug.assert(result == expected1, string.format("RemoveEscaping failed on test %d: expected %q, got %q", i, expected1, result))
        local result2 = RemoveEscaping(input, TEST_unsupportedSaveChars)
        Debug.assert(result2 == expected2, string.format("RemoveEscaping failed on test %d: expected %q, got %q", i, expected2, result2))
    end
    LogWrite("All RemoveEscaping tests passed!")
end

function test_roundtrip()
    print("\n=== Running test_roundtrip ===")
    local tests = {
        "hello",
        "\0\13\91\92\93",
        "\247",
        "\248\249\250\251\252",
        "so\nme\247text\250here",
        "\247\248\249\250\251\252"
    }

    for i, test in ipairs(tests) do
        -- Use TEST_ arrays for comprehensive testing
        local escaped = AddEscaping(test, TEST_unsupportedLoadChars)
        local unescaped = RemoveEscaping(escaped, TEST_unsupportedLoadChars)
        Debug.assert(unescaped == test, string.format("Roundtrip failed on test %d: expected %q, got %q", i, test, unescaped))
        local escaped2 = AddEscaping(test, TEST_unsupportedSaveChars)
        local unescaped2 = RemoveEscaping(escaped2, TEST_unsupportedSaveChars)
        Debug.assert(unescaped2 == test, string.format("Roundtrip failed on test %d: expected %q, got %q", i, test, unescaped2))
    end
    LogWrite("All roundtrip tests passed!")
end

---@type any[]
-- Note: Modified from original TestLib.lua to work on both 32-bit (WC3) and 64-bit (standard) Lua
-- Removed negative numbers because the Serializer uses bitwise operations that behave differently
-- in 32-bit vs 64-bit Lua. Negative numbers are treated as unsigned in 32-bit Lua but not in 64-bit.
local origTable = {
    true,
    false,
    1,
    0,
    255,
    256^2 - 1,
    0x7FFFFFFF, -- the maximum positive 32-bit signed integer
    math.pi,
    "hello",
    "\0\10\13\91\92\93\248\249\250\251\252\253",
    string.rep("s", 257 ),
    "",
    -- string.rep("d", 256*175 ), -- this test is spamming the log so skipping it by default
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
    { largeNumbers = { 0x40000000, 0x7FFFFFFF, 1073741824, 536870912 } },  -- Large positive numbers (2^30, 2^31-1, 2^30, 2^29)
}

function test_dumpLoad()
    print("\n=== Running test_dumpLoad ===")
    local packedStr = Serializer.dumpVariable(origTable)
    LogWrite("writing done")
    if packedStr then
        LogWrite("Packed string length: " .. #packedStr)
    end
    local loadedVar, charsConsumed = Serializer.loadVariable(packedStr)
    LogWrite("load done")
    Debug.assert(loadedVar ~= nil, "loadVariable failed")
    Debug.assert(charsConsumed == #packedStr, "loadVariable didn't consume all characters. " .. tostring(charsConsumed) .. ", " .. tostring(#packedStr))
    Debug.assert(deepCompare(origTable, loadedVar), "loaded table doesn't match the original table")
    LogWrite("test_dumpLoad validation done!")
end

-- Run all tests
print("\n" .. string.rep("=", 60))
print("RUNNING STANDALONE TESTS FOR WC3UTILS")
print(string.rep("=", 60))

local success, err = pcall(function()
    test_AddEscaping()
    test_RemoveEscaping()
    test_roundtrip()
    test_dumpLoad()
end)

print("\n" .. string.rep("=", 60))
if success then
    print("ALL TESTS PASSED!")
else
    print("TEST FAILED WITH ERROR:")
    print(err)
    os.exit(1)
end
print(string.rep("=", 60))
