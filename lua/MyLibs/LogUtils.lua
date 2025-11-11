if Debug then Debug.beginFile("LogUtils") end
do
--[[
LogUtils v1.0.3 by Tomotz
This library provides a log file for the game.

Features beyond what FileIO offers:
 - Log is saved to a memory buffer, allowing you to write to the file over and over again without losing the old data.
 - Writing lines to the log only when the game is in replay to reduce performance impact
 - Maximum log length - when reached, will open a new log file (and memory buffer) to avoid long writes
 - Adds the player id to the log name to allow multiple logs from a single game on the same computer (for map testing)
 - `print` like interface for arguments

Interface:
    LogWrite(...)
        Appends data to the current log file (also flushes everything in the memory buffer to the file). Acts like print

    LogWriteNoFlush(...)
        Appends data to the memory buffer without writing it to the file.
        This should only be used if you know you will eventually use a LogWrite to flush this line

    LogWriteNoFlushReplay(...)
    LogWriteReplay(...)
        These functions are the same as the ones above, except they will only write the line when a replay of the game is played.
        Note that the normal variants of these functions will write in both replay and normal modes.
        These functions should be used when you worry about game performace impact. If you write many/very long lines to
        the log, it might hurt performance

Installation instructions:
Copy the code to your map.

Credits:
TriggerHappy GameStatus (Replay Detection) https://www.hiveworkshop.com/threads/gamestatus-replay-detection.293176/
 * A big block of code was taken from there to allow detecting that the game is running in replay mode.
Requires:
FileIO (lua) by Trokkin - https://www.hiveworkshop.com/threads/fileio-lua-optimized.347049/
TotalInitialization by Bribe - https://www.hiveworkshop.com/threads/total-initialization.317099/

Updated: Nov 2025
--]]
LIBRARY_LogUtils = true
local SCOPE_PREFIX = "LogUtils_" ---@type string requires TotalInitialization, FileIO

-- Configurations:


-- Base name for the log files.
-- The logs are saved to Documents\Warcraft III\CustomMapData
-- the relative path where the log files are kept. Should end with \\
local RAW_LOG_PATH = "Savegames\\TestMap\\"
-- Raw name for the log file. Will append the player index to the start on any mode, and "replay" to the end on replay mode.
-- Will also add the log index (in case there are multiple log files in the same run) and .txt to the end
local RAW_LOG_NAME = "last_game_log"

-- The maximum length of the memory buffer. If too long, writes to the log file can take a long time
-- (as the whole buffer is flushed on every write) and hinder performances
local MAX_BUFF_LEN = 50000 -- Theoretically, FileIO supports 999999

-- Maximum number of log files that will be created in a single game (will stop logging if threshold was reached)
local MAX_FILES = 10

-- Same as MAX_FILES, but for replay logs
local MAX_FILESREPLAY = 500

-- If true, will try writing the map name to the long on init (using TRIGSTR_001)
local WRITE_MAP_NAME = true

-- Local variables for internal use
local LogFileName ---@type string

local WriteBuffer = {}
local WriteBufferSize = 0
local FileIdx = 0
local IsFlushed = true

---@param text string
local function WriteAndFlush(text)
    if (FileIdx <= MAX_FILES) or ((GameStatus == GAME_STATUS_REPLAY) and (FileIdx <= MAX_FILESREPLAY)) then
        if FileIO ~= nil then -- on rare occasions where log is called very early, FileIO may not be initialized yet
            FileIO.Save(LogFileName, text, false)
            IsFlushed = true
        end
    end
end

local function CreateNewLogFile()
    LogFileName = RAW_LOG_PATH .. GetPlayerId(GetLocalPlayer()) .. "_" .. RAW_LOG_NAME .. "_"
    if GameStatus == GAME_STATUS_REPLAY then
        LogFileName = LogFileName .. "replay_"
    end
    LogFileName = LogFileName .. tostring(FileIdx) .. ".txt"

    FileIdx = FileIdx + 1
    WriteAndFlush("\nLog file is empty")
end

local function init()
    CreateNewLogFile()
    -- write map name to log
    if WRITE_MAP_NAME then
        LogWrite(GetLocalizedString("TRIGSTR_001"))
    end
end

-- Writes a line to the WriteBuffer to be logged
function LogWriteNoFlush(...)
    local args = {...}
    for i = 1, #args do
        args[i] = tostring(args[i]) -- Convert each argument to a string
    end
    local fullLine = tostring(math.floor(GetElapsedGameTime())) .. ":" .. table.concat(args, " ")
    local lineLen = #fullLine
    if WriteBufferSize + lineLen > MAX_BUFF_LEN then
        if not IsFlushed then
            WriteAndFlush(table.concat(WriteBuffer, "\n"))
        end
        CreateNewLogFile()
        WriteBuffer = {}
        WriteBufferSize = 0
    end
    table.insert(WriteBuffer, fullLine)
    WriteBufferSize = WriteBufferSize + lineLen
    IsFlushed = false
end

-- Writes a line to the WriteBuffer to be logged only in replay mode
function LogWriteNoFlushReplay(...)
    if GameStatus == GAME_STATUS_REPLAY then
        LogWriteNoFlush(...)
    end
end

-- Writes a line to the current log
function LogWrite(...)
    LogWriteNoFlush(...)
    WriteAndFlush(table.concat(WriteBuffer, "\n"))
end

-- Writes a line to the log only in replay mode
function LogWriteReplay(...)
    if GameStatus == GAME_STATUS_REPLAY then
        LogWrite(...)
    end
end

OnInit.global(init)
end
if Debug then Debug.endFile() end
