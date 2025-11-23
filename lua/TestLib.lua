if Debug then Debug.beginFile("TestLib") end
do
Debug = Debug or {assert=assert, endFile=function() end, throwError=function(...) assert(false, ...) end}
LogWrite = LogWrite or function(...) print(...) end

--- Recursively compares two tables for deep equality.
---@param t1 table
---@param t2 table
---@param visited table? -- Used internally to track already compared tables
---@return boolean
function deepCompare(t1, t2, visited)
    -- If both are not tables, compare directly
    if type(t1) ~= type(t2) then
        Debug.throwError("deepCompare: tables not equal: " .. tostring(t1) .. " and " .. tostring(t2))
        return false
    end
    if type(t1) ~= "table" then
        if t1 == t2 then
            return true
        elseif type(t1) == "number" and math.abs(t1 - t2) < 0.00001 then
            return true
        end

        Debug.throwError("deepCompare: tables not equal: " .. tostring(t1) .. " and " .. tostring(t2))
        return false
    end

    -- Prevent infinite loops by tracking already visited tables
    visited = visited or {}
    if visited[t1] and visited[t2] then
        return true
    end
    visited[t1], visited[t2] = true, true

    -- Compare number of keys
    local keys1, keys2 = {}, {}
    local hasNil1, hasNil2 = false, false
    for k in pairs(t1) do
        if type(k) == "number" and math.floor(k) ~= k then
            --floats might lose some precision when converted to string, so we round them to 5 decimal places
            keys1[string.format("\x25.5f", k)] = true
        elseif type(k) == "nil" then
            hasNil1 = true
        else
            keys1[k] = true
        end
    end
    for k in pairs(t2) do
        if type(k) == "number" and math.floor(k) ~= k then
            --floats might lose some precision when converted to string, so we round them to 5 decimal places
            keys2[string.format("\x25.5f", k)] = true
        elseif type(k) == "nil" then
            hasNil2 = true
        else
            keys2[k] = true
        end
    end
    for k in pairs(keys1) do
        -- LogWrite("comparing key " .. tostring(k) .. ". First table: " .. tostring(t1[k]):sub(1, 100) .. ", second table: " .. tostring(t2[k]):sub(1, 100))
        if not keys2[k] then
            Debug.throwError("deepCompare: tables not equal: key " .. tostring(k) .. " not found in second table")
            return false
        end
        if not deepCompare(t1[k], t2[k], visited) then return false end
    end
    if hasNil1 ~= hasNil2 then
        local which = hasNil1 and "first" or "second"
        Debug.throwError("deepCompare: tables not equal: " .. which .. " has nil keys and the other doesn't")
        return false
    end
    for k in pairs(keys2) do
        if not keys1[k] then
            Debug.throwError("deepCompare: tables not equal: key " .. tostring(k) .. " not found in first table")
            return false
        end
    end

    return true
end

function test_AddEscaping()
    local tests = {
        -- input, output with load chars escaped, output with save chars escaped
        {"hello", "hello", "hello"},
        {"\0\10\13\91\92\93", "\248\249\250\91\251\252", "\248\10\13\91\92\93"}, -- fileio_unsupported_chars replaced (note: 91 and 92 are supported by FileIO in save mode)
        {"\247", "\247\247", "\247\247"}, -- escape_char doubled
        {"\248", "\247\248", "\247\248"},-- unprintable_replacables escaped
        {"\250", "\247\250", "\250"},
        {"hello\n\247\0world", "hello\249\247\247\248world", "hello\n\247\247\248world"},
        {"hello\250world", "hello\247\250world", "hello\250world"}
    }

    for i, test in ipairs(tests) do
        local input, expected1, expected2 = test[1], test[2], test[3]
        local result1 = AddEscaping(input, FileIO_unsupportedLoadChars)
        Debug.assert(result1 == expected1, string.format("AddEscaping failed on test \x25d: expected \x25q, got \x25q", i, expected1, result1))
        local result2 = AddEscaping(input, FileIO_unsupportedSaveChars)
        Debug.assert(result2 == expected2, string.format("AddEscaping failed on test \x25d: expected \x25q, got \x25q", i, expected2, result2))
    end
    LogWrite("All AddEscaping tests passed!")
end

function test_RemoveEscaping()
    local tests = {
        {"hello", "hello", "hello"},
        {"\248\249\250\91\251\252", "\0\10\13\91\92\93", "\0\249\250\91\251\252"}, -- reversed replacements (note: with SaveChars only byte 0 is replaced, others stay as-is)
        {"\247\247", "\247", "\247"}, -- double escape_char restored
        {"\247\248", "\248", "\248"}, -- escaped chars restored
        {"hello\249\247\247\248world", "hello\n\247\0world", "hello\249\247\0world"},
        {"hello\247\248world", "hello\248world", "hello\248world"}
    }

    for i, test in ipairs(tests) do
        local input, expected1, expected2 = test[1], test[2], test[3]
        local result = RemoveEscaping(input, FileIO_unsupportedLoadChars)
        Debug.assert(result == expected1, string.format("RemoveEscaping failed on test \x25d: expected \x25q, got \x25q", i, expected1, result))
        local result2 = RemoveEscaping(input, FileIO_unsupportedSaveChars)
        Debug.assert(result2 == expected2, string.format("RemoveEscaping failed on test \x25d: expected \x25q, got \x25q", i, expected2, result2))
    end
    LogWrite("All RemoveEscaping tests passed!")
end

function test_roundtrip()
    local tests = {
        "hello",
        "\0\13\91\92\93",
        "\247",
        "\248\249\250\251\252",
        "so\nme\247text\250here",
        "\247\248\249\250\251\252"
    }

    for i, test in ipairs(tests) do
        local escaped = AddEscaping(test, FileIO_unsupportedLoadChars)
        local unescaped = RemoveEscaping(escaped, FileIO_unsupportedLoadChars)
        Debug.assert(unescaped == test, string.format("Roundtrip failed on test \x25d: expected \x25q, got \x25q", i, test, unescaped))
        local escaped2 = AddEscaping(test, FileIO_unsupportedSaveChars)
        local unescaped2 = RemoveEscaping(escaped2, FileIO_unsupportedSaveChars)
        Debug.assert(unescaped2 == test, string.format("Roundtrip failed on test \x25d: expected \x25q, got \x25q", i, test, unescaped2))
    end
    LogWrite("All roundtrip tests passed!")
end

---@type any[]
local origTable = {
    true,
    false,
    1,
    -1, -- only works for 32 bit lua
    0,
    255,
    256^2 - 1,
    0x7FFFFFFF, -- the maximum positive integer
    0x7FFFFFFF, -- the maximum positive integer
    0xFFFFFFFF, -- -1
    0x80000000, -- the minimum negative integer
    math.pi,
    "hello",
    "\0\10\13\91\92\93\248\249\250\251\252\253",
    string.rep("s", 257 ),
    "",
    -- string.rep("d", 256*175 ), -- this test is spamming the log so skipping it by default
    "h",
    "ab!!",
    {},  -- Empty table
    { key1 = "value1", key2 = "value2" },  -- Table with string keys
    { 100, 200, 300 },  -- Table with only numeric values
    { 0, 1, 2, 1000, 256^3 },  -- Table with growing values
    { 256^3, 1000, 2, 1, 0 },  -- Table with decreasing values
    { [1] = "a", [3] = "c", [5] = "e" },  -- Sparse array
    { nested = { a = 1, b = { c = 2, d = { e = 3 } } } },  -- Deeply nested table
    { { { { { "deep" } } } } },  -- Extreme nesting level
    { special = { "\x0A", "\x09", "\x0D", "\x00", "\x5D", "\x5C" } },  -- Special characters (\n, \t, \r, \0, ], \)
    { mixed = { "string", 123, true, false, 0, { nested = "inside" } } },  -- Mixed types
    { largeNumbers = { 0x40000000, 0x7FFFFFFF, 0x80000000, 0xBFFFFFFF } },  -- Large numbers (2^30, 2^31-1, -2^31, -2^30)
}
-- for i=0, 255 do
--     origTable[#origTable + 1] = string.char(i)
-- end

---@param tbl table? -- if not given, origTable is used
function test_dumpLoad(tbl)
    tbl = tbl or origTable
    local packedStr = Serializer.dumpVariable(tbl)
    LogWrite("writing done")
    local loadedVar, charsConsumed = Serializer.loadVariable(packedStr)
    LogWrite("load done")
    Debug.assert(loadedVar ~= nil, "loadVariable failed")
    Debug.assert(charsConsumed == #packedStr, "loadVariable didn't consume all characters. " .. tostring(charsConsumed) .. ", " .. tostring(#packedStr))
    Debug.assert(deepCompare(tbl, loadedVar), "loaded table doesn't match the original table")
end

---@param testName string
---@param datas string[]
function singleSyncTest(testName, datas)
    local doneSyncs = {}
    local totalFlits = 0
    local startTime = os.clock()
    for i, data in ipairs(datas) do
        totalFlits = totalFlits + math.ceil((#data + 1) / FLIT_DATA_SIZE)

        doneSyncs[i] = false
        SyncStream.sync(Player(0), data, function (syncedData)
            Debug.assert(type(syncedData) == "string", "got " .. type(syncedData) .. " sync data")
            Debug.assert(#syncedData == #data, "wrong len for syncData. Expected: " .. #data .. ", got: " .. #syncedData .. ". " .. string.sub(syncedData, 1, 50) .. "...")
            Debug.assert(syncedData == data, "wrong data for syncData. Expected: " .. string.sub(data, 1, 50)  .. ". got: " .. string.sub(syncedData, 1, 5000) .. "...")
            doneSyncs[i] = true
            -- LogWrite(testName, "sync", i, "done")
        end)
    end
    local expectedTransferTimer = (totalFlits * FLIT_DATA_SIZE) / TRANSFER_RATE
    LogWrite(testName, "test started. Expected time:", expectedTransferTimer * 1.1, "seconds") -- add some time for the sleep
    print(testName, "test started. Expected time:", expectedTransferTimer * 1.1, "seconds") -- add some time for the sleep
    local allDone = true
    for _ = 0, 100 do
        TriggerSleepAction(math.max(expectedTransferTimer / 10, 0.1))
        allDone = true
        for i = 1, #datas do
            if not doneSyncs[i] then
                allDone = false
                break
            end
        end
        if allDone then
            break
        end
    end
    local endTime = os.clock()
    if allDone then
        LogWrite(testName, "test done. Took", endTime-startTime, "seconds")
        print(testName, "test done. Took", endTime-startTime, "seconds")
    else
        LogWrite(testName, "test timed out")
        print(testName, "test timed out")
        Debug.throwError(testName, "test timed out")
    end
end

function test_sync()
    LogWrite("testing syncs")
    singleSyncTest("empty sync", {""})
    local singleByteDatas = {}
    local longDataTable = {"a", "a"}
    for i = 0, 255 do
        table.insert(singleByteDatas, string.char(i))
        table.insert(longDataTable, string.rep(string.char(i), 254))
    end
    table.insert(longDataTable, "")
    local longData = table.concat(longDataTable)
    singleSyncTest("single char sync", singleByteDatas)
    singleSyncTest("same char + large string sync", {"a", "a", longData})

    singleSyncTest("all chars", {table.concat(singleByteDatas)})

    print("test_sync validation done")
    LogWrite("test_sync validation done")
end

function test_saveLoad()
    local success = Serializer.saveFile(Player(0), origTable, "Savegames\\TestMap\\test_save_load_0.txt")
    Debug.assert(success, "saveFile failed")
    LogWrite("saveFile saved")

    -- Doing GetLocalPlayer here to make sure the syncing really work even when running in LAN with 2 players on the same computer
    local callbackExecuted = false
    local error = Serializer.loadFile(Player(0),"Savegames\\TestMap\\test_save_load_" .. GetPlayerId((GetLocalPlayer())) .. ".txt", function(loadedVars)
        LogWrite("in callback")
        if loadedVars == nil then
            Debug.throwError("loadFile returned nil")
            return
        end
        Debug.assert(deepCompare(origTable, loadedVars), "loaded table doesn't match the original table")
        LogWrite("EndFunc test ended! validation done")
        callbackExecuted = true
    end)
    LogWrite("loaded returned:", error)
    
    -- Wait for the callback to be executed
    local count = 0
    while not callbackExecuted and count < 100 do
        TriggerSleepAction(0.1)
        count = count + 1
    end
    if not callbackExecuted then
        Debug.throwError("test_saveLoad timed out waiting for callback")
    end
end

--- Syncs all the data in input. Must be called from a yieldable coroutine
---@param input string[] -- each string should be of up to FLIT_DATA_SIZE characters.
function TestOriginalSync(input)
    LogWriteNoFlush("TestOriginalSync start")
    print("TestOriginalSync start")
    local syncTrigger = CreateTrigger()
    for i = 0, bj_MAX_PLAYER_SLOTS - 1 do
        BlzTriggerRegisterPlayerSyncEvent(syncTrigger, Player(i), "Synd", false)
    end
    local nextExpected = 1
    TriggerAddAction(syncTrigger, function()
        local package = BlzGetTriggerSyncData()
        LogWriteNoFlush("received packet #" .. nextExpected .. ". data: " .. string.sub(package, 1, 10) .. "...")
        Debug.assert(#package == #input[nextExpected], "bad package len. Got:" .. #package .. " for packet #" .. nextExpected .. " data:" .. string.sub(package, 1, 10) .. "...")
        Debug.assert(package == input[nextExpected], "bad package for packet #" .. nextExpected .. ". Got: " .. package)
        nextExpected = nextExpected + 1
        if nextExpected > #input then
            DisableTrigger(syncTrigger)
            DestroyTrigger(syncTrigger)
        end
    end)

    local syncTimer = CreateTimer()
    local nextPacket = 1
    TimerStart(syncTimer, 1 / 16, true, function()
        Debug.assert(#input[nextPacket] <= FLIT_DATA_SIZE, "input packet too large")
        LogWriteNoFlush("sending packet #" .. nextPacket .. ". data: " .. string.sub(input[nextPacket], 1, 10) .. "...")
        Debug.assert(BlzSendSyncData("Synd", input[nextPacket]), "send failed!!!!")
        nextPacket = nextPacket + 1
        if nextPacket > #input then
            PauseTimer(syncTimer)
            DestroyTimer(syncTimer)
        end
    end)

    local count = 0
    while nextExpected <= #input and count < 600 do
        TriggerSleepAction(0.1)
        count = count + 1
    end
    if count >= 600 then
        Debug.throwError("TestOriginalSync timed out")
    else
        LogWriteNoFlush("TestOriginalSync done")
        print("TestOriginalSync done!")
    end
end

function TestOrigSync()
    ExecuteFunc(function()
        local longData = {"a", "a"}
        for i = 0, 255 do
            if i == 0 or i == 92 then
                table.insert(longData, string.rep("\248", 255))
            else
                table.insert(longData, string.rep(string.char(i), 255))
            end
        end
        table.insert(longData, "")

        TestOriginalSync(longData)
        LogWriteNoFlush("TestOrigSync valildation done")
        print("TestOrigSync valildation done!")
    end)
end

function testFileIO()
    print("testing FileIO savefile/loadfile")
    LogWriteNoFlush("testing FileIO savefile/loadfile")

    -- test load:

    local testData = {
        "Hello, World!",
        "\0\10\13\91\92\93",
        string.rep("A", 5000),
        "\nLine1\nLine2\r\nLine3]",
        "\247\248\249\250\251\252\253",
        "--[[",
        "[[",
        "Mixed \0 data \10 with \13 special \91 characters \92 and \93 end.",

    }
    local allChars = {}
    local allCharsSave = {}
    for i = 0, 255 do
        table.insert(allChars, string.rep(string.char(i), MAX_TEXT_LOAD))
        table.insert(allCharsSave, string.rep(string.char(i),  MAX_TEXT_SAVE))
    end
    table.insert(testData, table.concat(allChars))

    for i, data in ipairs(testData) do
        local filenameLoad = "Savegames\\tests\\test_fileio_load_" .. i .. ".txt"

        FileIO.Save(filenameLoad, data)
        local loadedData = FileIO.Load(filenameLoad)
        Debug.assert(loadedData ~= nil, "FileIO.Load returned nil for file: " .. filenameLoad)
        Debug.assert(loadedData == data, "FileIO Load data mismatch for file: " .. filenameLoad .. ". Expected: " .. string.sub(data, 1, 50) .. "... Got: " .. string.sub(loadedData, 1, 50) .. "...")
    end

    local filenameSave = "Savegames\\tests\\test_fileio_save.txt"
    FileIO.Save(filenameSave, table.concat(allCharsSave), false) -- save without load escaping
    print("File IO save cannot be automatically validated. Please check that the file " .. filenameSave .. " was created and looks correct.")
    LogWriteNoFlush("File IO save cannot be automatically validated. Please check that the file " .. filenameSave .. " was created and looks correct.")

    print("FileIO savefile/loadfile end")
    LogWriteNoFlush("FileIO savefile/loadfile end")
end

OnInit.final(function()
    -- Run tests
    -- test_AddEscaping()
    -- test_RemoveEscaping()
    -- test_roundtrip()
    -- LogWrite("escaping validation done")
    -- test_dumpLoad()
    -- LogWrite("test_dumpLoad validation done")
    -- testFileIO()
    -- ExecuteFunc(test_sync)
    -- ExecuteFunc(test_saveLoad)
end)

end

if Debug then Debug.endFile() end
