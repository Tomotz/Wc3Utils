if Debug then Debug.beginFile("Serializer") end
do
--[[

Serializer v1.0.0 by Tomotz
Based on SaveLoadHelper by Wrda  https://www.hiveworkshop.com/threads/lua-save-and-load-1-6.355977/

Allows packing arbitrary variables into strings (and unpacking those strings back into variables).
Supports booleans, numbers (integers and floats), strings and tables, including recursive tables.
Optionally supports units and items (given a mapping from unit/item to unique integer ids and back).
Note: float numbers might lose a small amount of precision (0.0000001 difference)
Supports any data stated above including all unprintable characters

API:

---@param input boolean | number | string | table
---@return string? -- returns the full packed value of the input or nil on input error
--- Dumps a variable into a string
function Serializer.dumpVariable(input)

---Loads data packed with dumpVariable into a variable.
---@param data string -- the packed variable
---@return any -- value of the loaded variable. Returns nil on fail. Note that `false` is a valid return value.
---@return integer? -- number of characters consumed
function Serializer.loadVariable(data)

---@param p player
---@param input boolean | number | string | table - the input variable to be saved
---@param filePath string
---@param scrambleCallback fun(string):string? | nil - optional callback to be executed on the data (including the checksum) before saving.
--- saves a variable to a file in a Serialized format. Adds a checksum to validate data integrity
function Serializer.saveFile(p, input, filePath, scrambleCallback)

---Loads serialized data from a file or list of files into a table. Syncing the data to all players. Once completed, fires the callback function.
---@param whichPlayer player
---@param filePaths string | string[]-- name of the file/files to load
---@param callback fun(loadedVariables: any) -- callback to execute once loading is done. The callback is getting the synced data that was saved in the file(s). If a single file was given, the data is the variable loaded from that file. If a list of files was given, the data is a list of variables loaded from each file in the same order.
--- where loadedTables is the list of tables loaded from the files or nil on error and whichPlayer is the player that requested the load
---@param unscrambleCallback fun(string):string? | nil - optional callback to be executed on each file data after loading. Must match the scrambleCallback given to saveFile.
---@param isDeflate boolean? - if true, the data will be compressed using zlib before being synced between players (use if you want to reduce network traffic on large data).
---@return string -- an error message. Note that this message can differ between players, and must not be used in a synced way!
-- Message will be an empty string on success, or an error message on failure.
function Serializer.loadFile(whichPlayer, filePaths, callback, unscrambleCallback, isDeflate)

Recommendation - for very large files call saveFile/loadFile with LibDeflate.CompressDeflate/LibDeflate.DecompressDeflate in the scramble/unscramble callbacks, and set isDeflate to true.

Optional requirements
    DebugUtils by Eikonium @ https://www.hiveworkshop.com/threads/330758/
    FileIO (my version) - needed if you want to use the save/load to file functions.
    SyncStream (my version) - needed if you want to use the save/load to file functions @ https://www.hiveworkshop.com/threads/optimized-syncstream-and-stringescape.367925/
    My versions of SyncStream and FileIO are needed to be able to save/load all characters correctly (which the original version can't do)
    LibDeflate by Magi - needed if you want to sync large amounts of data faster @ https://www.hiveworkshop.com/threads/magi-log-n-load-the-ultimate-save-load-system.357602/
    LogUtils by me @ https://www.hiveworkshop.com/threads/logutils.357625/

If you want to serialize units/items, you need to provide two mappings:
    UnitToUniqueId : table<unit, integer>, UniqueIdToUnit : table<integer, unit>
    ItemToUniqueId : table<item, integer>, UniqueIdToItem : table<integer, item>

Updated Nov 2025

Doesn't support arbitrary classes with overriden metamethods. Doesn't support groups and hashtables
]]

Serializer = {}
--[[----------------------------------------------------------------------------------------------------
                            CONFIGURATION                                                             ]]
Serializer.VERSION = "000"
Serializer.PREFIX_END = " Serializer "
Serializer.TEXT_PREFIX = Serializer.VERSION .. Serializer.PREFIX_END
local IS_DEBUG = false -- enable debug prints

--------------------------------------------------------------------------------------------------------

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

---@param tbl table
---@return table? -- the class of the input tbl
function GetClass(tbl)
    local mt = getmetatable(tbl)
    return mt and mt.class or nil
end

---@param num integer
---@param char_count integer
---@return string
local function packBytes(num, char_count)
    char_count = char_count or math.ceil(math.log(num + 1, 256))  -- Ensure char_count is sufficient to hold the number
    local bytes = {} ---@type integer[]
    local orig_num = num

    -- Extract bytes from the number
    for _ = 1, char_count do
        local mod = num & 0xFF
        table.insert(bytes, mod)
        num = num >> 8
    end
    if num ~= 0 then
        debugPrint(true, "number too large for char count.", orig_num, char_count)
    end

    -- Create the format string, one byte per "B" format specifier
    local fmt = string.rep("B", char_count)

    -- Pack the bytes into a string
    return string.pack(fmt, table.unpack(bytes))
end

---@param bytes string
---@return integer
local function unpackBytes(bytes)
    local fmt = string.rep("B", #bytes)
    local values = table.pack(string.unpack(fmt, bytes))
    local num = 0

    -- Combine the bytes into a single number
    -- minus one because string.unpack returns and extra value
    for i = #values - 1, 1, -1 do
        num = num * 256 + values[i]
    end

    return num
end

--compress

---@param float number
---@return integer
local function binaryFloat2Integer(float)
    local result = string.unpack("i4", string.pack("f", float))
    return result
end

---@param int integer
---@return number
local function binaryInteger2Float(int)
    local result = string.unpack("f", string.pack("i4", int))
    return result
end

--validating parts of the file

---@param str string
---@return integer
local function getChecksum(str)
    local checksum = 0
    for i = 1, #str do
        checksum = checksum + string.byte(str, i, i)
    end
    return checksum
end

---@param str string
---@return string
local function addChecksum(str)
    local checksum = getChecksum(str)
    return packBytes(checksum, 4) .. str
end

---@param str string
---@return string, boolean
local function separateAndValidateChecksum(str)
    local separatedString = str:sub(5)
    return separatedString, getChecksum(separatedString) == unpackBytes(str:sub(1, 4))
end


---@class tokenProperties
---@field type string -- the token class - one of const, int, uint, flt, chr, str
---@field num_characters integer? -- the number of characters needed to represent the value
---@field value any -- the value of the token
---@field subType string? -- the subtype of the token, used only for tables and numbers

---@type table<string, tokenProperties>
local delimiterList = {
    --- constant types:
    ["A"] = {type="const", value=true},
    ["B"] = {type="const", value=false},
    ["D"] = {type="const", subType="int", num_characters=0, value=0},
    ["E"] = {type="const", subType="int", num_characters=0, value=1},
    ["F"] = {type="const", subType="int", num_characters=0, value=nil},

    --- userdata types
    ["P"] = {type="unit", num_characters=4},
    ["Q"] = {type="item", num_characters=4},

    --- string types. Format is TLV (type length value).
    --- num_characters is the length of the length field for the string:
    -- Max length of 255 characters.
    ["0"] = {type="str", num_characters=1},
    -- Didn't check the exact string length you can get, but 256*175=44800 characters seems to work
    -- and 256*200=51200 characters doesn't work
    ["1"] = {type="str", num_characters=2},

    --- character types. Basically constant length strings
    -- a single ascii character
    ["2"] = {type="chr", num_characters=1},
    -- 4 ascii characters
    ["3"] = {type="chr", num_characters=4},

    --- unsigned integer types:
    --- values in range [0, 255]
    ["5"] = {type="num", subType="int", num_characters=1},
    -- values in range [0, 256^2 - 1]
    ["6"] = {type="num", subType="int", num_characters=2},

    --- signed integer types:
    -- 32bit integer. values in range [0x80000000, 0x7FFFFFFF] (So any integer value supported in lua32 bit)
    ["8"] = {type="num", subType="int", num_characters=4},

    --- float types:
    -- Single percision float, represented by 4 characters like a 32bit int
    ["9"] = {type="num", subType="flt", num_characters=4},

    -- Table types. Tables are handled recursively. They can be 1 or 2 dimentional.
    -- They can be generic and contain any type, or only one specific type.
    -- The table starts with a type delimiter (as all other types), then the length as a 2 byte field.
    -- after this, comes an optional node type delimiter (only for tables with specific type nodes)
    -- and then the table contents.

    -- any[] - array of any type. Format: <delimiter> <2byte_item_count> <type1> <item1> <type2> <item2> ...
    ["b"] = {type="tbl", subType="var_arr"},
    -- type[] - array with specific type. Format: <delimiter> <2byte_item_count> <all_value_type> <item1> <item2> ...
    ["c"] = {type="tbl", subType="type_arr"},

    -- 2 dimentional tables are saved in a similar way to two 1 dimentional tables
    -- The format is
    -- <delimiter> <2byte_item_count> <key_table_delimiter> <key_table> <value_table_delimiter> <value_table>
    -- the length field is onlt saved once.
    -- table[any, any] - table with generic keys and generic values
    ["d"] = {type="tbl", subType="var_tbl"},
    -- table[type, any] - table with single type keys and generic values
    ["e"] = {type="tbl", subType="var_val_tbl"},
    -- table[any, type] - table with generic keys and single type values
    ["f"] = {type="tbl", subType="var_key_tbl"},
    -- table[type, type] - table with single type keys and single type values
    ["g"] = {type="tbl", subType="typed_tbl"},
}

---@type table<string, string>
--- mapping from variable type to delimiter in the table above
local delimiterMapping = {
    ["True"] =  "A",
    ["False"] = "B",
    ["zero"] = "D",
    ["one"] = "E",
    ["nill"] = "F",

    ["unit"] = "P",
    ["item"] = "Q",

    ["str1"] = "0",
    ["str2"] = "1",
    ["chr1"] = "2",
    ["chr4"] = "3",
    ["int1"] = "5",
    ["int2"] = "6",
    ["int4"] = "8",
    ["flt4"] = "9",
    ["var_arr"] = "b",
    ["type_arr"] = "c",
    ["var_tbl"] = "d",
    ["var_val_tbl"] = "e",
    ["var_key_tbl"] = "f",
    ["typed_tbl"] = "g",
}

---@param input boolean | number | string | table | unit
---@param buffer string[] -- in-out buffer to dump the packed data into
---@param skipDelimiter boolean? -- if true, will not write the delimiter byte to the buffer
---@return string? -- returns the delimiter type or nil on input error
function packVariable(input, buffer, skipDelimiter)
    local delimiterType ---@type string
    local tokenValue = nil ---@type string?
    if not skipDelimiter then
        table.insert(buffer, "") -- placeholder for the delimiter
    end
    local delimiterOffset = #buffer
    debugPrint(false, "saving ", type(input), ": ", tostring(input):sub(1, 100))
    if type(input) == "boolean" then
        delimiterType = input and delimiterMapping.True or delimiterMapping.False
    elseif type(input) == "userdata"then
        if string.sub(tostring(input), 1, 4) == "unit" then
            delimiterType = delimiterMapping.unit
            if UnitToUniqueId[input] ~= nil then
                debugPrint(false, "packing unit variable. uid:", GetUnitTypeId(input), ", uniqueId:", UnitToUniqueId[input])
                tokenValue = packBytes(UnitToUniqueId[input], 4)
            else
                tokenValue = packBytes(0, 4)
            end
        elseif string.sub(tostring(input), 1, 4) == "item" then
            delimiterType = delimiterMapping.item
            if ItemToUniqueId[input] ~= nil then
                tokenValue = packBytes(ItemToUniqueId[input], 4)
            else
                tokenValue = packBytes(0, 4)
            end
        else
            debugPrint(true, "unsupported userdata type: ", input)
            if not skipDelimiter then
                table.remove(buffer, delimiterOffset) -- packing failed. Cleanup
            end
            return nil
        end
    elseif type(input) == "number" then
        if math.floor(input) == input then
            -- int nubmer
            if input == 0 then
                delimiterType = delimiterMapping.zero
            elseif input == 1 then
                delimiterType = delimiterMapping.one
            elseif input < 0 or input >= 256 ^ 2 then
                delimiterType = delimiterMapping.int4
                tokenValue = packBytes(input, 4)
            elseif input <= 255 then
                delimiterType = delimiterMapping.int1
                tokenValue = packBytes(input, 1)
            else
                if input >= 256^2 then
                    debugPrint(true, "unexpected number value (too large):", input)
                end
                delimiterType = delimiterMapping.int2
                tokenValue = packBytes(input, 2)
            end
        else
            delimiterType = delimiterMapping.flt4
            tokenValue = packBytes(binaryFloat2Integer(input), 4)
        end
    elseif type(input) == "string" then
        if #input == 1 then
            delimiterType = delimiterMapping.chr1
        elseif #input == 4 then
            delimiterType = delimiterMapping.chr4
        elseif #input <= 255 then
            delimiterType = delimiterMapping.str1
            -- pack length field
            table.insert(buffer, packBytes(#input, 1))
        else
            if #input >= 256 ^ 2 then
                debugPrint(true, "string too long for str2 length:", #input)
            end
            delimiterType = delimiterMapping.str2
            -- pack length field
            table.insert(buffer, packBytes(#input, 2))
        end
        tokenValue = input
    elseif type(input) == "table" then
        delimiterType = dumpTable(input, buffer)
        if delimiterType == nil then
            if not skipDelimiter then
                table.remove(buffer, delimiterOffset) -- packing failed. Cleanup
            end
            return nil
        end
    elseif input == nil or tostring(input) == "nil" then
        delimiterType = delimiterMapping.nill
    else
        debugPrint(true, "unsupported type for saving: ", type(input), ". data: ", input, ". returning zero")
        delimiterType = delimiterMapping.zero
    end

    if not skipDelimiter then
        buffer[delimiterOffset] = delimiterType
    end
    if type(tokenValue) == "string" then
        table.insert(buffer, tokenValue)
    end
    return delimiterType
end

---@param tbl table
---@return boolean
function isArray(tbl)
    local nn = #tbl  -- Get the "length" of the table
    for key, _ in pairs(tbl) do
        if type(key) ~= "number" or key < 1 or key > nn or math.floor(key) ~= key then
            return false  -- Found a non-integer or out-of-range key
        end
    end
    return true
end

--- dumps an array into a string. Note that this function only returns the delimiter and element count, and does not pack them
---@param input table
---@param buffer string[] -- in-out buffer to dump the packed data into
---@return string? -- returns the delimiter type or nil on input error
---@return integer? -- returns the number of elements in the array
function dumpArr(input, buffer)
    ---@class CacheEntry
    ---@field delimiter string
    ---@field packedData string[]

    ---@type CacheEntry[]
    local childrenCache = {} -- cache to save the results of the children
    -- first run the dump recursively, and check if all the children are of the same type as the first child
    -- we will also cache the results of the children so we don't have to dump them again
    local childBuffer = {} ---@type string[]
    local childType = packVariable(input[1], childBuffer, true)
    if childType == nil then
        return nil
    end
    table.insert(childrenCache, {delimiter=childType, packedData=childBuffer})
        ---@type string?
    local firstType = childType
    for ii = 2, #input do
        childBuffer = {}
        local vv = input[ii]
        childType = packVariable(vv, childBuffer, true)
        if childType == nil then
            return nil
        end
        if childType ~= firstType then
            if firstType and delimiterList[childType].subType == "int" and delimiterList[firstType].subType == "int" then
                -- Allow saving the int as a longer type
                -- In some cases this might not be the most space efficient way, but I don't want to invest in optimizing it
                if delimiterList[childType].num_characters == 0 and delimiterList[firstType].num_characters == 0 then
                    -- two different constant ints. Need at least 1 byte to save the type
                    firstType = delimiterMapping.int1
                else
                    -- take the bigger of the two delimiters
                    firstType = delimiterList[childType].num_characters > delimiterList[firstType].num_characters and childType or firstType
                end
            else
                firstType = nil
            end
        end
        table.insert(childrenCache, {delimiter=childType, packedData=childBuffer})
    end
    local delimiterType = ""
    -- now we pack the children
    if firstType == nil then
        -- there are different types of children. We will pack them as var_arr
        delimiterType = delimiterMapping.var_arr
        for _, child in ipairs(childrenCache) do
            table.insert(buffer, child.delimiter)
            for _, node in ipairs(child.packedData) do
                table.insert(buffer, node)
            end
        end
    else
        -- all children are of the same type. We will pack them as type_arr
        delimiterType = delimiterMapping.type_arr
        table.insert(buffer, firstType)
        for _, child in ipairs(childrenCache) do
            -- we need to pad the value with zeros and handle const values correctly
            local firstDelimiter = delimiterList[firstType]
            if firstDelimiter.subType == "int" then
                local curDelimiter = delimiterList[child.delimiter]
                if firstDelimiter.type == "const" then
                    -- all of the same const type. No need to do anything, there is no data
                elseif curDelimiter.type == "const" then
                    table.insert(buffer, packBytes(curDelimiter.value, 1) .. string.rep(string.char(0), firstDelimiter.num_characters - 1))
                else
                    local curValue = child.packedData[1] -- since this is an int and we packed it without the delimiter, there should be only one entry
                    -- all of the same int type. We need to pad the value with zeros
                    table.insert(buffer, curValue .. string.rep(string.char(0), firstDelimiter.num_characters - #curValue))
                end
            else
                for _, node in ipairs(child.packedData) do
                    table.insert(buffer, node)
                end
            end
        end
    end
    return delimiterType, #input
end

---@param input table
---@param buffer string[] -- in-out buffer to dump the packed data into
---@return string?, integer?
function dump2DTable(input, buffer)
    -- first we split the table into keys and values
    local key_table = {}
    local value_table = {}
    for kk, vv in pairs(input) do
        table.insert(key_table, kk)
        table.insert(value_table, vv)
    end
    table.insert(buffer, "") -- placeholder for the length field
    local lengthOffset = #buffer
    local keyDelimiterType, nodeCount = dumpArr(key_table, buffer)
    if keyDelimiterType == nil then
        return nil
    end
    local valueDelimiterType, _ = dumpArr(value_table, buffer)
    if valueDelimiterType == nil then
        return nil
    end
    buffer[lengthOffset] = packBytes(nodeCount, 2)
    if keyDelimiterType == delimiterMapping.var_arr then
        if valueDelimiterType == delimiterMapping.var_arr then
            -- both keys and values are of different types. We will pack them as var_tbl
            return delimiterMapping.var_tbl, nodeCount
        end
        -- keys are of different types, values are of the same type. We will pack them as var_key_tbl
        return delimiterMapping.var_key_tbl, nodeCount
    end
    if valueDelimiterType == delimiterMapping.var_arr then
        -- keys are of the same type, values are of different types. We will pack them as var_val_tbl
        return delimiterMapping.var_val_tbl, nodeCount
    end
    -- both keys and values are of the same type. We will pack them as typed_tbl
    return delimiterMapping.typed_tbl, nodeCount
end

---@param class any
---@return boolean
local function isClassOverridingMetatables(class)
    local meta = getmetatable(class)
    if meta == nil then
        return false
    end
    for key, _ in pairs(meta) do
        if type(key) == "string" and key:sub(1,2) == "__" and key ~= "__call" then
            -- we don't care about call because it should not be used at this point as the class was already created
            return true
        end
    end
    return false
end

---@param input table
---@param buffer string[] -- in-out buffer to dump the packed data into
---@return string? -- returns the delimiter type or nil on error
function dumpTable(input, buffer)
    if next(input) == nil and GetClass(input) == nil then
        -- input is empty
        -- delimiterMapping.var_arr is the shortest table type in string represent
        table.insert(buffer, packBytes(0, 2))
        return delimiterMapping.var_arr
    end
    local class = GetClass(input)
    if class ~= nil and isClassOverridingMetatables(class) then
        debugPrint(true, "warning, saving a table with class:", class, "when loading it, it will be treated as a normal table, and changes to it's metamethod would not apply")
    end
    if isArray(input) then
        table.insert(buffer, "") -- placeholder for the length field
        local lengthOffset = #buffer
        local delimiterType, itemCount = dumpArr(input, buffer)
        if delimiterType == nil then
            return nil
        end
        buffer[lengthOffset] = packBytes(itemCount, 2)
        return delimiterType
    end
    local delimiterType, itemCount = dump2DTable(input, buffer)
    return delimiterType
end

---@param input boolean | number | string | table
---@return string? -- returns the full packed value of the input or nil on input error
--- Dumps a variable into a string
function Serializer.dumpVariable(input)
    local buffer = {}
    local delimiterType = packVariable(input, buffer)
    if delimiterType == nil then
        return nil
    end
    return table.concat(buffer)
end

---@param p player
---@param input boolean | number | string | table - the input variable to be saved
---@param filePath string
---@param scrambleCallback fun(string):string? | nil - optional callback to be executed on the data (including the checksum) before saving.
--- saves a variable to a file in a Serialized format. Adds a checksum to validate data integrity
function Serializer.saveFile(p, input, filePath, scrambleCallback)
    local data = Serializer.dumpVariable(input)
    if data == nil then
        debugPrint(true, "Failed to save data")
        return false
    end
    debugPrint(false, "after dump variable:", data:sub(1, 10), "end:", data:sub(-10))
    data = addChecksum(data)
    debugPrint(false, "after add checksum:", data:sub(1, 10), "end:", data:sub(-10))
    if scrambleCallback ~= nil then data = scrambleCallback(data) end
    if data == nil then
        debugPrint(true, "Failed to scramble data")
        return false
    end
    debugPrint(false, "after scramble:", data:sub(1, 10), "end:", data:sub(-10))
    if GetLocalPlayer() == p then
        FileIO.Save(filePath, Serializer.TEXT_PREFIX .. data .. "\n")
    end
    return true
end

---@param data string
---@param in_ptr integer
---@param numBytes integer
---@return integer?, integer?
function consumeBytes(data, in_ptr, numBytes)
    if in_ptr + numBytes - 1 > #data then
        debugPrint(true, "invalid data length! ", in_ptr, " ", numBytes, " ", #data)
        return nil
    end
    local out = unpackBytes(data:sub(in_ptr, in_ptr + numBytes - 1))
    debugPrint(false, "consumed ", numBytes, " bytes. ", string.format("0x\x25X", out))

    in_ptr = in_ptr + numBytes
    return out, in_ptr
end

---@param data string -- the packed array
---@param pos integer -- the current position in the data string
---@param count integer -- the number of elements in the array
---@param isSingleType boolean -- true if all array nodes are of the same type
---@return table? -- the loaded table or nil on error
---@return integer? -- new position in the data string
function loadArr(data, pos, count, isSingleType)
    local allValType = nil
    if isSingleType then
        allValType, pos = consumeBytes(data, pos, 1)
        if allValType == nil then
            return nil
        end
    end
    local outTable = {}
    while count > 0 do
        local valueType = allValType
        if valueType == nil then
            valueType, pos = consumeBytes(data, pos, 1)
            if valueType == nil then
                return nil
            end
        end
        local success, tokenVal, newPos = loadTokenAtPos(data, pos, valueType)
        if not success then
            return nil
        end
        pos = newPos
        outTable[#outTable + 1] = tokenVal

        count = count - 1
    end
    return outTable, pos
end

---@param data string
---@param pos integer -- the current position in the data string
---@param token tokenProperties
---@return table? -- the loaded table or nil on error
---@return integer? -- new position in the data string
function loadTable(data, pos, token)
    local nodeCount
    if pos + 1 > #data then
        debugPrint(true, "invalid data length! ", #data)
        return nil
    end
    nodeCount, pos = consumeBytes(data, pos, 2)
    if nodeCount == nil then
        return nil
    end
    if token.subType == "var_arr" or token.subType == "type_arr" then
        local isSingleType = token.subType == "type_arr"
        local valTable, newPos = loadArr(data, pos, nodeCount, isSingleType)
        if valTable == nil then
            return nil
        end
        return valTable, newPos
    end
    local isKeyTyped = token.subType == "var_val_tbl" or token.subType == "typed_tbl"
    local keyTable, newPos = loadArr(data, pos, nodeCount, isKeyTyped)
    if keyTable == nil then
        return nil
    end
    pos = newPos
    local isValTyped = token.subType == "var_key_tbl" or token.subType == "typed_tbl"
    local valTable, newPos2 = loadArr(data, pos, nodeCount, isValTyped)
    if valTable == nil then
        return nil
    end
    pos = newPos2
    local outTable = {}
    for i = 1, nodeCount do
        outTable[keyTable[i]] = valTable[i]
    end
    return outTable, pos
end

---Loads packed with packVariable data into a variable using position-based parsing.
---This avoids creating substrings for each token, which was causing O(n^2) memory usage.
---@param data string -- the full packed data string
---@param pos integer -- the current position in the data string
---@param delTypeByte integer -- the delimiter type as a byte value
---@return boolean -- isSuccess - returns false on fail
---@return any -- value of the loaded variable, or nil on input error
---@return integer? -- new position in the data string
function loadTokenAtPos(data, pos, delTypeByte)
    local delType = string.char(delTypeByte)
    if delimiterList[delType] == nil then
        debugPrint(true, "invalid delimiter! ", delType)
        return false -- bad format
    end
    if delimiterList[delType].type == "const" then
        return true, delimiterList[delType].value, pos
    end
    if delimiterList[delType].type == "tbl" then
        local tbl, newPos = loadTable(data, pos, delimiterList[delType])
        if tbl == nil then
            return false
        end
        return true, tbl, newPos
    end
    -- If we didn't return by now, the token is a number or string
    local tokenLen = delimiterList[delType].num_characters
    local tokenEnd = pos + tokenLen - 1
    if tokenEnd > #data then
        debugPrint(true, "invalid token length!")
        return false -- bad format
    end
    local tokenContent = data:sub(pos, tokenEnd)
    debugPrint(false, "consumed token. len=", tokenLen, ". first byte=: ", tostring(tokenContent):byte(1))
    pos = tokenEnd + 1
    local value
    if delimiterList[delType].type == "num" then
        value = unpackBytes(tokenContent)
        if delimiterList[delType].subType == "flt" then
            -- float doesn't need sine as it's always represented by 4 byte with sign in it already
            value = binaryInteger2Float(value)
        end
    elseif delimiterList[delType].type == "chr" then
        value = tokenContent
    elseif delimiterList[delType].type == "str" then
        local strLen = unpackBytes(tokenContent)
        local strEnd = tokenEnd + strLen
        if strEnd > #data then
            debugPrint(true, "invalid str length! ", strLen, " ", #data)
            return false -- bad format
        end
        value = data:sub(tokenEnd + 1, strEnd)
        pos = strEnd + 1
    elseif delimiterList[delType].type == "unit" then
        value = UniqueIdToUnit[unpackBytes(tokenContent)]
        debugPrint(false, "loading unit token. UniqueId:", unpackBytes(tokenContent), ", unit:", value)
        if value == nil then value = 0 end
    elseif delimiterList[delType].type == "item" then
        value = UniqueIdToItem[unpackBytes(tokenContent)]
        if value == nil then
            value = 0
        end
    end
    debugPrint(false, "finished loading token: ", tostring(value):sub(1, 100))
    return true, value, pos
end

---Loads packed with packVariable data into a variable.
---Legacy wrapper for loadTokenAtPos that maintains backward compatibility.
---@param delType string -- type of the token
---@param data string -- the packed token
---@return boolean -- isSuccess - returns false on fail
---@return any -- value of the loaded variable, or nil on input error
---@return integer? -- number of characters consumed
function loadToken(delType, data)
    local success, val, newPos = loadTokenAtPos(data, 1, string.byte(delType))
    if not success then
        return false
    end
    return true, val, newPos - 1
end

---Loads data packed with dumpVariable into a variable.
---@param data string -- the packed variable
---@return any -- value of the loaded variable. Returns nil on fail. Note that `false` is a valid return value.
---@return integer? -- number of characters consumed
function Serializer.loadVariable(data)
    if #data < 1 then
        debugPrint(true, "empty data!")
        return nil
    end
    local delTypeByte = string.byte(data, 1)
    debugPrint(false, "consumed delimiter (1 byte): ", string.format("0x\x2502X", delTypeByte))
    local success, val, newPos = loadTokenAtPos(data, 2, delTypeByte)
    if not success then
        return nil
    end
    return val, newPos - 1
end

-- gets the packed and scrambled variable and returns the unpacked version of it
---@param packedData string -- the packed and scrambled variable
---@param isDeflate boolean? -- if true, the data will be compressed using zlib. Must match the compression used in Serializer.saveFile.
--- Note that this changes the whole behavior of the packed data, not just the deflate itself.
---@return table? -- value of the loaded variable. Returns nil on fail. Note that `false` is a valid return value.
local function handleSyncData(packedData, isDeflate)
    local decompressed = packedData
    if isDeflate then
        decompressed = LibDeflate.DecompressDeflate(packedData)
        if decompressed == nil then
            debugPrint(true, "Failed to decompress data.")
            print("loading error. Failed to decompress data.")
            return nil
        end
        debugPrint(false, "deflate the second inflate:", decompressed:sub(1, 10), "end:", decompressed:sub(-10))
    end
    local loaded = Serializer.loadVariable(decompressed)
    if loaded == nil then
        debugPrint(true, "Failed to load variable from data.")
        print("loading error. Failed to load variable from data.")
        return nil
    end
    if type(loaded) ~= "table" then
        debugPrint(true, "expected loaded data to be a table.", type(loaded))
        print("loading error. Expected loaded data to be a table.")
        return nil
    end
    return loaded
end

---Loads serialized data from a file or list of files into a table. Syncing the data to all players. Once completed, fires the callback function.
---@param whichPlayer player
---@param filePaths string | string[]-- name of the file/files to load
---@param callback fun(loadedVariables: any) -- callback to execute once loading is done. The callback is getting the synced data that was saved in the file(s). If a single file was given, the data is the variable loaded from that file. If a list of files was given, the data is a list of variables loaded from each file in the same order.
--- where loadedTables is the list of tables loaded from the files or nil on error and whichPlayer is the player that requested the load
---@param unscrambleCallback fun(string):string? | nil - optional callback to be executed on each file data after loading. Must match the scrambleCallback given to saveFile.
---@param isDeflate boolean? - if true, the data will be compressed using zlib before being synced between players (use if you want to reduce network traffic on large data).
---@return string -- an error message. Note that this message can differ between players, and must not be used in a synced way!
-- Message will be an empty string on success, or an error message on failure.
function Serializer.loadFile(whichPlayer, filePaths, callback, unscrambleCallback, isDeflate)
    -- The data in this function is not synced yet, so we have to get to the sync call even if the data is wrong, so that all clients reach the same state
    local errorMsg = ""
    local inputType = type(filePaths)
    if inputType == "string" then
        filePaths = {filePaths}
    end
    local allData = {} ---@type string[]
    for _, filePath in ipairs(filePaths) do
        local isSuccess, scrambledData = false, nil
        if (whichPlayer == GetLocalPlayer()) then
            isSuccess, scrambledData = pcall(FileIO.Load, filePath)
        end
        if not isSuccess then
            errorMsg = "Failed reading load file - Unknown file format."
            scrambledData = ""
        elseif scrambledData == nil then
            errorMsg = "Could not load from local disk."
            scrambledData = ""
        elseif #scrambledData > #Serializer.VERSION and Serializer.VERSION ~= scrambledData:sub(1, #Serializer.VERSION) then
            errorMsg = "Unsupported load file version! expected: " .. Serializer.VERSION .. " got: " .. scrambledData:sub(1, #Serializer.VERSION)
            scrambledData = ""
        elseif #scrambledData < #Serializer.TEXT_PREFIX + 2 then
            errorMsg = "Save file corrupted or unrecognised."
            scrambledData = ""
        else
            debugPrint(false, "After load file:", scrambledData:sub(1, 10), "end:", scrambledData:sub(-10))
            -- remove prefix and ending newline. We don't want to force a format on the prefix, so we just crop until we see PREFIX_END
            local prefixEndIndex = string.find(scrambledData, Serializer.PREFIX_END)
            if not prefixEndIndex then
                errorMsg = "Save file corrupted or unrecognised."
                scrambledData = " "
            else
                scrambledData = scrambledData:sub(prefixEndIndex + #Serializer.PREFIX_END, #scrambledData - 1)
                debugPrint(false, "After prefix:", scrambledData:sub(1, 10), "end:", scrambledData:sub(-10))
            end
        end
        if whichPlayer ~= GetLocalPlayer() and errorMsg ~= "" then
            debugPrint(false, errorMsg)
        end
        local unscrambled = scrambledData
        local loadedVar = ""
        if errorMsg == "" then
            if unscrambleCallback ~= nil then unscrambled = unscrambleCallback(scrambledData) end
            if unscrambled == nil then
                errorMsg = "Failed to unscramble data."
                unscrambled = ""
            else
                debugPrint(false, "After unscramble:", unscrambled:sub(1, 10), "end:", unscrambled:sub(-10))
            end
            if type(unscrambled) ~= "string" then
                errorMsg = "Failed to load from file - Unknown file format."
                unscrambled = ""
                debugPrint(true, "expected loaded data to be a list of strings.")
            end
            debugPrint(false, "after load variable:", unscrambled:sub(1, 10), "end:", unscrambled:sub(-10))
            local rawData, isValid = separateAndValidateChecksum(unscrambled)
            debugPrint(false, "after removing checksum:", rawData:sub(1, 10), "end:", rawData:sub(-10))
            if isValid then
                -- this should return the original variable saved by Serializer.saveFile
                loadedVar = Serializer.loadVariable(rawData)
                if loadedVar == nil then
                    debugPrint(true, "Failed to load variable from data1.")
                    loadedVar = ""
                end
            else
                --tampering detected
                if (whichPlayer == GetLocalPlayer()) then
                    -- data was not synced yet, so we can expect other players to fail here
                    debugPrint(true, "invalid checksum! bytes=", unpackBytes(rawData:sub(1, 4)), ". calc:", getChecksum(rawData:sub(5)), ". len(rawData) ==", #rawData)
                    -- for i=1,#rawData do
                    --     debugPrint(false, tostring(i), ": ", tostring(rawData:byte(i)))
                    -- end
                end
                errorMsg = "Tempered file detected - bad checksum."
            end
        end
        table.insert(allData, loadedVar)
    end
    local packedData = Serializer.dumpVariable(allData)
    if packedData == nil then
        errorMsg = "Bad data in save file."
        packedData = ""
    end
    debugPrint(false, "After dump all to one:", packedData:sub(1, 10), "end:", packedData:sub(-10))
    if isDeflate then
        packedData = LibDeflate.CompressDeflate(packedData) or ""
        debugPrint(false, "After second inflate:", packedData:sub(1, 10), "end:", packedData:sub(-10))
    end

    debugPrint(false, "data to sync:", packedData:sub(1, 10), "end:", packedData:sub(-10))
    SyncStream.sync(whichPlayer, packedData, function(syncedData)
        debugPrint(false, "finished syncing", #syncedData, "bytes of data. syncedData:", syncedData:sub(1, 10), "end:", syncedData:sub(-10))
        if syncedData == "" or syncedData == nil then
            debugPrint(false, "no data synced!")
            return
        end
        local loadedTables = handleSyncData(syncedData, isDeflate)
        if inputType == "string" and loadedTables ~= nil and #loadedTables == 1 then
            loadedTables = loadedTables[1]
        end
        if loadedTables ~= nil then callback(loadedTables) end
    end)
    return errorMsg
end

end
if Debug then Debug.endFile() end
