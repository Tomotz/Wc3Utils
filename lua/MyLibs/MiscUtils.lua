if Debug then Debug.beginFile("MiscUtils") end
do

--[[
MiscUtils v1.0.0 by Tomotz
  Small misc utilities that are used in my other libraries, or just weren't enough to warrant their own library.
  Some I wrote myself and some I borrowed from others

--- This hook is changing execute func to be a coroutine.
--- It also allows calling it with a function instead of a name, and passing args
--- to the function
function Hook:ExecuteFunc(func, ...)

--- Sets the GameStatus to one of GAME_STATUS_OFFLINE, GAME_STATUS_ONLINE, GAME_STATUS_REPLAY to let you know if you're running in replay/offline/online
GameStatus global variable

--- Get the time passed from game start
GetElapsedGameTime()

--- Handle chat commands - listens to any user input starting with "-". Splits the input by spaces and calls the appropriate handler function with the command arguments and the trigger player as arguments.
HandleChatCmd()

Updated: Nov 2025
--]]

---@param func string | function
---@vararg any
--- This hook is changing execute func to be a coroutine.
--- It also allows calling it with a function instead of a name, and passing args
--- to the function
---@diagnostic disable-next-line: duplicate-set-field
function Hook:ExecuteFunc(func, ...)
    if type(func) == 'string' then
        func = _G[func]
    end
    local co = coroutine.create(func)
    coroutine.resume(co, ...)
end

---@param val number
---@return integer
function Round(val)
    return math.floor(val + .5)
end

do --- Table and Array Helpers
---@param arr any[]
---@param value any
---@return integer? -- first index of value occurrence in arr or nil if not found
function ArrayFind(arr, value)
    for i, v in ipairs(arr) do
        if v == value then
            return i -- Return index if found
        end
    end
    return nil -- Return nil if not found
end

---@param arr any[]
---@param value any
---@return any? -- the removed value or nil if not found
--- removes the first occurance of value in arr
function ArrayRemove(arr, value)
    local index = ArrayFind(arr, value)
    if index then
        return table.remove(arr, index)
    end
    return nil
end

function SyncedTable:ToIndexedTables()
    local t = {}
    t[1] = {}
    t[2] = {}
    local i = 1
    for k,v in pairs(self) do
        t[1][i] = k
        t[2][i] = v
        i = i + 1
    end
    return t
end

function SyncedTable.FromIndexedTables(tbl)
    local new = SyncedTable.create()
    for i = 1, #tbl[1] do
        new[tbl[1][i]] = tbl[2][i]
    end
    return new
end
end  --- Table and Array Helpers

do --- Game Status Detection (Online/Offline/Replay)
-- Useful globals that tells you if the game is offline (single player I think), online or replay.
-- The first 3 are constants and should not be changed
GAME_STATUS_OFFLINE = 0
GAME_STATUS_ONLINE = 1
GAME_STATUS_REPLAY = 2
GameStatus = 0 -- one of GAME_STATUS_OFFLINE, GAME_STATUS_ONLINE, GAME_STATUS_REPLAY

-- sets GameStatus variable which decides if game is online, offline or replay
local function SetGameStatus()
    local firstPlayer ---@type player
    local u ---@type unit
    local selected ---@type boolean

    -- find an actual player
    firstPlayer = Player(0)
    while not ((GetPlayerController(firstPlayer) == MAP_CONTROL_USER and GetPlayerSlotState(firstPlayer) == PLAYER_SLOT_STATE_PLAYING)) do
        firstPlayer = Player(GetPlayerId(firstPlayer) + 1)
    end
    -- force the player to select a dummy unit
    u = CreateUnit(firstPlayer, FourCC('hfoo'), 0, 0, 0)
    SelectUnit(u, true)
    selected = IsUnitSelected(u, firstPlayer)
    RemoveUnit(u)
    if (selected) then
        -- detect if replay or offline game
        if (ReloadGameCachesFromDisk()) then
            GameStatus = GAME_STATUS_OFFLINE
        else
            GameStatus = GAME_STATUS_REPLAY
        end
    else
        -- if the unit wasn't selected instantly, the game is online
        GameStatus = GAME_STATUS_ONLINE
    end
end
OnInit.global(SetGameStatus)


local gametime_initialized = false
local gameStartTimer ---@type timer
---@return real
function GetElapsedGameTime()
    if not gametime_initialized then return 0 end
    return TimerGetElapsed(gameStartTimer)
end

OnInit.global(function()
    gametime_initialized = true
    gameStartTimer = CreateTimer()
    TimerStart(gameStartTimer, 0xF4240, false, nil)
end)
end --- Game Status Detection

do --- Chat Command Handler
--- Handle chat commands - listens to any user input starting with "-". Splits the input by spaces and calls the appropriate handler function with the command arguments and the trigger player as arguments.

-- Table mapping event chat command to their handler functions
local chatHandlers = {}

function StrSplitBySpace(str)
    local result = {}
    for word in string.gmatch(str, "\x25S+") do
        table.insert(result, word)
    end
    return result
end

function HandleChatCmd()
    local triggerPlayer = GetTriggerPlayer() ---@type player
    local chatStr = GetEventPlayerChatString()
    local spliced = StrSplitBySpace(chatStr)
    local cmd = string.lower(spliced[1])
    table.remove(spliced, 1)
    local args = spliced
    if chatHandlers[cmd] then
        chatHandlers[cmd](triggerPlayer, args)
    end
end

-- can't init some of these things in the root as the functions are not all defined yet
-- the functions here can get the command arguments, and the trigger player as args
OnInit.trig(function()
    local ChatCmdTrigger = CreateTrigger()
    TriggerAddAction(ChatCmdTrigger, HandleChatCmd)
    for i = 0, GetBJMaxPlayers() - 1 do
        TriggerRegisterPlayerChatEvent(ChatCmdTrigger, Player(i), "-", false)
    end

    chatHandlers =  {
        ["-d"] = DumpRecentWrap,
        ["-s"] = CreateUnitForPlayer,
        ["-c"] = CrashTest,
        ["-e"] = TestEscaping,
        ["-se"] = TestSerializer,
        ["-sy"] = TestSyncStream,
        ["-o"] = TestOrigSync,
        ["-f"] = FlushLog,
    }
end)
end --- Chat Command Handler

end
if Debug then Debug.endFile() end
