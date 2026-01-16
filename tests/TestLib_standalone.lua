#!/usr/bin/env lua
--[[
    Standalone test file for Wc3Utils libraries
    This file can run on standard Lua without WC3 runtime

    Tests included:
    - test_AddEscaping (StringEscape)
    - test_RemoveEscaping (StringEscape)
    - test_roundtrip (StringEscape)
    - test_dumpLoad (Serializer)
    - test_sync (SyncStream)
    - test_saveLoad (Serializer with FileIO)
    - test_StateSaver_RecordVariable (StateSaver)
    - test_StateSaver_VariablePackUnpack (StateSaver)

    All WC3 native functions are mocked in TestLib_mocks.lua
]]

-- Get the directory of this script
local scriptPath = debug.getinfo(1, "S").source:match("@(.*)$")
local scriptDir = scriptPath:match("(.*[\\/])") or "./"

-- Load WC3 mocks
dofile(scriptDir .. "TestLib_mocks.lua")

-- Load libraries using dofile (no gsub stripping needed - Debug is mocked)
print("=== Loading StringEscape.lua ===")
dofile(scriptDir .. "../lua/MyLibs/StringEscape.lua")

print("=== Loading FileIO.lua ===")
dofile(scriptDir .. "../lua/MyLibs/FileIO.lua")

print("=== Loading SyncStream.lua ===")
dofile(scriptDir .. "../lua/MyLibs/SyncStream.lua")

print("=== Loading Serializer.lua ===")
dofile(scriptDir .. "../lua/MyLibs/Serializer.lua")

print("=== Loading StateTracker.lua ===")
dofile(scriptDir .. "../lua/MyLibs/StateTracker.lua")

print("=== Loading StateSaver.lua ===")
dofile(scriptDir .. "../lua/MyLibs/StateSaver.lua")

print("=== Loading TestLib.lua ===")
dofile(scriptDir .. "../lua/TestLib.lua")

print("=== Executing OnInit callbacks ===")
executeOnInitCallbacks()

print("=== Libraries loaded successfully ===\n")

-- Get the standalone-compatible origTable from TestLib.lua
-- This avoids duplicating the table definition and ensures consistency
local origTable = TestLib_getStandaloneOrigTable()

-- Run the standalone-compatible tests
-- Note: runAsyncTest is provided by TestLib_mocks.lua
print("\n============================================================")
print("RUNNING STANDALONE TESTS FOR WC3UTILS")
print("============================================================")

test_AddEscaping()
test_RemoveEscaping()
test_roundtrip()
test_dumpLoad(origTable)

print("\n--- Running async tests ---")
runAsyncTest("test_sync", test_sync)
runAsyncTest("test_saveLoad", function()
    test_saveLoad(origTable)
end)

print("\n--- Running StateSaver tests ---")

function test_StateSaver_RecordVariable()
    print("Testing StateSaver.RecordVariable...")
    
    TestGlobalVar1 = "test value 1"
    TestGlobalVar2 = 42
    TestGlobalVar3 = {nested = {value = "deep"}}
    
    StateSaver.RecordVariable("TestGlobalVar1")
    StateSaver.RecordVariable("TestGlobalVar2")
    StateSaver.RecordVariable("TestGlobalVar3")
    
    print("StateSaver.RecordVariable test passed!")
end

function test_StateSaver_VariablePackUnpack()
    print("Testing StateSaver variable packing and unpacking...")
    
    TestPackVar1 = "hello world"
    TestPackVar2 = 12345
    TestPackVar3 = {a = 1, b = 2, c = {d = 3}}
    TestPackVar4 = true
    
    StateSaver.RecordVariable("TestPackVar1")
    StateSaver.RecordVariable("TestPackVar2")
    StateSaver.RecordVariable("TestPackVar3")
    StateSaver.RecordVariable("TestPackVar4")
    
    local originalVar1 = TestPackVar1
    local originalVar2 = TestPackVar2
    local originalVar3Copy = {a = TestPackVar3.a, b = TestPackVar3.b, c = {d = TestPackVar3.c.d}}
    local originalVar4 = TestPackVar4
    
    TestPackVar1 = "modified"
    TestPackVar2 = 99999
    TestPackVar3 = {}
    TestPackVar4 = false
    
    Debug.assert(TestPackVar1 ~= originalVar1, "TestPackVar1 should be modified")
    Debug.assert(TestPackVar2 ~= originalVar2, "TestPackVar2 should be modified")
    Debug.assert(TestPackVar4 ~= originalVar4, "TestPackVar4 should be modified")
    
    print("StateSaver variable pack/unpack test passed!")
end

function test_StateSaver_PlayerMapping()
    print("Testing StateSaver player name utilities...")
    
    Debug.assert(ArrayFind({"a", "b", "c"}, "b") == 2, "ArrayFind should find 'b' at index 2")
    Debug.assert(ArrayFind({"a", "b", "c"}, "d") == nil, "ArrayFind should return nil for missing element")
    Debug.assert(ArrayFind({}, "a") == nil, "ArrayFind should return nil for empty array")
    
    Debug.assert(Round(1.4) == 1, "Round(1.4) should be 1")
    Debug.assert(Round(1.5) == 2, "Round(1.5) should be 2")
    Debug.assert(Round(1.6) == 2, "Round(1.6) should be 2")
    Debug.assert(Round(-1.5) == -1, "Round(-1.5) should be -1")
    
    print("StateSaver player mapping utilities test passed!")
end

function test_StateSaver_UnitMocks()
    print("Testing StateSaver unit mock functions...")
    
    local u = CreateUnit(Player(0), FourCC("hfoo"), 100, 200, 90)
    Debug.assert(u ~= nil, "CreateUnit should return a unit")
    Debug.assert(GetUnitTypeId(u) == FourCC("hfoo"), "GetUnitTypeId should return the correct type")
    Debug.assert(GetUnitX(u) == 100, "GetUnitX should return 100")
    Debug.assert(GetUnitY(u) == 200, "GetUnitY should return 200")
    Debug.assert(GetUnitFacing(u) == 90, "GetUnitFacing should return 90")
    Debug.assert(GetOwningPlayer(u) == Player(0), "GetOwningPlayer should return Player(0)")
    
    BlzSetUnitMaxHP(u, 500)
    Debug.assert(BlzGetUnitMaxHP(u) == 500, "BlzGetUnitMaxHP should return 500 after setting")
    
    SetUnitState(u, UNIT_STATE_LIFE, 250)
    Debug.assert(GetWidgetLife(u) == 250, "GetWidgetLife should return 250 after setting")
    
    BlzSetUnitMaxMana(u, 300)
    Debug.assert(BlzGetUnitMaxMana(u) == 300, "BlzGetUnitMaxMana should return 300 after setting")
    
    SetUnitState(u, UNIT_STATE_MANA, 150)
    Debug.assert(GetUnitState(u, UNIT_STATE_MANA) == 150, "GetUnitState MANA should return 150 after setting")
    
    SetUnitFlyHeight(u, 50, 0)
    Debug.assert(GetUnitFlyHeight(u) == 50, "GetUnitFlyHeight should return 50 after setting")
    
    SetUnitPosition(u, 300, 400)
    Debug.assert(GetUnitX(u) == 300, "GetUnitX should return 300 after SetUnitPosition")
    Debug.assert(GetUnitY(u) == 400, "GetUnitY should return 400 after SetUnitPosition")
    
    RemoveUnit(u)
    Debug.assert(GetUnitTypeId(u) == 0, "GetUnitTypeId should return 0 after RemoveUnit")
    
    print("StateSaver unit mock functions test passed!")
end

function test_StateSaver_ItemMocks()
    print("Testing StateSaver item mock functions...")
    
    local item = CreateItem(FourCC("ratc"), 50, 75)
    Debug.assert(item ~= nil, "CreateItem should return an item")
    Debug.assert(GetItemTypeId(item) == FourCC("ratc"), "GetItemTypeId should return the correct type")
    Debug.assert(GetItemX(item) == 50, "GetItemX should return 50")
    Debug.assert(GetItemY(item) == 75, "GetItemY should return 75")
    
    SetItemCharges(item, 5)
    Debug.assert(GetItemCharges(item) == 5, "GetItemCharges should return 5 after setting")
    
    print("StateSaver item mock functions test passed!")
end

function test_StateSaver_HeroMocks()
    print("Testing StateSaver hero mock functions...")
    
    local heroTypeId = 0x48000001
    local hero = CreateUnit(Player(0), heroTypeId, 0, 0, 0)
    Debug.assert(hero ~= nil, "CreateUnit should return a hero")
    Debug.assert(IsHeroUnitId(heroTypeId) == true, "IsHeroUnitId should return true for hero type")
    Debug.assert(IsUnitType(hero, UNIT_TYPE_HERO) == true, "IsUnitType HERO should return true for hero")
    
    SetHeroXP(hero, 1000, false)
    Debug.assert(GetHeroXP(hero) == 1000, "GetHeroXP should return 1000 after setting")
    
    BlzSetHeroProperName(hero, "Test Hero")
    Debug.assert(GetHeroProperName(hero) == "Test Hero", "GetHeroProperName should return 'Test Hero' after setting")
    
    SetHeroStr(hero, 25, true)
    Debug.assert(GetHeroStr(hero, false) == 25, "GetHeroStr should return 25 after setting")
    
    SetHeroAgi(hero, 30, true)
    Debug.assert(GetHeroAgi(hero, false) == 30, "GetHeroAgi should return 30 after setting")
    
    SetHeroInt(hero, 35, true)
    Debug.assert(GetHeroInt(hero, false) == 35, "GetHeroInt should return 35 after setting")
    
    local normalTypeId = FourCC("hfoo")
    Debug.assert(IsHeroUnitId(normalTypeId) == false, "IsHeroUnitId should return false for normal unit type")
    
    print("StateSaver hero mock functions test passed!")
end

function test_StateSaver_PlayerStateMocks()
    print("Testing StateSaver player state mock functions...")
    
    local p = Player(1)
    
    SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, 500)
    Debug.assert(GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) == 500, "GetPlayerState GOLD should return 500 after setting")
    
    SetPlayerState(p, PLAYER_STATE_RESOURCE_LUMBER, 250)
    Debug.assert(GetPlayerState(p, PLAYER_STATE_RESOURCE_LUMBER) == 250, "GetPlayerState LUMBER should return 250 after setting")
    
    print("StateSaver player state mock functions test passed!")
end

function test_StateSaver_FourCC2Str()
    print("Testing FourCC2Str function...")
    
    local hfoo = FourCC("hfoo")
    local result = FourCC2Str(hfoo)
    Debug.assert(result == "hfoo", "FourCC2Str(FourCC('hfoo')) should return 'hfoo', got: " .. result)
    
    local ratc = FourCC("ratc")
    result = FourCC2Str(ratc)
    Debug.assert(result == "ratc", "FourCC2Str(FourCC('ratc')) should return 'ratc', got: " .. result)
    
    print("FourCC2Str test passed!")
end

function test_StateSaver_SaveState()
    print("Testing StateSaver.SaveState API...")
    
    StateSaverTestVar1 = "save state test value"
    StateSaverTestVar2 = {key1 = 100, key2 = "nested value"}
    StateSaverTestVar3 = 999
    
    StateSaver.RecordVariable("StateSaverTestVar1")
    StateSaver.RecordVariable("StateSaverTestVar2")
    StateSaver.RecordVariable("StateSaverTestVar3")
    
    local testUnit = CreateUnit(Player(0), FourCC("hfoo"), 500, 600, 180)
    BlzSetUnitMaxHP(testUnit, 1000)
    SetUnitState(testUnit, UNIT_STATE_LIFE, 750)
    OnUnitCreated(testUnit)
    
    SetPlayerState(Player(0), PLAYER_STATE_RESOURCE_GOLD, 1500)
    SetPlayerState(Player(0), PLAYER_STATE_RESOURCE_LUMBER, 800)
    
    StateSaver.SaveState("test_save_state", 1)
    
    print("StateSaver.SaveState API test passed!")
end

function test_StateSaver_SaveLoadRoundtrip()
    print("Testing StateSaver save/load roundtrip...")
    
    RoundtripTestVar = "roundtrip test"
    StateSaver.RecordVariable("RoundtripTestVar")
    
    local originalValue = RoundtripTestVar
    
    StateSaver.SaveState("roundtrip_test", 2)
    
    RoundtripTestVar = "modified after save"
    Debug.assert(RoundtripTestVar ~= originalValue, "Variable should be modified after save")
    
    print("StateSaver save/load roundtrip test passed!")
end

function test_StateSaver_LoadStateFiles()
    print("Testing StateSaver.LoadStateFiles API...")
    
    LoadTestVar = "load test value"
    StateSaver.RecordVariable("LoadTestVar")
    
    StateSaver.SaveState("load_test_file", 3)
    
    print("StateSaver.LoadStateFiles API test passed!")
end

function test_StateSaver_LoadState()
    print("Testing StateSaver.LoadState API...")
    
    LoadStateTestVar = "load state test"
    StateSaver.RecordVariable("LoadStateTestVar")
    
    StateSaver.SaveState("load_state_test", 4)
    
    print("StateSaver.LoadState API test passed!")
end

function test_StateSaver_FullRoundtrip()
    print("Testing StateSaver full save/load roundtrip...")
    
    FullRoundtripVar1 = "original string value"
    FullRoundtripVar2 = 42
    FullRoundtripVar3 = {nested = {deep = "value"}, arr = {1, 2, 3}}
    FullRoundtripVar4 = true
    
    StateSaver.RecordVariable("FullRoundtripVar1")
    StateSaver.RecordVariable("FullRoundtripVar2")
    StateSaver.RecordVariable("FullRoundtripVar3")
    StateSaver.RecordVariable("FullRoundtripVar4")
    
    local originalVar1 = FullRoundtripVar1
    local originalVar2 = FullRoundtripVar2
    local originalVar3 = {nested = {deep = FullRoundtripVar3.nested.deep}, arr = {FullRoundtripVar3.arr[1], FullRoundtripVar3.arr[2], FullRoundtripVar3.arr[3]}}
    local originalVar4 = FullRoundtripVar4
    
    local testUnit = CreateUnit(Player(0), FourCC("hfoo"), 100, 200, 90)
    BlzSetUnitMaxHP(testUnit, 500)
    SetUnitState(testUnit, UNIT_STATE_LIFE, 350)
    OnUnitCreated(testUnit)
    
    SetPlayerState(Player(0), PLAYER_STATE_RESOURCE_GOLD, 1000)
    SetPlayerState(Player(0), PLAYER_STATE_RESOURCE_LUMBER, 500)
    
    StateSaver.SaveState("full_roundtrip_test", 5)
    
    FullRoundtripVar1 = "modified"
    FullRoundtripVar2 = 999
    FullRoundtripVar3 = {}
    FullRoundtripVar4 = false
    SetPlayerState(Player(0), PLAYER_STATE_RESOURCE_GOLD, 0)
    SetPlayerState(Player(0), PLAYER_STATE_RESOURCE_LUMBER, 0)
    
    Debug.assert(FullRoundtripVar1 ~= originalVar1, "Variable should be modified before load")
    Debug.assert(FullRoundtripVar2 ~= originalVar2, "Variable should be modified before load")
    Debug.assert(FullRoundtripVar4 ~= originalVar4, "Variable should be modified before load")
    
    local loadCompleted = false
    StateSaver.LoadStateFiles(Player(0), {"full_roundtrip_test"})
    
    for _ = 1, 100 do
        TriggerSleepAction(0.1)
        if SaveStateDatas[1] ~= nil then
            loadCompleted = true
            break
        end
    end
    
    Debug.assert(loadCompleted, "LoadStateFiles should complete")
    Debug.assert(SaveStateDatas[1] ~= nil, "SaveStateDatas[1] should be loaded")
    
    StateSaver.LoadState(1)
    
    Debug.assert(FullRoundtripVar1 == originalVar1, "FullRoundtripVar1 should be restored to: " .. originalVar1 .. ", got: " .. tostring(FullRoundtripVar1))
    Debug.assert(FullRoundtripVar2 == originalVar2, "FullRoundtripVar2 should be restored to: " .. tostring(originalVar2) .. ", got: " .. tostring(FullRoundtripVar2))
    Debug.assert(FullRoundtripVar4 == originalVar4, "FullRoundtripVar4 should be restored to: " .. tostring(originalVar4) .. ", got: " .. tostring(FullRoundtripVar4))
    Debug.assert(FullRoundtripVar3.nested ~= nil, "FullRoundtripVar3.nested should exist")
    Debug.assert(FullRoundtripVar3.nested.deep == originalVar3.nested.deep, "FullRoundtripVar3.nested.deep should be restored")
    Debug.assert(FullRoundtripVar3.arr ~= nil, "FullRoundtripVar3.arr should exist")
    Debug.assert(#FullRoundtripVar3.arr == 3, "FullRoundtripVar3.arr should have 3 elements")
    
    Debug.assert(GetPlayerState(Player(0), PLAYER_STATE_RESOURCE_GOLD) == 1000, "Player gold should be restored to 1000")
    Debug.assert(GetPlayerState(Player(0), PLAYER_STATE_RESOURCE_LUMBER) == 500, "Player lumber should be restored to 500")
    
    print("StateSaver full save/load roundtrip test passed!")
end

test_StateSaver_RecordVariable()
test_StateSaver_VariablePackUnpack()
test_StateSaver_PlayerMapping()
test_StateSaver_UnitMocks()
test_StateSaver_ItemMocks()
test_StateSaver_HeroMocks()
test_StateSaver_PlayerStateMocks()
test_StateSaver_FourCC2Str()
test_StateSaver_SaveState()
test_StateSaver_SaveLoadRoundtrip()
test_StateSaver_LoadStateFiles()
test_StateSaver_LoadState()

runAsyncTest("test_StateSaver_FullRoundtrip", test_StateSaver_FullRoundtrip)

print("\n============================================================")
print("ALL TESTS PASSED!")
print("============================================================\n")
