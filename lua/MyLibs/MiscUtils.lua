if Debug then Debug.beginFile("MiscUtils") end
do

--[[
MiscUtils v1.0.0 by Tomotz
  Small misc utilities that are used in my other libraries, or just weren't enough to warrent their own library.
  Some I wrote myself and some I borrowed from others

--- This hook is changing execute func to be a coroutine.
--- It also allows calling it with a function instead of a name, and passing args
--- to the function
function Hook:ExecuteFunc(func, ...)

--- Sets the GameStatus to one of GAME_STATUS_OFFLINE, GAME_STATUS_ONLINE, GAME_STATUS_REPLAY to let you know if you're running in replay/offline/online
GameStatus global variable

--- Get the time passed from game start
GetElapsedGameTime()

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

end
if Debug then Debug.endFile() end