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

function Sound2()
    local s = CreateSound("Sound\\Interface\\Warning\\Human\\KnightInventoryFull1.flac", false, false, false, 0xA, 0xA, "DefaultEAXON")
    SetSoundVolume(s, 127)
    SetSoundPitch(s, 0.6)
    StartSound(s)
    for i = 1, 1600 do
        KillSoundWhenDone(s)
    end
end

  function StressSoundTest(useAttach, useKillWhenDone, count, interval)
      local i = 0
      local u = CreateUnit(Player(0), FourCC("hfoo"), 0, 0, 0)
      local t = CreateTimer()
      TimerStart(t, interval, true, function()
          i = i + 1
          if i >= count then
              DestroyTimer(t)
              print("StressSoundTest done: " .. i .. " sounds created")
              return
          end
          local s = CreateSound("Sound\\Interface\\Warning\\Human\\KnightInventoryFull1.flac", false, true, false, 0xA, 0xA, "")
          SetSoundPitch(s, GetRandomReal(0.8, 1))
          SetSoundVolume(s, 0x7F)
          SetSoundDistances(s, 600, 0x2710)
          SetSoundDistanceCutoff(s, 0xBB8)
          if useAttach then
              AttachSoundToUnit(s, u)
          else
              SetSoundPosition(s, GetUnitX(u), GetUnitY(u), 0)
          end
          if i % (count / 10) == 0 then
                KillUnit(u)
          end
          StartSound(s)
          if i % (count / 10) == 5 then
                KillUnit(u)
          end
          if useKillWhenDone then
              KillSoundWhenDone(s)
          end
      end)
  end

function MultiSound()
    StressSoundTest(true, true, 2000, 0.01)
    StressSoundTest(false, true, 2000, 0.01)
    StressSoundTest(true, false, 2000, 0.01)

    s = {}
    u = {}
    for i = 1, 1600 do
        s[i] = CreateSound("Sound\\Interface\\Warning\\Human\\KnightInventoryFull1.flac", false, false, false, 0xA, 0xA, "DefaultEAXON")
        a = CreateSound("sdafdfasfdas.flac", false, false, false, 0xA, 0xA, "DefaultEAXON")
        u[i] = CreateUnit(Player(0), FourCC("hfoo"), 0, 0, 0)
        SetSoundVolume(s[i], 127)
        SetSoundPitch(s[i], 0.6)
        AttachSoundToUnit(s[i], u[i])
    end
    for i = 1, 1600 do
        StartSound(s[i])

    end
    for i = 1, 1600 do
        KillUnit(u[i])
    end
    for i = 1, 1600 do
        if s[i] == nil then
            print("nil!!!")
        end
        KillSoundWhenDone(s[i])
    end
end

function CrashTest()
    local a = CreateUnit(Player(0), FourCC("hfoo"), 0,0,0)
    SetUnitX(a, 10000)
    IssuePointOrder(a, 'attack', 0, 0)

    -- print("Crash test ExecuteFunc")
    -- ExecuteFunc("CrashingFun")
    -- TriggerSleepAction(1)

    -- a = CreateTimer()
    -- TimerStart(a, 2, false, function()
    --     print("sleep from wc3 coroutine")
    --     TriggerSleepAction(5)
    --     print("sleep from wc3 coroutine done")
    -- end)
    -- FileIO.Save("test1.txt", "n")
    -- local test1 = FileIO.Load("test1.txt")
    -- if test1 == nil then
    --     test1 = "nil"
    --     print("test1 is nil!")
    -- else
    --     print(test1)
    -- end
    -- FileIO.Save("test.txt", "\n")
    -- local test = FileIO.Load("test.txt")
    -- if test == nil then
    --     test = "nil"
    --     print("test is nil!")
    -- else
    --     print(test)
    -- end

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
    local msg = "Type -d to dump recent functions to log. Type -s to trigger a desyncing function. -c for crash test. -e for escaping tests. -sy for syncStream tests. -se for serializer tests. -b for breakpoint tests. Counter =" ..
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
    test_saveLoad()
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

function SaveState(triggerPlayer, args)
    local stateName = args[1] or "default"
    StateSaver.SaveState(stateName)
    print("State saved with name", stateName)
end

function LoadState(triggerPlayer, args)
    local t = CreateTrigger()
    local stateName = args[1] or "default"
    TriggerAddAction(t, function()
        --- Load state files can be ran at game start.
        StateSaver.LoadStateFiles(triggerPlayer, {stateName})

        print("Loading state files. This might take a few seconds")
        --- wait for state data to finish loading
        local count = 0
        while next(SaveStateDatas) == nil do
            if count == 600 then
                LogWriteNoFlush("Error! state data didn't load in time. Aborting.")
                return
            end
            TriggerSleepAction(0.1)
        end

        -- Before running loadState, you should clear any game data that is not needed
        for u, data in pairs(AllUnitIds) do
            RemoveUnit(u)
        end

        -- in the callback, you can run anything needed before unit skills and stats are loaded
        StateSaver.LoadState(1, function() end)
        print("State loaded with name", stateName)
        LogWrite("State loaded with name", stateName)
    end)
    TriggerExecute(t)
end

function RegisterEvents()
    ExecutedTrigger = CreateTrigger()
    TriggerAddAction(ExecutedTrigger, ExecutedFunctionWithTSA)
    RegisterFastTimer()
    RegisterSlowTimer()
    CoroutineStarted()
    --- setting Mage as global so I can later access it from the console
    Mage = CreateUnit(Player(0), FourCC("Hblm"), 0, 0, 0)
    SetHeroLevel(Mage, 9, false)
    --- Test logging:
    LogWrite("Testing log:", Mage, {a = 1.35, [3] = 2, c = {Mage, "string", math.pi}})
end

OnInit.final(RegisterEvents)

if Debug then Debug.endFile() end
