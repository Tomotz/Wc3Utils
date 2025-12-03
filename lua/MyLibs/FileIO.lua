if Debug then Debug.beginFile("FileIO") end
--[[
    Optimized FileIO v1.0.0 by Tomotz
    Based on Trokkin's version (https://www.hiveworkshop.com/threads/fileio-lua-optimized.347049/)

    - Read and write files with any data.
    - This version allows writing/reading any data including characters that the preload natives can't work with, by escaping them.
    - Allow Saving with the `-isLoadable` that will make the file look nicer if you never plan to load it.
    It's similar to Antares's Stable Lua FileIO, only it allows writing null terminators as well.

    API:

        FileIO.Save(filename, data, isLoadable?)
            - Write string data to a file
            ---@param isLoadable boolean? -- Use false only if you never plan to load the file to make it format nicer and be more size efficient. Default is true.

        FileIO.Load(filename) -> string?
            - Read string data from a file. Returns nil if file doesn't exist.

        FileIO.SaveAsserted(filename, data, onFail?) -> bool
            - Saves the file and checks that it was saved successfully.
              If it fails, passes (filename, data, loadResult) to onFail.

        FileIO.enabled : bool
            - field that indicates that files can be accessed correctly.

    Requirements:
        StringEscape by Tomotz                          @ https://www.hiveworkshop.com/threads/optimized-syncstream-and-stringescape.367925/
        Total Initialization by Bribe                   @ https://www.hiveworkshop.com/threads/317099/

    Optional requirements:
        DebugUtils by Eikonium                          @ https://www.hiveworkshop.com/threads/330758/

    Patch by Tomotz 1 Mar 2025:
        - Added escaping to all characters unsupported by FileIO. Those include null terminator (for saving and loading),
        and line feed, backslash, closing square bracket.
        - Added optional parameter isLoadable to savefile, which defaults to true. If false, the file will have nicer format -
        less character are escaped, and there are less extra characters added by FileIO. This also means there is more room for user
        data in each Preload call. Such files will not be loadable with FileIO.Load.
--]]
    local RAW_PREFIX = ']]i([['
    local RAW_SUFFIX = ']])--[['
    local MAX_PRELOAD_SIZE = 256
    MAX_TEXT_SAVE = MAX_PRELOAD_SIZE
    MAX_TEXT_LOAD = MAX_PRELOAD_SIZE - #RAW_PREFIX - #RAW_SUFFIX
    local LOAD_ABILITY = FourCC('ANdc')
    local LOAD_EMPTY_KEY = '!@#$, empty data'
    local name = nil ---@type string?

    -- carriage return seems to turn into new line when written and read back
    FileIO_unsupportedLoadChars = {0, 10, 13, 92, 93} -- null terminator, line feed, carriage return, slash, closing square bracket
    FileIO_unsupportedSaveChars = {0} -- only null terminator is not supported when saving. \ becomed \\ though, so the string becomes longer and we lose the last characters in the Preload

    ---@param filename any
    ---@param isLoadable any
    local function open(filename, isLoadable)
        -- turns out you can't save a file without an extension.
        if Debug then Debug.assert(filename:find('.', 1, true), "FileIO: filename must have an extension") end
        name = filename
        PreloadGenClear()
        if isLoadable then
            Preload('")\nendfunction\n//!beginusercode\nlocal p={} local i=function(s) table.insert(p,s) end--[[')
        end
    end

    local function write(s, isLoadable)
        local maxSize = isLoadable and MAX_TEXT_LOAD or MAX_TEXT_SAVE
        local prefix = isLoadable and RAW_PREFIX or ''
        local suffix = isLoadable and RAW_SUFFIX or ''
        local curPos = 1
        while curPos <= #s do
            local chunk = s:sub(curPos, curPos + maxSize - 1)
            local lastChar = #chunk
            if not isLoadable then
                -- handle \ characters which are escaped as \\ in preload (for loadable files, we replace the \ with unprintable char)
                local _, numSlash = chunk:gsub("[\\]", "")
                local curLen = lastChar + numSlash -- This is the actuall length the chunk will take in preload
                while curLen > maxSize and lastChar > 0 do
                    local char = chunk:sub(lastChar, lastChar)
                    if char == '\\' then
                        curLen = curLen - 1
                    end
                    curLen = curLen - 1
                    lastChar = lastChar - 1
                end
            end
            chunk = chunk:sub(1, lastChar)
            Preload(prefix .. chunk .. suffix)
            curPos = curPos + #chunk
        end
    end

    local function close(isLoadable)
        if isLoadable then
            Preload(']]BlzSetAbilityTooltip(' ..
                LOAD_ABILITY .. ', table.concat(p), 0)\n//!endusercode\nfunction a takes nothing returns nothing\n//')
        end
        PreloadGenEnd(name --[[@as string]])
        name = nil
    end

    ---@param filename string
    ---@param data string
    ---@param isLoadable boolean? -- Use false only if you never plan to load the file. Default is true.
    -- This controls which characters are escaped and replaced. For loadable files, we must remove more characters.
    local function savefile(filename, data, isLoadable)
        if isLoadable == nil then
            isLoadable = true
        end
        local unsupportedChars ---@type integer[]
        if isLoadable then
            unsupportedChars = FileIO_unsupportedLoadChars
        else
            unsupportedChars = FileIO_unsupportedSaveChars
        end
        local data2 = AddEscaping(data,  unsupportedChars)
        open(filename, isLoadable)
        write(data2, isLoadable)
        close(isLoadable)
    end

    ---@param filename string
    ---@return string?
    local function loadfile(filename)
        local s = BlzGetAbilityTooltip(LOAD_ABILITY, 0)
        BlzSetAbilityTooltip(LOAD_ABILITY, LOAD_EMPTY_KEY, 0)
        Preloader(filename)
        local loaded = BlzGetAbilityTooltip(LOAD_ABILITY, 0)
        if loaded == LOAD_EMPTY_KEY then
            return nil
        end
        return RemoveEscaping(loaded, FileIO_unsupportedLoadChars)
    end

    ---@param filename string
    ---@param data string
    ---@param onFail nil | fun(filename:string, data:string, loadResult:string?)
    ---@return boolean
    local function saveAsserted(filename, data, onFail)
        savefile(filename, data)
        local res = loadfile(filename)
        if res == data then
            return true
        end
        if onFail then
            onFail(filename, data, res)
        end
        return false
    end

    FileIO = {
        Save = savefile,
        Load = loadfile,
        SaveAsserted = saveAsserted,
    }

OnInit.global(function()
    FileIO.enabled = saveAsserted('TestFileIO.pld', 'FileIO is Enabled')
end)
if Debug then Debug.endFile() end
