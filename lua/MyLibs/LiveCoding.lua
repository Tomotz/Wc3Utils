if Debug then Debug.beginFile("LiveCoding") end
--[[
Lua Live Coding v1.5.0 by Tomotz
This tool allows connecting to your game with an external cli, and run lua code in it - it allows you to open a windows terminal and run code inside your game. Works for single player and in replays

Features:
 - A cli interpreter that connects to your game while it's running, and runs lua code inside the game.
 - Write single line lua instructions in the terminal, and have them run inside the game.
 - Get command output in the terminal.
 - Run lua script files.
 - Run new code during replay and let you debug the replay.
 - Breakpoint support allowing you to debug in the breakpoint context.
Note that currently the interpreter does not support multiplayer (It will not run if there is more than one active player). Support for multiplayer can be added but will be a bit complicated since the backend files data needs to be synced. If I'll see a demand for the feature, I'll add it.

Installation and usage instructions:
 - Copy the lua code to your map and install the requirements.
 - Install python3 (tested with python 3.9 but would probably work with any python3 version)
 - pip install watchdog
 - Create wc3_interpreter.py script, and edit `CUSTOM_MAP_DATA_PATH` to point to your `CustomMapData` folder
 - In windows terminal run `python <full path>\wc3_interpreter.py` (type help for list of commands and usage)

 - Tip - if you want to debug a replay, run warcraft with nowfpause, and then you can alt tab to the shell without the game pausing:
    "C:\Program Files (x86)\Warcraft III\_retail_\x86_64\Warcraft III.exe" -launch -nowfpause

Run wc3_interpreter.py and then `help` for a list of available commands.
* Note: exiting or restarting the script while the game is running will cause a missalignment in file ids. You must use jump command to fix it

Algorithm explanation:
The lua code polls on the creation of new files with increasing indices (in0.txt, in1.txt, ...). When a new file is found, it reads the content, runs it as lua code, and saves the output to a single out.txt file with the command index.
For breakpoints, each coroutine writes its data to a per-coroutine file (bp_data_<thread_id>.txt) and a shared metadata file (bp_threads.txt) lists all active breakpoint threads.

Suggested usages:
 - Map Development - You created a new global function, you test your map and it doesn't do what you meant. You can now create a file with this function, edit what you wish, and run `file` command. The new function will run over the old one, and you can test it again without restarting wc3 and rebuilding the map. You can also add breakpoints to inspect and change variable values
 - Value Lookups - You can check variable values and other state checks while playing (in single player). You could already do that with DebugUtils `-console`, but this was annoying to do with the limited ingame chat. If you're playing in multiplayer, you can later check the values in the replay.
 - Map Debugging - Reimplement global functions dynamically while playing, and add prints and logs as needed
 - Replay Debugging - Perform quarries or make things happen differently at replay - change values of variables, create new units etc.

Requires:
My version of FileIO (lua). Original version by Trokkin - https://www.hiveworkshop.com/threads/fileio-lua-optimized.347049/
StringEscape (by me) - https://www.hiveworkshop.com/threads/optimized-syncstream-and-stringescape.367925/
TotalInitialization by Bribe - https://www.hiveworkshop.com/threads/total-initialization.317099/

Optionaly requires:
PrettyString (by me) - https://www.hiveworkshop.com/threads/logutils.357625/. If you want better output formatting for tables and wc3 handles

Credits:
TriggerHappy GameStatus (Replay Detection) https://www.hiveworkshop.com/threads/gamestatus-replay-detection.293176/
 * SetGameStatus was taken from there to allow detecting that the game is running in replay mode.
--]]

do
-- Period to check for new commands to execute
-- Note that once a command was executed, the polling period increases to 0.1 seconds to allow fast interpreting.
-- The period goes back to normal after no new commands were found for 60 seconds.
local PERIOD = 5
-- Directory to save the input/output files. Must match the python script path
local FILES_ROOT = "Interpreter"

-- The code will desync in multiplayer, so we only allow running it in single player or replay mode
local isDisabled ---@type boolean

EnabledBreakpoints = {} ---@type table<string, boolean> -- saves for each breakpoint id if it is disabled. Allows the debugger to disable/enable bps

-- Field separator for data files (ASCII 31 = unit separator)
local FIELD_SEP = string.char(31)

-- ============================================================================
-- Shared Output File Format
-- ============================================================================
-- Both normal commands and breakpoints use a similar output format:
-- For normal commands: out.txt contains "{index}SEPARATOR{result}"
-- For breakpoint results: bp_out.txt contains "{thread_id}:{cmd_index}SEPARATOR{result}"

--- Write a result to an output file with an index prefix
--- This is the shared format used by both normal commands and breakpoints
---@param filename string -- The output file path
---@param index string|integer -- The command index (or thread_id:cmd_index for breakpoints)
---@param result string -- The result to write
local function writeIndexedOutput(filename, index, result)
    FileIO.Save(filename, tostring(index) .. FIELD_SEP .. result, false)
end

--- Helper to format output for responses
---@param value any
---@return string
local function formatOutput(value)
    if PrettyString then
        return PrettyString(value)
    end
    return tostring(value)
end

--- Create an environment table that includes localVariables with globals as fallback
---@param localVariables {[1]: string, [2]: any}[]? -- Array of {name, value} pairs
---@return table
local function createBreakpointEnv(localVariables)
    local env = {}
    setmetatable(env, {__index = _G})
    if localVariables then
        for _, pair in ipairs(localVariables) do
            local name, value = pair[1], pair[2]
            env[name] = value
        end
    end
    return env
end

-- ============================================================================
-- Breakpoint System
-- ============================================================================
-- Breakpoints use per-coroutine data files and a shared metadata file:
-- - bp_threads.txt: Lists all thread IDs currently in a breakpoint (one per line)
-- - bp_data_<thread_id>.txt: Contains breakpoint data as a single FIELD_SEP-separated record:
--     bp_id<SEP>value<SEP>stack<SEP>stacktrace<SEP>var1<SEP>val1<SEP>var2<SEP>val2...
-- - bp_in_<thread_id>_<idx>.txt: Per-thread input commands (incrementing files due to WC3 file caching)
--     Content is just the raw command (no prefix needed since thread_id is in filename)
-- - bp_out.txt: Output results with format "thread_id:cmd_indexFIELD_SEPresult"

local activeBreakpointThreads = {} ---@type table<string, boolean> -- Maps thread_id to true if in breakpoint
local nextBreakpointCmdIndex = {} ---@type table<string, integer> -- Maps thread_id to next command index (persists across Breakpoint calls)

--- Get a unique identifier for the current coroutine
---@return string
local function getThreadId()
    local co = coroutine.running()
    if co then
        return tostring(co):match("thread: (.+)") or tostring(co)
    end
    return "main"
end

--- Update the bp_threads.txt metadata file with all active breakpoint threads
local function updateBreakpointThreadsFile()
    local threads = {}
    for threadId, _ in pairs(activeBreakpointThreads) do
        table.insert(threads, threadId)
    end
    FileIO.Save(FILES_ROOT .. "\\bp_threads.txt", table.concat(threads, FIELD_SEP), false)
end

--- Write breakpoint data file for a specific thread
--- Uses FIELD_SEP (ASCII 31) as field separator to avoid conflicts with variable values
--- Format: bp_id<SEP>value<SEP>stack<SEP>stacktrace<SEP>var1<SEP>val1<SEP>var2<SEP>val2...
---@param threadId string
---@param breakpointId string
---@param localVariables {[1]: string, [2]: any}[]? -- Array of {name, value} pairs
---@param env table? -- Environment table to read current values from (for modified variables)
local function writeBreakpointDataFile(threadId, breakpointId, localVariables, env)
    local fields = {}
    -- Add bp_id
    table.insert(fields, "bp_id")
    table.insert(fields, tostring(breakpointId))

    -- Add stacktrace (use Debug.traceback for WC3 compatibility)
    local stack = ""
    if Debug and Debug.traceback then
        stack = Debug.traceback() or ""
    end
    table.insert(fields, "stack")
    table.insert(fields, stack)

    -- Add local variable values in order (read from env if provided, otherwise from original pairs)
    if localVariables then
        for _, pair in ipairs(localVariables) do
            local name = pair[1]
            local value = env and env[name] or pair[2]
            table.insert(fields, name)
            table.insert(fields, formatOutput(value))
        end
    end

    FileIO.Save(FILES_ROOT .. "\\bp_data_" .. threadId .. ".txt", table.concat(fields, FIELD_SEP), false)
end

--- Remove breakpoint data file for a specific thread
---@param threadId string
local function removeBreakpointDataFile(threadId)
    -- Write empty content to indicate the breakpoint is no longer active
    FileIO.Save(FILES_ROOT .. "\\bp_data_" .. threadId .. ".txt", "", false)
end

-- Helper function to return all local variable values from the environment
---@param env table -- Environment table
---@param vars {[1]: string, [2]: any}[]? -- Array of {name, value} pairs
---@return any ...
local function returnLocalValues(env, vars)
    if not vars or #vars == 0 then return end
    local values = {}
    for _, pair in ipairs(vars) do
        local name = pair[1]
        table.insert(values, env[name])
    end
    return table.unpack(values)
end

---@param threadId string
---@param cmdIndex string|integer
---@param data string
local function writeBPOutput(threadId, cmdIndex, data)
    writeIndexedOutput(FILES_ROOT .. "\\bp_out.txt", threadId .. ":" .. cmdIndex, data)
end

--- Put a breakpoint in your code that will halt execution of a function and wait for external debugger instructions.
--- Returns the (potentially modified) local variable values in the same order as the input array.
--- Usage: `var1, var2 = Breakpoint(id, {{"var1", var1}, {"var2", var2}})`
---@param breakpointId string -- Unique id for the breakpoint. Used for auto breakpoints set from the debugger. When called from user code, it should contain a unique string to allow you to recognise the breakpoint.
---@param localVariables {[1]: string, [2]: any}[]? -- Array of {name, value} pairs. Will be used as the environment in the code called from the debugger. The values can be modified by the debugger and will be returned when the breakpoint continues.
---@param condition string? -- a string containing a lua expression. Breakpoint will only trigger if the expression is true.
---@param startsEnabled boolean? -- if false, the breakpoint will start disabled and must be enabled from the debugger. Default is true. This allows you to dynamically enable a static breakpoint (which can be set anywhere in the code unlike the dynamic one)
---@return any ... -- Returns the local variable values in the same order as the input array (potentially modified by the debugger)
--- Notes: 1. This function should only be called from yieldable context.
--- 2. Execution of the thread will not continue unless you connect the debugger, be sure not to keep breakpoints in your final code.
--- 3. To avoid desyncs, this function will do nothing in multiplayer
function Breakpoint(breakpointId, localVariables, condition, startsEnabled)
    -- Create environment with locals and globals accessible
    local env = createBreakpointEnv(localVariables)
    if isDisabled then return returnLocalValues(env, localVariables) end

    if not coroutine.isyieldable() then
        if Debug then Debug.throwError("Coroutine is not yieldable.") end
        return returnLocalValues(env, localVariables)
    end
    if EnabledBreakpoints[breakpointId] == nil then
        EnabledBreakpoints[breakpointId] = (startsEnabled == nil) or startsEnabled
    end
    if EnabledBreakpoints[breakpointId] == false then return returnLocalValues(env, localVariables) end

    if condition then
        local cond = load(condition, "breakpoint_condition", "t", env)
        if cond == nil then
            if Debug then Debug.throwError("error executing breakpoint condition") end
            return returnLocalValues(env, localVariables)
        end
        if not cond() then return returnLocalValues(env, localVariables) end
    end

    -- Get thread ID and register this breakpoint
    local threadId = getThreadId()
    activeBreakpointThreads[threadId] = true

    -- Write breakpoint data file and update metadata
    writeBreakpointDataFile(threadId, breakpointId, localVariables, env)
    updateBreakpointThreadsFile()

    -- Main breakpoint loop - wait for commands
    -- Uses per-thread incrementing bp_in_<threadId>_<idx>.txt files due to WC3 file caching
    -- Command index persists across Breakpoint() calls for the same thread to avoid reading stale files
    local cmdIndex = nextBreakpointCmdIndex[threadId] or 0
    while true do
        -- Check for commands in bp_in_<threadId>_<cmdIndex>.txt
        local filename = FILES_ROOT .. "\\bp_in_" .. threadId .. "_" .. cmdIndex .. ".txt"
        local command = FileIO.Load(filename)
        if command ~= nil then
            -- Command found - file content is just the raw command
            if command == "continue" then
                -- Acknowledge the continue command for the debugger protocol
                writeBPOutput(threadId, cmdIndex, "")
                -- Advance and persist the index so next Breakpoint() for this thread starts fresh
                nextBreakpointCmdIndex[threadId] = cmdIndex + 1
                -- Clean up and exit breakpoint
                activeBreakpointThreads[threadId] = nil
                removeBreakpointDataFile(threadId)
                updateBreakpointThreadsFile()
                -- Return the (potentially modified) local variable values
                return returnLocalValues(env, localVariables)
            end

            -- Execute the command with proper error handling
            local cur_func, loadErr = load(command, "breakpoint_cmd", "t", env)
            local outData
            if cur_func == nil then
                outData = "Syntax error: " .. tostring(loadErr)
            else
                local ok, result = pcall(cur_func)
                if ok then
                    outData = formatOutput(result)
                else
                    outData = "Runtime error: " .. tostring(result)
                end
            end

            -- Write result using shared format (thread_id:cmd_index as index)
            writeBPOutput(threadId, cmdIndex, outData)

            -- Update breakpoint data file (in case locals changed)
            writeBreakpointDataFile(threadId, breakpointId, localVariables, env)

            -- Advance and persist the index
            cmdIndex = cmdIndex + 1
        end
        TriggerSleepAction(0.1)
    end
end

-- ============================================================================
-- Normal Command System
-- ============================================================================
-- Uses single out.txt file with format: "{index}SEPARATOR{result}"

local nextFile = 0
local curPeriod = PERIOD
local lastCommandExecuteTime = 0
local timer = nil ---@type timer?

function CheckFiles()
    --- first we trigger the next run in case this run crashes or returns
    TimerStart(timer, curPeriod, false, CheckFiles)
    -- To make the replay as close as possible to the original game, we do call the timer on both, and just return right away if multiplayer
    if isDisabled then return end
    local commands = FileIO.Load(FILES_ROOT .. "\\in" .. nextFile .. ".txt")
    if commands ~= nil then
        -- command found, increase period to 0.1s, run the command and return the result
        curPeriod = 0.1
        TimerStart(timer, 0.1, false, CheckFiles)
        lastCommandExecuteTime = os.clock()
        local cur_func = load(commands)
        local result = nil
        if cur_func ~= nil then
            local ok = false
            ok, result = pcall(cur_func)
        end
        -- Use shared output format: index on first line, result on subsequent lines
        writeIndexedOutput(FILES_ROOT .. "\\out.txt", nextFile, tostring(result))
        nextFile = nextFile + 1
    end
    if os.clock() - lastCommandExecuteTime > 60 then
        -- over 60s passed since last command sent. Return the period to normal
        curPeriod = PERIOD
    end
end

---@param period number? -- Optional period in seconds for polling. Defaults to 5 seconds. Useful for testing with shorter periods.
function TryInterpret(period)
    isDisabled = ((not GameStatus) or GameStatus == GAME_STATUS_ONLINE) and (not bj_isSinglePlayer)
    -- Timer is leaked on purpose to keep it running throughout the entire game
    timer = CreateTimer()
    TimerStart(timer, period or 5, false, CheckFiles)
end

OnInit(function() TryInterpret(5) end)

end
if Debug then Debug.endFile() end
