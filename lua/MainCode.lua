if Debug then Debug.beginFile("MainCode") end

local Counter = 0 ---@type integer
local ExecutedTrigger ---@type trigger

function CoroutineYielder()
    -- no one should resume this yield, so the function will apear in the log
    coroutine.yield()
end

function CoroutineStarted()
    local co = coroutine.create(CoroutineYielder)
    coroutine.resume(co)
end

function ExecutedFunctionWithTSA()
    print("Running ExecutedFunctionWithTSA")
    TriggerSleepAction(10)
end

function DumpRecentWrap()
    --function that you should see in the "recent funcs" section of the log
    print("Dumping recent functions to log")
    TriggerExecute(ExecutedTrigger)
    LogRecentFuncs()
end

function CrashingFun()
    print("Crashing")
    error()
    print("Crashing end")
end

function CrashTest()
    -- print("Crash test ExecuteFunc")
    -- ExecuteFunc("CrashingFun")
    -- TriggerSleepAction(1)

    -- a = CreateTimer()
    -- TimerStart(a, 2, false, function()
    --     print("sleep from wc3 coroutine")
    --     TriggerSleepAction(5)
    --     print("sleep from wc3 coroutine done")
    -- end)
    FileIO.Save("test1.txt", "n")
    local test1 = FileIO.Load("test1.txt")
    if test1 == nil then
        test1 = "nil"
        print("test1 is nil!")
    else
        print(test1)
    end
    FileIO.Save("test.txt", "\n")
    local test = FileIO.Load("test.txt")
    if test == nil then
        test = "nil"
        print("test is nil!")
    else
        print(test)
    end

    -- print("TimerCrashTest")
    -- local tt = CreateTimer()
    -- TimerStart(tt, 1, false, CrashingFun)
    -- TriggerSleepAction(2)
    -- TimerStart(tt, 1, false, function() print("timer ok") end)
    -- print("Crash test end")


    -- print("Timer reset test")
    -- local tt = CreateTimer()
    -- TimerStart(tt, 2, false, function() print("timer 1 ok") end)
    -- TriggerSleepAction(1)
    -- TimerStart(tt, 2, false, function() print("timer 2 ok") end)
    -- print("Timer reset test end")


    -- print("no func test")
    -- local tt = CreateTimer()
    -- TimerStart(tt, 1, false, gsfsgsgf)
    -- TriggerSleepAction(2)
    -- TimerStart(tt, 1, false, function() print("timer 2 ok") end)
    -- print("Timer reset test end")
end

function RegisterFastTimer()
    TimerStart(CreateTimer(), 0.03, true, function() Counter = Counter + 1 end)
end

function RegisterSlowTimer()
    local msg = "Type -d to dump recent functions to log. Type -s to trigger a desyncing function. -c for crash test. -e for escaping tests. -sy for syncStream tests. -se for serializer tests. Counter =" ..
                Counter
    print(msg)
    TimerStart(CreateTimer(), 20, true,
        function()
            print(msg)
        end)
end

function TestEscaping()
    test_AddEscaping()
    test_RemoveEscaping()
    test_roundtrip()
    print("All escaping tests done")
end

function TestSerializer()
    test_dumpLoad()
    print("All serializer tests done")
end

function TestSyncStream()
    ExecuteFunc(test_sync)
end

function CreateUnitForPlayer()
    print("Desyncing. This can take up to 15 seconds I think")
    if GetTriggerPlayer() == GetLocalPlayer() then
        CreateUnit(GetTriggerPlayer(), FourCC('hfoo'), 0, 0, 0)
    end
end

function FlushLog()
    LogWrite("")
end

-- Table mapping event chat command to their handler functions
local chatHandlers = {}

-- can't init some of these things in the root as the functions are not all defined yet
-- the functions here can get the command arguments, and the trigger player as args
OnInit.trig(function() chatHandlers =  {
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

function strSplitBySpace(str)
    local result = {}
    for word in string.gmatch(str, "\x25S+") do
        table.insert(result, word)
    end
    return result
end

function handleChatCmd()
    local triggerPlayer = GetTriggerPlayer() ---@type player
    local chatStr = GetEventPlayerChatString()
    local spliced = strSplitBySpace(chatStr)
    local cmd = string.lower(spliced[1])
    table.remove(spliced, 1)
    local args = spliced
    if chatHandlers[cmd] then
        chatHandlers[cmd](triggerPlayer, args)
    end
end

function RegisterEvents()
    local ChatCmdTrigger = CreateTrigger()
    TriggerAddAction(ChatCmdTrigger, handleChatCmd)
    for i = 0, GetBJMaxPlayers() - 1 do
        TriggerRegisterPlayerChatEvent(ChatCmdTrigger, Player(i), "-", false)
    end

    ExecutedTrigger = CreateTrigger()
    TriggerAddAction(ExecutedTrigger, ExecutedFunctionWithTSA)
    RegisterFastTimer()
    RegisterSlowTimer()
    CoroutineStarted()
end

OnInit(RegisterEvents)

if Debug then Debug.endFile() end
