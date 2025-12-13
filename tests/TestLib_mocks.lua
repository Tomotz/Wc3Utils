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

---Mock require function for OnInit callbacks
---In DawnOfTheDead, OnInit.final("name", function(require) ...) passes a require function
---that waits for dependencies. In our mock, we just use the global require.
---@param moduleName string
local function mockOnInitRequire(moduleName)
    -- The DawnOfTheDead OnInit require just ensures dependencies are loaded
    -- In our mock environment, we don't need to do anything special
    -- The modules should already be loaded or will be loaded by executeOnInitCallbacks
end

---Helper to handle both OnInit.xxx(func) and OnInit.xxx("name", func) patterns
---@param callbacks table
---@return fun(nameOrFunc: string|fun(), func?: fun())
local function makeOnInitHandler(callbacks)
    return function(nameOrFunc, func)
        if type(nameOrFunc) == "function" then
            table.insert(callbacks, nameOrFunc)
        elseif type(nameOrFunc) == "string" and type(func) == "function" then
            table.insert(callbacks, func)
        end
    end
end

---@type OnInitLib
OnInit = setmetatable({
    map = makeOnInitHandler(onInitCallbacks.map),
    global = makeOnInitHandler(onInitCallbacks.global),
    trig = makeOnInitHandler(onInitCallbacks.trig),
    final = makeOnInitHandler(onInitCallbacks.final)
}, {
    -- Allow OnInit to be called directly as OnInit(func), which defaults to OnInit.final
    __call = function(_, nameOrFunc, func)
        if type(nameOrFunc) == "function" then
            table.insert(onInitCallbacks.final, nameOrFunc)
        elseif type(nameOrFunc) == "string" and type(func) == "function" then
            table.insert(onInitCallbacks.final, func)
        end
    end
})

---Execute all registered OnInit callbacks in order
---Passes mockOnInitRequire to callbacks that expect a require function
function executeOnInitCallbacks()
    for _, func in ipairs(onInitCallbacks.map) do func(mockOnInitRequire) end
    for _, func in ipairs(onInitCallbacks.global) do func(mockOnInitRequire) end
    for _, func in ipairs(onInitCallbacks.trig) do func(mockOnInitRequire) end
    for _, func in ipairs(onInitCallbacks.final) do func(mockOnInitRequire) end
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
    local co, isMain = coroutine.running()

    -- Save the resume time BEFORE advancing currentTime
    -- This ensures the coroutine waits for the next time advancement
    local resumeTime = currentTime + duration
    currentTime = currentTime + duration

    for _, timer in ipairs(activeTimers) do
        while timer._active and timer._nextTrigger <= currentTime do
            -- Save the nextTrigger before callback in case callback reschedules
            local triggerTimeBefore = timer._nextTrigger
            if timer._callback then
                timer._callback()
            end
            -- Only deactivate if the timer wasn't rescheduled by the callback
            -- (i.e., nextTrigger is still the same as before the callback)
            if timer._periodic then
                timer._nextTrigger = timer._nextTrigger + timer._timeout
            elseif timer._nextTrigger == triggerTimeBefore then
                -- Timer wasn't rescheduled by callback, so deactivate it
                timer._active = false
                break
            else
                -- Timer was rescheduled by callback (nextTrigger changed), keep it active
                break
            end
        end
    end

    -- In Lua 5.3+, coroutine.running() returns (thread, isMain) where isMain is true for main thread
    -- Don't yield if we're in the main thread or not in a coroutine
    if not co or isMain then
        return
    end

    table.insert(runningCoroutines, {co = co, resumeTime = resumeTime})
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

---Resume one coroutine that's ready to resume
---This is useful for breakpoint tests where we want to resume the breakpoint coroutine
---once to process a command, without getting stuck in an infinite loop
---@return boolean -- true if a coroutine was resumed
function resumeOneCoroutine()
    local i = 1
    while i <= #runningCoroutines do
        local coData = runningCoroutines[i]
        if coData.resumeTime <= currentTime then
            table.remove(runningCoroutines, i)
            local success, err = coroutine.resume(coData.co)
            if not success then
                error("Coroutine error: " .. tostring(err))
            end
            return true  -- Only resume one coroutine
        else
            i = i + 1
        end
    end
    return false
end

-- ============================================================================
-- File System (Preload/Preloader)
-- ============================================================================

-- Optional: Set this global to a directory path to mirror file writes to real OS files.
-- Used by E2E tests where Python needs to read files written by Lua.
-- Default is nil (no mirroring). Only set this in test environments.
---@type string?
MOCK_FILE_MIRROR_ROOT = MOCK_FILE_MIRROR_ROOT or nil

-- Optional: Set this global to true to capture the last Preload content to a global variable.
-- When enabled, the raw content (before wrapping) is stored in MOCK_PRELOAD_LAST_CONTENT.
-- This is useful for tests that need to access the generated save code directly.
---@type boolean?
MOCK_PRELOAD_CAPTURE_ENABLED = MOCK_PRELOAD_CAPTURE_ENABLED or nil

-- Stores the last content captured by Preload when MOCK_PRELOAD_CAPTURE_ENABLED is true.
-- This contains the raw concatenated chunks before any wrapping.
---@type string?
MOCK_PRELOAD_LAST_CONTENT = nil

-- Optional: Set this global to true to capture the data passed to FileIO.Save.
-- When enabled, the raw data (before FileIO wrapping) is stored in MOCK_FILEIO_SAVE_LAST_DATA.
-- This is useful for tests that need to access the exact data passed to FileIO.Save.
---@type boolean?
MOCK_FILEIO_SAVE_CAPTURE_ENABLED = MOCK_FILEIO_SAVE_CAPTURE_ENABLED or nil

-- Stores the last data captured by FileIO.Save when MOCK_FILEIO_SAVE_CAPTURE_ENABLED is true.
---@type string?
MOCK_FILEIO_SAVE_LAST_DATA = nil

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

---Build a proper WC3 preload file from chunks
---@param chunks string[] -- The chunks to wrap
---@param endTime number -- The time value for PreloadEnd
---@return string -- The full preload file content
local function buildPreloadFileFromChunks(chunks, endTime)
    local lines = {}
    table.insert(lines, "function PreloadFiles takes nothing returns nothing")
    table.insert(lines, "")
    table.insert(lines, "\tcall PreloadStart()")
    for _, chunk in ipairs(chunks) do
        -- WC3's Preload native places the content directly inside the quotes
        -- without escaping. The content may contain quotes that close the string
        -- early, which is intentional for the loadable file format.
        table.insert(lines, '\tcall Preload( "' .. chunk .. '" )')
    end
    table.insert(lines, string.format("\tcall PreloadEnd( %.1f )", endTime))
    table.insert(lines, "")
    table.insert(lines, "endfunction")
    return table.concat(lines, "\n")
end

---@param filename string
function PreloadGenEnd(filename)
    if fileSystem._currentFile then
        local chunks = fileSystem._currentFile
        local isLoadable = false
        -- Check if this is a loadable file by looking for the beginusercode marker in the first chunk
        if #chunks > 0 and chunks[1]:find("//!beginusercode", 1, true) then
            isLoadable = true
        end

        -- Capture raw content to global variable if enabled
        -- This stores the concatenated chunks before any wrapping
        if MOCK_PRELOAD_CAPTURE_ENABLED then
            MOCK_PRELOAD_LAST_CONTENT = table.concat(chunks)
        end

        local content
        if isLoadable then
            -- For loadable files, wrap in proper WC3 preload format
            -- Use a higher endTime value that matches typical save files
            content = buildPreloadFileFromChunks(chunks, 4500.2)
        else
            -- For nonloadable files, wrap in proper WC3 preload format
            content = buildPreloadFileFromChunks(chunks, 0.0)
        end

        fileSystem[filename] = content
        fileSystem._currentFile = nil

        -- Mirror to real OS files if MOCK_FILE_MIRROR_ROOT is set (for E2E tests)
        if MOCK_FILE_MIRROR_ROOT then
            pcall(function()
                -- Normalize path separators (WC3 uses backslashes, OS may use forward slashes)
                local normalized = filename:gsub("\\", "/")
                local full = MOCK_FILE_MIRROR_ROOT .. normalized
                -- Create parent directory if needed
                local dir = full:match("^(.*)/[^/]+$")
                if dir then
                    os.execute('mkdir -p "' .. dir .. '"')
                end
                local f = io.open(full, "wb")
                if f then
                    f:write(content)
                    f:close()
                end
            end)
        end
    end
end

---@param filename string
function Preloader(filename)
    local content = fileSystem[filename]

    -- If MOCK_FILE_MIRROR_ROOT is set and file not in memory, try to read from disk
    if not content and MOCK_FILE_MIRROR_ROOT then
        local normalized = filename:gsub("\\", "/")
        local full = MOCK_FILE_MIRROR_ROOT .. normalized
        local f = io.open(full, "rb")
        if f then
            content = f:read("*all")
            f:close()
            -- Store in memory for future access
            -- Only cache non-empty content to avoid negative caching
            -- (empty files may be written later with actual content)
            if content and #content > 0 then
                fileSystem[filename] = content
            else
                content = nil
            end
        end
    end

    if content and #content > 0 then
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

---Parse nonloadable file content and extract the payload from preload wrapper
---Handles payloads with newlines and doubled quotes ("") inside
---@param content string -- The raw file content with preload wrapper
---@return string? -- The extracted payload, or nil if parsing fails
local function parseNonloadableContent(content)
    if not content then return nil end
    local payload = {}
    local pos = 1
    while true do
        -- Find the start of a Preload call and the opening quote
        local callStart, quoteStart = content:find('call Preload%(%s*"', pos)
        if not callStart then break end

        local i = quoteStart + 1
        local buf = {}

        while i <= #content do
            local c = content:sub(i, i)
            if c == '"' then
                local nextc = content:sub(i + 1, i + 1)
                if nextc == '"' then
                    -- Doubled quote inside the string, keep both quotes
                    table.insert(buf, '""')
                    i = i + 2
                else
                    -- This is the closing quote before the ` )`
                    break
                end
            else
                table.insert(buf, c)
                i = i + 1
            end
        end

        table.insert(payload, table.concat(buf))
        pos = i + 1
    end

    if #payload > 0 then
        return table.concat(payload)
    end
    return nil
end

---Get raw file content (for files saved with isLoadable=false)
---Parses the preload wrapper and returns just the payload
---@param filename string
---@return string?
function getRawFileContent(filename)
    local content = fileSystem[filename]

    -- If MOCK_FILE_MIRROR_ROOT is set and file not in memory, try to read from disk
    if not content and MOCK_FILE_MIRROR_ROOT then
        pcall(function()
            local normalized = filename:gsub("\\", "/")
            local full = MOCK_FILE_MIRROR_ROOT .. normalized
            local f = io.open(full, "rb")
            if f then
                content = f:read("*all")
                f:close()
                -- Store in memory for future access
                if content then
                    fileSystem[filename] = content
                end
            end
        end)
    end

    -- Parse the preload wrapper and extract the payload
    return parseNonloadableContent(content)
end

---Clear a file from the mock file system
---@param filename string
function clearFile(filename)
    fileSystem[filename] = nil
end

---Clear all files matching a pattern from the mock file system
---@param pattern string -- Lua pattern to match filenames
function clearFilesMatching(pattern)
    for filename in pairs(fileSystem) do
        if filename:match(pattern) then
            fileSystem[filename] = nil
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

-- ============================================================================
-- WC3 String Functions
-- ============================================================================

---@param s string
---@return integer
function StringLength(s)
    return #s
end

---@param s string
---@param start integer
---@param finish integer
---@return string
function SubString(s, start, finish)
    return s:sub(start + 1, finish)
end

---@param s string
---@param upper boolean
---@return string
function StringCase(s, upper)
    if upper then
        return s:upper()
    else
        return s:lower()
    end
end

-- ============================================================================
-- Modulo Function
-- ============================================================================

---@param a integer
---@param b integer
---@return integer
function ModuloInteger(a, b)
    return a % b
end

-- ============================================================================
-- Display Functions (no-op in standalone)
-- ============================================================================

---@param x number
---@param y number
---@param duration number
---@param message string
function DisplayTimedTextToLocalPlayer(x, y, duration, message)
    -- No-op in standalone mode
end

---@param p any
---@param x number
---@param y number
---@param duration number
---@param message string
function DisplayTimedTextToPlayer(p, x, y, duration, message)
    -- No-op in standalone mode
end

-- ============================================================================
-- Utility Functions
-- ============================================================================

---@param val any
---@return boolean
function is_zero_or_nil(val)
    return val == nil or val == 0
end

---@param defaultValue any
---@return table
function __jarray(defaultValue)
    return setmetatable({}, {
        __index = function(t, k)
            return defaultValue
        end
    })
end

-- ============================================================================
-- WC3 JASS PRNG (exact implementation matching Warcraft 3's random number generator)
-- Based on PyJASSPrng by huntergregal
-- ============================================================================

-- Constants extracted from game.dll v1.26.0.6401
local JASS_CONSTANTS = {
    0x8e, 0x14, 0x27, 0x99, 0xfd, 0xaa, 0xc7, 0x08, 0xd5, 0xe6, 0x3e, 0x1f, 0xf6, 0xbb, 0x55, 0xda,
    0x75, 0xa0, 0x4a, 0x6a, 0xe8, 0xbd, 0x97, 0xff, 0xde, 0x9b, 0xbc, 0x9f, 0x81, 0x8a, 0xa1, 0x46,
    0x6e, 0x0b, 0xe3, 0x63, 0x76, 0x7a, 0x6c, 0x5d, 0x88, 0xd3, 0x69, 0xca, 0xc3, 0x47, 0xb9, 0x25,
    0x83, 0xab, 0xa2, 0x3f, 0xa6, 0x41, 0x7c, 0xba, 0xe5, 0xac, 0x95, 0x01, 0x7e, 0xcf, 0x09, 0xc1,
    0xd9, 0x62, 0x70, 0x71, 0x8d, 0xdb, 0x05, 0x02, 0x24, 0x87, 0xef, 0x54, 0xc6, 0xd4, 0x37, 0x30,
    0xd0, 0x1b, 0xcb, 0x7b, 0xb8, 0xe4, 0xd8, 0xec, 0x49, 0xce, 0xad, 0xdc, 0x13, 0xa9, 0x94, 0xc4,
    0x8f, 0x39, 0xae, 0x0d, 0x18, 0x52, 0xdd, 0x0e, 0x78, 0xfa, 0xf5, 0x85, 0x58, 0xd2, 0xaf, 0x6d,
    0xa4, 0xb2, 0x53, 0x3b, 0x51, 0xa5, 0x50, 0xbe, 0xfc, 0x2d, 0xf4, 0x11, 0x48, 0x98, 0x16, 0xf1,
    0x86, 0xdf, 0x3d, 0x66, 0x5e, 0x44, 0x2e, 0x2f, 0x36, 0x07, 0x6b, 0x17, 0x8b, 0x29, 0x4c, 0xb6,
    0xe2, 0x89, 0x5f, 0xe7, 0xcd, 0xa7, 0x21, 0xe1, 0x4d, 0xc9, 0x65, 0xed, 0xfe, 0xee, 0x9c, 0x23,
    0x33, 0x7d, 0xb7, 0x04, 0x9e, 0x9a, 0x2a, 0x40, 0xb3, 0x10, 0x5b, 0xf3, 0x82, 0x77, 0x1c, 0x92,
    0x20, 0x4e, 0x1e, 0x57, 0x22, 0x72, 0x06, 0x8c, 0x67, 0x2c, 0x73, 0xfb, 0x59, 0xc2, 0x0a, 0xbf,
    0x79, 0x5c, 0xf9, 0x0c, 0x28, 0x1a, 0x12, 0x68, 0x74, 0x34, 0x19, 0x42, 0xb1, 0xc0, 0x84, 0xf8,
    0x38, 0xf0, 0x15, 0x9d, 0x60, 0xf2, 0x3a, 0x6f, 0xb4, 0x90, 0xeb, 0x91, 0x1d, 0x7f, 0x35, 0x61,
    0x5a, 0x32, 0x03, 0x56, 0xa3, 0xc5, 0x2b, 0x93, 0x80, 0x0f, 0x4b, 0x43, 0xf7, 0xa8, 0xe0, 0x3c,
    0x96, 0xd1, 0x64, 0x26, 0xd7, 0x45, 0xcc, 0x4f, 0xc8, 0xb0, 0xe9, 0xb5, 0x00, 0xd6, 0x31, 0xea,
    0x68, 0x75, 0x6e, 0x74, 0x65, 0x72, 0x20, 0x67, 0x72, 0x65, 0x67, 0x61, 0x6c,
}

-- JASS PRNG state
local jass_seed_bits = 0
local jass_current = 0

-- 32-bit left rotation
local function rotl32(x, n)
    x = x & 0xffffffff
    return ((x << n) | (x >> (32 - n))) & 0xffffffff
end

-- Get 4-byte little-endian integer from constants at 0-based index
local function const_at(idx)
    -- idx is 0-based like in Python, Lua tables are 1-based
    local b0 = JASS_CONSTANTS[idx + 1] or 0
    local b1 = JASS_CONSTANTS[idx + 2] or 0
    local b2 = JASS_CONSTANTS[idx + 3] or 0
    local b3 = JASS_CONSTANTS[idx + 4] or 0
    return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff
end

-- Advance the PRNG state and return the next value
local function jass_step()
    local s = jass_seed_bits & 0xffffffff

    local b3 = (s >> 24) & 0xff
    local b2 = (s >> 16) & 0xff
    local b1 = (s >> 8) & 0xff
    local b0 = s & 0xff

    local i0 = b3 - 4
    if i0 < 0 then i0 = b3 + 0xB8 end
    local i1 = b2 - 0x0C
    if i1 < 0 then i1 = b2 + 200 end
    local i2 = b1 - 0x18
    if i2 < 0 then i2 = b1 + 0xD4 end
    local i3 = b0 - 0x1C
    if i3 < 0 then i3 = b0 + 0xD8 end

    local mix = (
        rotl32(const_at(i2), 3) ~
        rotl32(const_at(i1), 2) ~
        const_at(i3) ~
        rotl32(const_at(i0), 1)
    ) & 0xffffffff

    local new_val = (jass_current + mix) & 0xffffffff

    -- Advance seed bytes
    jass_seed_bits = (((i0 & 0xff) << 24) |
                      ((i1 & 0xff) << 16) |
                      ((i2 & 0xff) << 8) |
                      (i3 & 0xff)) & 0xffffffff

    jass_current = new_val
    return new_val
end

---Set the random seed (WC3 JASS compatible)
---@param seed integer
function SetRandomSeed(seed)
    seed = seed & 0xffffffff

    -- _set_seed: compute seed_bits from seed
    -- seed_bitfield format:
    --   [31..26]  6b:  ((seed / 47) * 17 + seed)  & 0x3F
    --   [25..24]  2b:  0 (gaps)
    --   [23..18]  6b:  seed % 53
    --   [17..16]  2b:  0
    --   [15..10]  6b:  seed % 59
    --   [9..8]    2b:  0
    --   [7..2]    6b:  seed % 61
    --   [1..0]    2b:  0
    jass_seed_bits = ((seed % 0x3d) << 2)
    jass_seed_bits = jass_seed_bits | ((seed % 0x3b) << 10)
    jass_seed_bits = jass_seed_bits | ((seed % 0x35) << 18)
    jass_seed_bits = jass_seed_bits | (((seed // 0x2f) * 0x11 + seed) << 26)
    jass_seed_bits = jass_seed_bits & 0xffffffff
    jass_current = seed & 0xffffffff

    -- The Python code immediately advances once after setting seed
    jass_step()
end

---Get a random integer in range [min, max] (WC3 JASS compatible)
---@param min_val integer
---@param max_val integer
---@return integer
function GetRandomInt(min_val, max_val)
    if min_val == max_val then
        return min_val
    end

    local rng
    if max_val < min_val then
        rng = min_val - max_val
    else
        rng = max_val - min_val
    end

    local rnd = jass_step() & 0xffffffff
    -- (rnd * (rng + 1)) >> 32
    local t = (rnd * (rng + 1)) >> 32
    return min_val + t
end

-- ============================================================================
-- Async Test Runner
-- ============================================================================

---Helper function to run async tests in coroutines
---@param testName string
---@param testFunc fun()
function runAsyncTest(testName, testFunc)
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

-- ============================================================================
-- FileIO.Save Capture Hook
-- ============================================================================

---Install the FileIO.Save capture hook after FileIO is loaded.
---This wraps FileIO.Save to capture the data passed to it when MOCK_FILEIO_SAVE_CAPTURE_ENABLED is true.
---Call this function after requiring FileIO to enable the capture functionality.
function installFileIOSaveCapture()
    if FileIO and FileIO.Save then
        local realFileIO_Save = FileIO.Save
        FileIO.Save = function(filename, data, isLoadable)
            if MOCK_FILEIO_SAVE_CAPTURE_ENABLED then
                MOCK_FILEIO_SAVE_LAST_DATA = data
            end
            return realFileIO_Save(filename, data, isLoadable)
        end
    end
end
