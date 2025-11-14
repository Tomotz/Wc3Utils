if Debug then Debug.beginFile("SyncStream") end
do
--[[
Optimized SyncStream v1.0.0 by Tomotz
Original version By Trokkin https://www.hiveworkshop.com/threads/syncstream.349055/

Provides functionality to designed to safely sync arbitrary amounts of data.
Uses timers to spread BlzSendSyncData calls over time.

API:
--- Adds data to the queue to be synced.
--- Note that SyncStream.sync must be called from all clients, even the ones that don't have the data. getLocalData can be different between clients.
---@param whichPlayer player -- the player who's data is used as the sync data
---@param getLocalData string | fun():string -- the data to sync, or a callback that returns the data to sync
---@param callback fun(syncedData:string, ...) -- the callback to call once the sync is done.
---@param ... any -- additional arguments to pass to the callback. Note that the args must be the same for all clients.
function SyncStream.sync(whichPlayer, getLocalData, callback, ...)

--- Same as SyncStream.sync, but waiting until the sync was done and only then returns.
--- Must be called from a context where you can call TriggerSleepAction().
--- If called twice, the second call will wait for the first one to finish.
---@param whichPlayer player
---@param getLocalData string | fun():string
---@return string
function SyncStream.blockingSync(whichPlayer, getLocalData)

Patch by Tomotz Nov 2025:
Advantages over the original version are mostly performance related (This library needs about half the packets on any input size):
1. No header packet - this means that for small data sizes (up to 254 character strings) this sends half the amount of packets
2. Smaller headers for data packets - each header is only 1 character instead of 6 in the original version I think (so more room for data)
3. Packet size increased to the max possible (I think) - 254 characters instead of 200
4. Encoder is more efficient - only encodes null terminators since they are the only unsupported character for syncs.

Requirements:
    DebugUtils by Eikonium                          @ https://www.hiveworkshop.com/threads/330758/
    Total Initialization by Bribe                   @ https://www.hiveworkshop.com/threads/317099/
    StringEscape by Tomotz

]]
OnInit.global("SyncStream", function()
    --CONFIGURATION
    local PREFIX = "Sync"
    --- Setting the next locals to 1, 8 seems to not be noticable when syncing during the game. Up to 32, 32 should be desync safe, but will cause lag spikes when syncing large data
    local PACKAGE_PER_TICK = 2
    local PACKAGE_TICK_PER_SECOND = 16
    local IS_DEBUG = false -- enable debug prints
    local LAST_HUMAN_SLOT = bj_MAX_PLAYER_SLOTS - 1 -- the last slot id that might belongs to a human player
    --END CONFIGURATION

    --- Calculated values from configuration
    local MAX_PAYLOAD = 255 -- Maximum payload (not including the null terminator) that can be sent with BlzSendSyncData
    FLIT_DATA_SIZE = MAX_PAYLOAD -- max data length in a single flit that is sent with BlzSendSyncData

    TRANSFER_RATE = FLIT_DATA_SIZE * PACKAGE_PER_TICK * PACKAGE_TICK_PER_SECOND -- bytes per second. Do not change this.

    --internal
    ---@type table<integer, SyncStream>
    local streams = {}
    local syncTimer
    local localPlayer ---@type player

    --- A SyncStream callback and a table of arguments for it
    ---@class StreamFuncAndArgs
    ---@field func fun(fullData:string, whichPlayer:player, ...:any)
    ---@field args any[]

    --- Sends or receives player's data assymentrically
    ---@class SyncStream
    ---@field owner player
    ---@field is_local boolean
    ---@field outPackets string[] -- list of outPackets to send
    ---@field callbacks StreamFuncAndArgs[] -- when a SyncStream.sync ends the syncing, we will call the first function in this list, and remove it
    ---@field inData string[] -- aggregated data received in this stream so far. zeroed when a full sync is done
    SyncStream = {}
    SyncStream.__index = SyncStream

    ---@param owner player The player owning the data from the stream
    ---@return SyncStream
    local function CreateSyncStream(owner)
        return setmetatable({
            owner = owner,
            is_local = owner == localPlayer,
            outPackets = {},
            callbacks = {},
            inData = {},
        }, SyncStream)
    end

    --- Only print error messages unless we're in debug mode
    ---@param isError boolean
    ---@param ... any
    local function debugPrint(isError, ...)
        if isError or IS_DEBUG then
            if LogWriteNoFlush == nil then
                print(...)
            else
                LogWriteNoFlush(...)
            end
        end
    end

    --- Sets the speed of the syncing. The higher the speed is, the faster the data will be sent, but the more it interfere with the game.
    --- The default is 1, 8 which doesn't feel like the game is slowed down at all. Original was 32, 32 where you couldn't really do anything until the sync was done.
    ---@param packetsPerTick integer
    ---@param ticksPerSecond integer
    function SetSyncRate(packetsPerTick, ticksPerSecond)
        PACKAGE_PER_TICK = packetsPerTick
        PACKAGE_TICK_PER_SECOND = ticksPerSecond
    end

    local blockSyncedData = nil
    ---@param syncedData string
    function SyncDone(syncedData)
        blockSyncedData = syncedData
    end

    local isSyncInProgress = false

    --- Same as SyncStream.sync, but waiting until the sync was done and only then returns.
    --- Must be called from a context where you can call TriggerSleepAction().
    --- If called twice, the second call will wait for the first one to finish.
    ---@param whichPlayer player
    ---@param getLocalData string | fun():string
    ---@return string
	function SyncStream.blockingSync(whichPlayer, getLocalData)
        while isSyncInProgress do
            TriggerSleepAction(0.1)
        end
        isSyncInProgress = true
        SyncStream.sync(whichPlayer, getLocalData, SyncDone)
        while blockSyncedData == nil do
            TriggerSleepAction(0.1)
        end
        isSyncInProgress = false
        local data = blockSyncedData
        blockSyncedData = nil
        return data
    end


    ---@param stream SyncStream
    ---@param inData string
    local function parsePackage(stream, inData)
        -- sync doesn't work with null terminators. Need to escape it. This is the only character FileIO save isn't able to handle as well,
        -- so we can use the same defines as there
        local data = AddEscaping(inData, {0})
        for i = 1, #data, FLIT_DATA_SIZE do
            local curData = data:sub(i, i + FLIT_DATA_SIZE - 1)
            debugPrint(false, "parsePackage created flit", #curData)
            table.insert(stream.outPackets, curData)
        end
        if math.fmod(#data, FLIT_DATA_SIZE) == 0 then
            --- The receiver must get a flit shorter than FLIT_DATA_SIZE to know the package was completed.
            --- The last flit was exactly FLIT_DATA_SIZE bytes, so we must send an empty flit
            debugPrint(false, "parsePackage created empty flit")
            table.insert(stream.outPackets, "")
        end
    end

    --- Adds data to the queue to be synced.
    --- Note that SyncStream.sync must be called from all clients, even the ones that don't have the data. getLocalData can be different between clients.
    ---@param whichPlayer player -- the player who's data is used as the sync data
    ---@param getLocalData string | fun():string -- the data to sync, or a callback that returns the data to sync
    ---@param callback fun(syncedData:string, ...) -- the callback to call once the sync is done.
    ---@param ... any -- additional arguments to pass to the callback. Note that the args must be the same for all clients.
    function SyncStream.sync(whichPlayer, getLocalData, callback, ...)
        local pid = GetPlayerId(whichPlayer)
        local stream = streams[pid]
        debugPrint(false, "Sending sync request from player", pid, Debug.traceback())
        table.insert(stream.callbacks, {callback = callback, args = {...}})
        if stream.is_local then
            if type(getLocalData) == "function" then
                getLocalData = getLocalData()
            end
            if type(getLocalData) ~= "string" then
                getLocalData = "sync error: bad data type provided " .. type(getLocalData)
            end
            parsePackage(stream, getLocalData)
        end
    end

    function startSyncTimer()
        --- Setup sender timer
        local stream = streams[GetPlayerId(GetLocalPlayer())]
        if not stream.is_local then
            debugPrint(true, "SyncStream panic: local stream is not local")
            return
        end
        TimerStart(syncTimer, 1 / PACKAGE_TICK_PER_SECOND, true, function()
            for _ = 1, PACKAGE_PER_TICK do
                --- no more packets to send
                if next(stream.outPackets) == nil then
                    break
                end
                local package = stream.outPackets[1]
                debugPrint(false, "Sending package", #package, package)
                if BlzSendSyncData(PREFIX, package) then
                    table.remove(stream.outPackets, 1)
                else
                    debugPrint(true, "BlzSendSyncData FAILED for package of length", #package)
                end
            end
        end)
    end

    ---@param owner player
    ---@param package string
    function handleData(owner, package)
        local stream = streams[GetPlayerId(owner)]
        if stream == nil then
            debugPrint(true, "SyncStream panic: no stream found for player: " .. GetPlayerName(owner))
            return
        end
        if package == nil then
            debugPrint(true, "SyncStream panic: bad package received from player: " .. GetPlayerName(owner))
            return
        end
        debugPrint(false, "Got sync package from player", GetPlayerId(owner), #package, package)
        if next(stream.callbacks) == nil then
            debugPrint(true, "SyncStream panic: sync packet received but no function set to handle it")
            return
        end
        table.insert(stream.inData, package)
        if #package < FLIT_DATA_SIZE then
            --- got a packet that is not full. This means it's the last packet
            local callbackData = table.remove(stream.callbacks, 1)
            local rawData = RemoveEscaping(table.concat(stream.inData), {0})
            stream.inData = {}
            debugPrint(false, "Last flit received for player", GetPlayerId(owner), "calling callback", #package)
            callbackData.callback(rawData, owner, table.unpack(callbackData.args))
        end
    end

    OnInit.global(function()
        syncTimer = CreateTimer()
        localPlayer = GetLocalPlayer()
        for i = 0, LAST_HUMAN_SLOT do
            streams[i] = CreateSyncStream(Player(i))
        end

        --- Setup receiver trigger
        local syncTrigger = CreateTrigger()
        for i = 0, LAST_HUMAN_SLOT do
            BlzTriggerRegisterPlayerSyncEvent(syncTrigger, Player(i), PREFIX, false)
        end
        TriggerAddAction(syncTrigger, function()
            local owner = GetTriggerPlayer()
            local package = BlzGetTriggerSyncData()
            handleData(owner, package)
        end)
        startSyncTimer()
    end)
end)
end
if Debug then Debug.endFile() end