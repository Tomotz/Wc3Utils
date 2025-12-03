#!/usr/bin/env lua
--[[
    End-to-End Lua Test Harness for wc3_interpreter.py
    
    This harness uses real file I/O to communicate with the Python interpreter
    through the file system, implementing the same protocol as LiveCoding.lua.
    
    Usage:
        lua e2e_lua_harness.lua <files_root> <test_name>
    
    The harness will:
    1. Set up real file I/O in <files_root>
    2. Run the specified test which hits breakpoints
    3. Poll for commands and respond via files (same protocol as LiveCoding.lua)
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

-- ============================================================================
-- File I/O Implementation (matches wc3_interpreter.py format)
-- ============================================================================

-- File format constants (must match wc3_interpreter.py)
-- Using [=[ ]=] delimiters to allow ]] inside the string
local FILE_PREFIX = [=[function PreloadFiles takes nothing returns nothing

	call PreloadStart()
	call Preload( "")
endfunction
//!beginusercode
local p={} local i=function(s) table.insert(p,s) end--[[" )
	]=]

local FILE_POSTFIX = [=[
	call Preload( "]]BlzSetAbilityTooltip(1095656547, table.concat(p), 0)
//!endusercode
function a takes nothing returns nothing
//" )
	call PreloadEnd( 0.1 )

endfunction

]=]

local LINE_PREFIX = '\n\tcall Preload( "]]i([['
local LINE_POSTFIX = ']])--[[" )'

-- Pattern to extract content from preload format (matches wc3_interpreter.py REGEX_PATTERN)
-- Lua pattern: %] escapes ], %[ escapes [, %. escapes ., %- escapes -
-- Matches: ]]i([[...]])--[[
local REGEX_PATTERN = '%]%]i%(%[%[(.-)%]%]%)%-%-%[%['

---Read a file in WC3 preload format (same format as wc3_interpreter.py load_file)
---@param filename string -- relative path within filesRoot
---@return string?
local function loadFile(filename)
    local fullPath = filesRoot .. filename
    local file = io.open(fullPath, "rb")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    
    -- Extract content from preload format (same as wc3_interpreter.py)
    local parts = {}
    for match in content:gmatch(REGEX_PATTERN) do
        table.insert(parts, match)
    end
    
    if #parts > 0 then
        return table.concat(parts)
    end
    
    return nil
end

---Write a file in WC3 preload format (same format as wc3_interpreter.py create_file)
---@param filename string -- relative path within filesRoot
---@param data string
local function createFile(filename, data)
    local fullPath = filesRoot .. filename
    local file = io.open(fullPath, "wb")
    if not file then
        error("Failed to create file: " .. fullPath)
    end
    
    -- Build content in preload format (same as wc3_interpreter.py)
    local content = FILE_PREFIX
    
    -- Split data into 255 byte chunks
    local pos = 1
    while pos <= #data do
        local chunk = data:sub(pos, pos + 254)
        content = content .. LINE_PREFIX .. chunk .. LINE_POSTFIX
        pos = pos + 255
    end
    
    content = content .. FILE_POSTFIX
    file:write(content)
    file:close()
end

---Write raw content to a file (for output files that don't need preload format)
---@param filename string -- relative path within filesRoot
---@param data string
local function writeRawFile(filename, data)
    local fullPath = filesRoot .. filename
    local file = io.open(fullPath, "wb")
    if not file then
        error("Failed to create file: " .. fullPath)
    end
    file:write(data)
    file:close()
end

-- ============================================================================
-- Breakpoint Protocol Implementation (matches LiveCoding.lua)
-- ============================================================================

-- Field separator for breakpoint data files (ASCII 31 = unit separator)
-- Must match FIELD_SEP in LiveCoding.lua and wc3_interpreter.py
local FIELD_SEP = string.char(31)

-- Active breakpoint threads
local activeBreakpointThreads = {}

---Get a unique identifier for the current coroutine
---@return string
local function getThreadId()
    local co = coroutine.running()
    if co then
        return tostring(co):match("thread: (.+)") or tostring(co)
    end
    return "main"
end

---Update the bp_threads.txt metadata file with all active breakpoint threads
local function updateBreakpointThreadsFile()
    local threads = {}
    for threadId, _ in pairs(activeBreakpointThreads) do
        table.insert(threads, threadId)
    end
    if #threads > 0 then
        writeRawFile("bp_threads.txt", table.concat(threads, "\n"))
    else
        writeRawFile("bp_threads.txt", "")
    end
end

---Write breakpoint data file for a specific thread
---Format: bp_id<SEP>value<SEP>stack<SEP>stacktrace<SEP>var1<SEP>val1<SEP>var2<SEP>val2...
---@param threadId string
---@param breakpointId string|integer
---@param localVariables table<string, any>?
local function writeBreakpointDataFile(threadId, breakpointId, localVariables)
    local fields = {}
    -- Add bp_id
    table.insert(fields, "bp_id")
    table.insert(fields, tostring(breakpointId))

    -- Add stacktrace
    local stack = debug.traceback("", 2) or ""
    table.insert(fields, "stack")
    local escapedStack = stack:gsub("\n", "\\n")
    table.insert(fields, escapedStack)

    -- Add local variable values
    if localVariables then
        for k, v in pairs(localVariables) do
            table.insert(fields, k)
            table.insert(fields, tostring(v))
        end
    end

    writeRawFile("bp_data_" .. threadId .. ".txt", table.concat(fields, FIELD_SEP))
end

---Remove breakpoint data file for a specific thread
---@param threadId string
local function removeBreakpointDataFile(threadId)
    writeRawFile("bp_data_" .. threadId .. ".txt", "")
end

---Write indexed output (format: "index\nresult")
---@param filename string
---@param index string|integer
---@param result string
local function writeIndexedOutput(filename, index, result)
    writeRawFile(filename, tostring(index) .. "\n" .. result)
end

-- EnabledBreakpoints table (matches LiveCoding.lua)
EnabledBreakpoints = {}

---Breakpoint function (matches LiveCoding.lua Breakpoint function)
---@param breakpointId integer|string
---@param localVariables table<string, any>?
---@param condition string?
---@param startsEnabled boolean?
local function Breakpoint(breakpointId, localVariables, condition, startsEnabled)
    if not coroutine.isyieldable() then
        error("Coroutine is not yieldable.")
    end
    
    if EnabledBreakpoints[breakpointId] == nil then
        EnabledBreakpoints[breakpointId] = (startsEnabled == nil) or startsEnabled
    end
    if EnabledBreakpoints[breakpointId] == false then return end
    
    -- Create environment with locals and globals accessible
    local env = {}
    setmetatable(env, {__index = _G})
    if localVariables then
        for k, v in pairs(localVariables) do
            env[k] = v
        end
    end
    
    if condition then
        local cond = load(condition, "breakpoint_condition", "t", env)
        if cond == nil then
            error("error executing breakpoint condition")
        end
        if not cond() then return end
    end

    -- Get thread ID and register this breakpoint
    local threadId = getThreadId()
    activeBreakpointThreads[threadId] = true
    print("Breakpoint hit: " .. tostring(breakpointId) .. " (thread: " .. threadId .. ")")

    -- Write breakpoint data file and update metadata
    writeBreakpointDataFile(threadId, breakpointId, localVariables)
    updateBreakpointThreadsFile()

    -- Main breakpoint loop - wait for commands
    local cmdIndex = 0
    while true do
        -- Check for commands in bp_in_<threadId>_<cmdIndex>.txt
        local filename = "bp_in_" .. threadId .. "_" .. cmdIndex .. ".txt"
        local command = loadFile(filename)
        if command ~= nil then
            print("Received command: " .. command)
            
            -- Command found - file content is just the raw command
            if command == "continue" then
                -- Clean up and exit breakpoint
                print("Continuing from breakpoint...")
                activeBreakpointThreads[threadId] = nil
                removeBreakpointDataFile(threadId)
                updateBreakpointThreadsFile()
                return
            end

            -- Execute the command with proper error handling
            local cur_func, loadErr = load(command, "breakpoint_cmd", "t", env)
            local outData
            if cur_func == nil then
                outData = "Syntax error: " .. tostring(loadErr)
            else
                local ok, result = pcall(cur_func)
                if ok then
                    outData = tostring(result)
                else
                    outData = "Runtime error: " .. tostring(result)
                end
            end

            print("Response: " .. outData)
            
            -- Write result using shared format (thread_id:cmd_index as index)
            writeIndexedOutput("bp_out.txt", threadId .. ":" .. cmdIndex, outData)

            -- Update breakpoint data file (in case locals changed)
            writeBreakpointDataFile(threadId, breakpointId, localVariables)

            cmdIndex = cmdIndex + 1
        end
        
        -- Small sleep to avoid busy waiting (0.1 seconds)
        os.execute("sleep 0.1")
        coroutine.yield()
    end
end

-- ============================================================================
-- Coroutine Management
-- ============================================================================

local runningCoroutines = {}

---Process pending coroutines
local function processCoroutines()
    local i = 1
    while i <= #runningCoroutines do
        local co = runningCoroutines[i]
        if coroutine.status(co) == "dead" then
            table.remove(runningCoroutines, i)
        else
            local success, err = coroutine.resume(co)
            if not success then
                print("Coroutine error: " .. tostring(err))
                table.remove(runningCoroutines, i)
            else
                i = i + 1
            end
        end
    end
end

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
        Breakpoint("basic_test", {gold = playerGold, level = playerLevel})
        print("Breakpoint continued!")
        testComplete = true
    end)
    
    -- Add to running coroutines
    table.insert(runningCoroutines, co)
    
    -- Start the coroutine
    print("Starting coroutine...")
    local success, err = coroutine.resume(co)
    if not success then
        error("Coroutine failed to start: " .. tostring(err))
    end
    
    -- The coroutine should now be waiting at the breakpoint
    print("Coroutine started, waiting for Python to interact...")
    
    -- Poll and process coroutines until test completes or timeout
    local maxIterations = 600  -- 60 seconds at 0.1s per iteration
    local iteration = 0
    while not testComplete and iteration < maxIterations do
        processCoroutines()
        
        -- Check if all coroutines are dead (test failed to complete)
        if #runningCoroutines == 0 and not testComplete then
            break
        end
        
        -- Small sleep to avoid busy waiting
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
        Breakpoint("conditional_test", {gold = gold}, "return gold > 500")
        print("Conditional breakpoint continued!")
        testComplete = true
    end)
    
    table.insert(runningCoroutines, co)
    
    local success, err = coroutine.resume(co)
    if not success then
        error("Coroutine failed to start: " .. tostring(err))
    end
    
    print("Coroutine started, waiting for Python to interact...")
    
    local maxIterations = 600
    local iteration = 0
    while not testComplete and iteration < maxIterations do
        processCoroutines()
        if #runningCoroutines == 0 and not testComplete then
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
        Breakpoint("conditional_false_test", {gold = gold}, "return gold > 500")
        print("Conditional breakpoint skipped (condition was false)!")
        testComplete = true
    end)
    
    table.insert(runningCoroutines, co)
    
    local success, err = coroutine.resume(co)
    if not success then
        error("Coroutine failed to start: " .. tostring(err))
    end
    
    -- This should complete immediately since condition is false
    processCoroutines()
    
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
        Breakpoint("disabled_test", nil, nil, false)  -- startsEnabled = false
        print("Disabled breakpoint skipped!")
        testComplete = true
    end)
    
    table.insert(runningCoroutines, co)
    
    local success, err = coroutine.resume(co)
    if not success then
        error("Coroutine failed to start: " .. tostring(err))
    end
    
    -- This should complete immediately since breakpoint is disabled
    processCoroutines()
    
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
