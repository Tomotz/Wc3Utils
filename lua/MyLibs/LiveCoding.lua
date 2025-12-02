if Debug then Debug.beginFile("LiveCoding") end
--[[
Lua Live Coding v1.1.0 by Tomotz
This tool allows connecting to your game with an external cli, and run lua code in it - it allows you to open a windows terminal and run code inside your game. Works for single player and in replays

Features:
 - A cli interpreter that connects to your game while it's running, and runs lua code inside the game.
 - Write single line lua instructions in the terminal, and have them run inside the game.
 - Get command output in the terminal.
 - Run lua script files.
 - Run new code during replay and let you debug the replay.
Note that currently the interpreter does not support multiplayer (It will not run if there is more than one active player). Support for multiplayer can be added but will be a bit complicated since the backend files data needs to be synced. If I'll see a demand for the feature, I'll add it.

Installation and usage instructions:
 - Copy the lua code to your map and install the requirements.
 - Install python3 (tested with python 3.9 but would probably work with any python3 version)
 - Create wc3_interpreter.py script, and edit `CUSTOM_MAP_DATA_PATH` to point to your `CustomMapData` folder
 - In windows terminal run `python ...\wc3_interpreter.py` (type help for list of commands and usage)
 - Tip - if you want to debug a replay, run warcraft with nowfpause, and then you can alt tab to the shell without the game pausing:
    "C:\Program Files (x86)\Warcraft III\_retail_\x86_64\Warcraft III.exe" -launch -nowfpause

cli commands:
 - help - Print all available commands and descriptions
 - exit - Exit the program
 - restart - Cleans the state to allow a new game to be started (this is the same as exiting and restarting the script)
 - file <full file path> - send a file with lua commands to the game. end the file with `return <data>` to print the data to the console
 - watch <full file path> - send a file to the game on each change. print the result just like `file`.
 - unwatch <full file path> - stop watching a file
 - watching - list all currently watched files
 - <lua command> - run a lua command in the game. If the command is a `return` statement, the result will be printed to the console.
* Note: exiting or restarting the script while the game is running will cause it to stop working until the game is also restarted **
Requires:

Algorithm explanation:
The lua code polls on the creation of new files with increasing indices (in0.txt, in1.txt, ...). When a new file is found, it reads the content, runs it as lua code, and saves the output to the corresponding outN.txt file.
For each command you type in the cli, the python script creates a files in the wc3 preload format and reads and prints the output file returned.

Suggested usages:
 - Map Development - You created a new global function, you test your map and it doesn't do what you meant. You can now create a file with this function, edit what you wish, and run `file` command. The new function will run over the old one, and you can test it again without restarting wc3 and rebuilding the map.
 - Value Lookups - You can check variable values and other state checks while playing (in single player). You could already do that with DebugUtils `-console`, but this was annoying to do with the limited ingame chat. If you're playing in multiplayer, you can later check the values in the replay.
 - Map Debugging - Reimplement global functions dynamically while playing, and add prints and logs as needed
 - Replay Debugging - Perform quarries or make things happen differently at replay - change values of variables, create new units etc.

Requires:
FileIO (lua) by Trokkin - https://www.hiveworkshop.com/threads/fileio-lua-optimized.347049/
TotalInitialization by Bribe - https://www.hiveworkshop.com/threads/total-initialization.317099/

To be able to run in replay mode of a multiplayer game, you either need
LogUtils (by me) - https://www.hiveworkshop.com/threads/logutils.357625/
or just to copy the `SetGameStatus` function from there and call it in your map init.

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

EnabledBreakpoints = {} ---@type table<string | integer, boolean> -- saves for each breakpoint id if it is disabled. Allows the debugger to disable/enable bps

local nextBpFile = 0

--- Helper to format output for breakpoint responses
---@param value any
---@return string
local function formatBreakpointOutput(value)
    if PrettyString then
        return PrettyString(value)
    end
    return tostring(value)
end

--- Create an environment table that includes localVariables with globals as fallback
---@param localVariables table<string, any>?
---@return table
local function createBreakpointEnv(localVariables)
    local env = {}
    setmetatable(env, {__index = _G})
    if localVariables then
        for k, v in pairs(localVariables) do
            env[k] = v
        end
    end
    return env
end

--- Put a breakpoint in your code that will halt execution of a function and wait for external debugger instructions.
---@param breakpointId integer | string -- Unique id for the breakpoint. Used for auto breakpoints set from the debugger. When called from user code, it should contain a unique string (that is not a number) to allow you to recognise the breakpoint.
---@param localVariables table<string, any>? -- a table mapping a local variable name to it's value. Will be used as the environment in the code called from the debugger. Note that for manual breakpoints, if you want to access locals from the debugger, you need to pass them here, and update them after the breakpoint finishes.
---@param condition string? -- a string containing a lua expression. Breakpoint will only trigger if the expression is true.
---@param startsEnabled boolean? -- if false, the breakpoint will start disabled and must be enabled from the debugger. Default is true. This allows you to dynamically enable a static breakpoint (which can be set anywhere in the code unlike the dynamic one)
--- Notes: 1. This function should only be called from yieldable context.
--- 2. Execution of the thread will not continue unless you connect the debugger, be sure not to keep breakpoints in your final code.
--- 3. To avoid desyncs, this function will do nothing in multiplayer
function Breakpoint(breakpointId, localVariables, condition, startsEnabled)
    if isDisabled then return end

    if not coroutine.isyieldable() then
        if Debug then
            Debug.throwError("Coroutine is not yieldable.")
        end
        return
    end
    if EnabledBreakpoints[breakpointId] == nil then
        EnabledBreakpoints[breakpointId] = (startsEnabled == nil) or startsEnabled
    end
    if EnabledBreakpoints[breakpointId] == false then return end
    if condition then
        local cond = load(condition)
        if cond == nil then
            if Debug then Debug.throwError("error executing breakpoint condition") end
            return
        end
        if not cond() then return end
    end

    -- Create environment with locals and globals accessible
    local env = createBreakpointEnv(localVariables)

    -- Initial output: breakpoint ID and available local variables
    local outData = "BREAKPOINT_HIT:" .. tostring(breakpointId)
    if localVariables then
        local varNames = {}
        for k, _ in pairs(localVariables) do
            table.insert(varNames, k)
        end
        if #varNames > 0 then
            outData = outData .. "\nLocal variables: " .. table.concat(varNames, ", ")
        end
    end

    while true do
        FileIO.Save(FILES_ROOT .. "\\out_bp" .. nextBpFile .. ".txt", outData)
        local commands = nil ---@type string?
        while true do
            commands = FileIO.Load(FILES_ROOT .. "\\bp_in" .. nextBpFile .. ".txt")
            if commands ~= nil then break end
            TriggerSleepAction(0.5)
        end
        nextBpFile = nextBpFile + 1
        if commands == "continue" then return end

        -- Execute the command with proper error handling
        local cur_func, loadErr = load(commands, "breakpoint_cmd", "t", env)
        if cur_func == nil then
            outData = "Syntax error: " .. tostring(loadErr)
        else
            local ok, result = pcall(cur_func)
            if ok then
                outData = formatBreakpointOutput(result)
            else
                outData = "Runtime error: " .. tostring(result)
            end
        end
    end
end

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
            result = cur_func()
        end
        FileIO.Save(FILES_ROOT .. "\\out" .. nextFile .. ".txt", tostring(result))
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

OnInit(TryInterpret)

end
if Debug then Debug.endFile() end
