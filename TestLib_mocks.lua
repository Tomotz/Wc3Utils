--[[
    WC3 Native Function Mocks for Standalone Testing
    
    This file provides mock implementations of WC3-specific functions and globals
    to allow testing WC3 Lua libraries in a standard Lua environment.
    
    Mocked systems:
    - Debug utilities
    - Logging functions
    - OnInit framework
    - Player system
    - Timer system
    - Trigger and sync event system
    - File I/O (Preload/Preloader)
    - Ability tooltips
]]

-- ============================================================================
-- Debug System
-- ============================================================================

---@class DebugLib
---@field assert fun(condition:any, message?:string)
---@field throwError fun(...:any)
---@field beginFile fun()
---@field endFile fun()
---@field traceback fun():string

---@type DebugLib
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
    endFile = function() end,
    traceback = function()
        return debug.traceback("", 2)
    end
}

-- ============================================================================
-- Logging Functions
-- ============================================================================

---@param ... any
LogWrite = function(...)
    print(...)
end

---@param ... any
LogWriteNoFlush = function(...)
    print(...)
end

-- ============================================================================
-- OnInit Framework
-- ============================================================================

---@class OnInitCallbacks
---@field map fun()[]
---@field global fun()[]
---@field trig fun()[]
---@field final fun()[]

---@type OnInitCallbacks
local onInitCallbacks = {
    map = {},
    global = {},
    trig = {},
    final = {}
}

---@class OnInitLib
---@field map fun(func:fun())
---@field global fun(func:fun())
---@field trig fun(func:fun())
---@field final fun(func:fun())

---@type OnInitLib
OnInit = {
    map = function(func) table.insert(onInitCallbacks.map, func) end,
    global = function(func) table.insert(onInitCallbacks.global, func) end,
    trig = function(func) table.insert(onInitCallbacks.trig, func) end,
    final = function(func) table.insert(onInitCallbacks.final, func) end
}

---Execute all registered OnInit callbacks in order
function executeOnInitCallbacks()
    for _, func in ipairs(onInitCallbacks.map) do func() end
    for _, func in ipairs(onInitCallbacks.global) do func() end
    for _, func in ipairs(onInitCallbacks.trig) do func() end
    for _, func in ipairs(onInitCallbacks.final) do func() end
end

-- ============================================================================
-- WC3 Constants
-- ============================================================================

bj_MAX_PLAYER_SLOTS = 24 ---@type integer

-- ============================================================================
-- Player System
-- ============================================================================

---@class player
---@field _id integer
---@field _type string

---@type table<integer, player>
local playerObjects = {}

---@param id integer
---@return player
local function createPlayerObject(id)
    return {_id = id, _type = "player"}
end

for i = 0, bj_MAX_PLAYER_SLOTS - 1 do
    playerObjects[i] = createPlayerObject(i)
end

---@param id integer
---@return player
function Player(id)
    if not playerObjects[id] then
        playerObjects[id] = createPlayerObject(id)
    end
    return playerObjects[id]
end

---@param player player
---@return integer
function GetPlayerId(player)
    return player._id
end

---@return player
function GetLocalPlayer()
    return Player(0)
end

---@param player player
---@return string
function GetPlayerName(player)
    return "Player " .. player._id
end

-- ============================================================================
-- Timer System
-- ============================================================================

---@class timer
---@field _callback fun()?
---@field _timeout number
---@field _periodic boolean
---@field _active boolean
---@field _nextTrigger number

---@type timer[]
local activeTimers = {}

---@type number
local currentTime = 0

---@return timer
function CreateTimer()
    local timer = {
        _callback = nil,
        _timeout = 0,
        _periodic = false,
        _active = false,
        _nextTrigger = 0
    }
    return timer
end

---@param timer timer
---@param timeout number
---@param periodic boolean
---@param callback fun()
function TimerStart(timer, timeout, periodic, callback)
    timer._callback = callback
    timer._timeout = timeout
    timer._periodic = periodic
    timer._active = true
    timer._nextTrigger = currentTime + timeout
    -- Add timer to active timers list if not already there
    local found = false
    for _, t in ipairs(activeTimers) do
        if t == timer then
            found = true
            break
        end
    end
    if not found then
        table.insert(activeTimers, timer)
    end
end

---@param timer timer
function PauseTimer(timer)
    timer._active = false
end

---@param timer timer
function DestroyTimer(timer)
    for i, t in ipairs(activeTimers) do
        if t == timer then
            table.remove(activeTimers, i)
            break
        end
    end
end

-- ============================================================================
-- Trigger System
-- ============================================================================

---@class trigger
---@field _id integer
---@field _actions fun()[]
---@field _enabled boolean

---@type integer
local triggerIdCounter = 0

---@type table<integer, trigger>
local activeTriggers = {}

---@type table<string, {trigger:trigger, player:player}[]>
local syncEventHandlers = {}

---@class TriggerData
---@field player player?
---@field syncData string?

---@type TriggerData
local currentTriggerData = {
    player = nil,
    syncData = nil
}

---@return trigger
function CreateTrigger()
    triggerIdCounter = triggerIdCounter + 1
    local trigger = {
        _id = triggerIdCounter,
        _actions = {},
        _enabled = true
    }
    activeTriggers[trigger._id] = trigger
    return trigger
end

---@param trigger trigger
---@param action fun()
function TriggerAddAction(trigger, action)
    table.insert(trigger._actions, action)
end

---@param trigger trigger
---@param player player
---@param prefix string
---@param fromServer boolean
function BlzTriggerRegisterPlayerSyncEvent(trigger, player, prefix, fromServer)
    if not syncEventHandlers[prefix] then
        syncEventHandlers[prefix] = {}
    end
    table.insert(syncEventHandlers[prefix], {trigger = trigger, player = player})
end

---@return player
function GetTriggerPlayer()
    return currentTriggerData.player
end

---@return string
function BlzGetTriggerSyncData()
    return currentTriggerData.syncData
end

---@param trigger trigger
function DisableTrigger(trigger)
    trigger._enabled = false
end

---@param trigger trigger
function DestroyTrigger(trigger)
    activeTriggers[trigger._id] = nil
end

-- ============================================================================
-- Sync Data System
-- ============================================================================

---@param prefix string
---@param data string
---@return boolean
function BlzSendSyncData(prefix, data)
    local sender = GetLocalPlayer()
    
    local handlers = syncEventHandlers[prefix]
    if handlers then
        for _, handler in ipairs(handlers) do
            if handler.trigger._enabled and handler.player == sender then
                currentTriggerData.player = sender
                currentTriggerData.syncData = data
                
                for _, action in ipairs(handler.trigger._actions) do
                    action()
                end
                
                currentTriggerData.player = nil
                currentTriggerData.syncData = nil
            end
        end
    end
    return true
end

-- ============================================================================
-- Coroutine System
-- ============================================================================

---@class CoroutineData
---@field co thread
---@field resumeTime number

---@type CoroutineData[]
local runningCoroutines = {}

---@param duration number
function TriggerSleepAction(duration)
    local co = coroutine.running()
    
    currentTime = currentTime + duration
    
    for _, timer in ipairs(activeTimers) do
        while timer._active and timer._nextTrigger <= currentTime do
            if timer._callback then
                timer._callback()
            end
            if timer._periodic then
                timer._nextTrigger = timer._nextTrigger + timer._timeout
            else
                timer._active = false
                break
            end
        end
    end
    
    if not co then
        return
    end
    
    table.insert(runningCoroutines, {co = co, resumeTime = currentTime})
    coroutine.yield()
end

---Process pending coroutines that are ready to resume
---@return boolean -- true if any coroutines were processed
function processTimersAndCoroutines()
    local processed = false
    local i = 1
    while i <= #runningCoroutines do
        local coData = runningCoroutines[i]
        if coData.resumeTime <= currentTime then
            table.remove(runningCoroutines, i)
            local success, err = coroutine.resume(coData.co)
            if not success then
                error("Coroutine error: " .. tostring(err))
            end
            processed = true
        else
            i = i + 1
        end
    end
    return processed
end

---Get the count of running coroutines
---@return integer
function getRunningCoroutineCount()
    return #runningCoroutines
end

---Clear all running coroutines (for cleanup between tests)
function clearRunningCoroutines()
    runningCoroutines = {}
end

-- ============================================================================
-- File System (Preload/Preloader)
-- ============================================================================

---@type table<string, string>
local fileSystem = {}

---@param data string
function Preload(data)
    if not fileSystem._currentFile then
        fileSystem._currentFile = {}
    end
    table.insert(fileSystem._currentFile, data)
end

function PreloadGenClear()
    fileSystem._currentFile = {}
end

---@param filename string
function PreloadGenEnd(filename)
    if fileSystem._currentFile then
        fileSystem[filename] = table.concat(fileSystem._currentFile)
        fileSystem._currentFile = nil
    end
end

---@param filename string
function Preloader(filename)
    local content = fileSystem[filename]
    if content then
        local startMarker = "//!beginusercode\n"
        local endMarker = "\n//!endusercode"
        local startPos = content:find(startMarker, 1, true)
        local endPos = content:find(endMarker, 1, true)
        
        if startPos and endPos then
            local luaCode = content:sub(startPos + #startMarker, endPos - 1)
            
            local env = {
                BlzSetAbilityTooltip = BlzSetAbilityTooltip,
                ANdc = FourCC('ANdc'),
                table = table,
                string = string,
                math = math,
                print = print
            }
            setmetatable(env, {__index = _G})
            local func, err = load(luaCode, filename, "t", env)
            if func then
                local success, execErr = pcall(func)
                if not success then
                    print("Error executing Preloader content:", execErr)
                end
            else
                print("Error loading Preloader content:", err)
            end
        end
    end
end

-- ============================================================================
-- Ability Tooltip System
-- ============================================================================

---@type table<integer, string>
local abilityTooltips = {}

---@param abilityId integer
---@param level integer
---@return string
function BlzGetAbilityTooltip(abilityId, level)
    return abilityTooltips[abilityId] or '!@#$, empty data'
end

---@param abilityId integer
---@param tooltip string
---@param level integer
function BlzSetAbilityTooltip(abilityId, tooltip, level)
    abilityTooltips[abilityId] = tooltip
end

---Convert a 4-character code to an integer (FourCC)
---@param code string -- 4-character string
---@return integer
function FourCC(code)
    local out = 0
    for i = 1, #code do
        out = out * 0x100 + string.byte(code, i)
    end
    return out
end
