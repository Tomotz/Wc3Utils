if Debug then Debug.beginFile("StateSaver") end
--- This system is based on MagiLogNLoad and some of the code is taken from it directly
--- https://www.hiveworkshop.com/threads/magi-log-n-load-the-ultimate-save-load-system.357602/

do

--- Configurations ---
local IS_DEBUG = false -- enable debug prints

---@type string[] -- list of variable names to record in the state. Variables can also be added at any time using StateSaver.RecordVariable
local varsToSave = {}

---@type table<integer, boolean> -- table<itemId, true> itemsIds that should be ignored and not saved
local filterItems = {}

---@type table<integer, boolean> -- table<unitId, true>  unitIds that should be ignored and not saved
local filterUnits = {}

---@type table<integer, boolean> -- table<abilityId, true> abilityIds that should be ignored and not saved. Global so we can access them in StateTracker
filterSkills = {}

local SAVE_FOLDER_PATH = 'Savegames\\TestMap\\SavedState\\'  -- needs to end with \\

MaxHumanPlayers = bj_MAX_PLAYER_SLOTS -- the last slot id that might belongs to a human player
--- End Configurations ---

StateSaver = {}

local unitUniqueId = 1
UnitToUniqueId = {} ---@type table<unit, integer>
UniqueIdToUnit = {} ---@type table<integer, unit>

local itemUniqueId = 1
ItemToUniqueId = {} ---@type table<item, integer>
UniqueIdToItem = {} ---@type table<integer, item>

---@class ResearchData
---@field id integer
---@field level integer

---@class PlayerDumpData
---@field id integer
---@field gold integer
---@field lumber integer
---@field research ResearchData[]

---@class ItemDumpData
---@field iid integer -- wc3 id of the item
---@field uniqueId integer -- unique id for the item
---@field charges integer
---@field slot integer? -- the slot of the item in the unit inventory. nil for items on the ground
---@field x integer? -- location of the item. nil for items in unit inventory
---@field y integer?

---@class UnitSkill
---@field id integer
---@field cd real
---@field level integer

---@class UnitDumpData
---@field uid integer -- wc3 id of the unit
---@field uniqueId integer -- unique id for the unit
---@field owner integer -- owning player id
---@field x integer
---@field y integer
---@field face integer
---@field flyHeight integer?
---@field items ItemDumpData[]
---@field heroProperName string?
---@field heroXP integer?
---@field maxHP integer?
---@field curHP integer?
---@field maxMana integer?
---@field curMana integer?
---@field baseDamage integer?
---@field strength integer?
---@field agility integer?
---@field intelligence integer?
---@field killTime real? -- if the unit has timed life, the amount of time left until it expires.
---@field buffId integer? -- the buff id of the timed life buff.
---@field heroSkills UnitSkill[]? -- all the hero heroSkills
---@field skills UnitSkill[]? -- all the normal skills. We save those seperately so that if a hero skill triggers a normal skill level up, we don't level it up twice
---@field hookedFuncs HookFunc[]? -- list of important functions that were used on the unit, and should be used again when loading state

---@class SaveStateData
---@field OldToNewPid table<integer, integer>? -- a mapping from the saved player indices to the current indices.
---@field playerNames string[]? -- the names of the players in the game
---@field saveId integer? -- unique id for the state
---@field variables string? -- a packed version of a table<string, any> with the variable names as keys and their values as values
---@field units UnitDumpData[]? -- a list of all the units in the game,
---@field items ItemDumpData[]? -- a list of all the items on the ground
---@field players PlayerDumpData[]? -- a list of all the players in the game

SaveStateDatas = {} ---@type SaveStateData[]
local fileLoading = 0 ---@type integer -- the current index of the file being loaded

local curPlayerNames = {} ---@type string[]

local playersData = {} ---@type PlayerDumpData[] -- note that index 1 in the array is for player 0

ABILITY_ID_CROW_FORM = FourCC('Amrf')

if TimerQueue == nil then
    TimerQueue = {}
    function TimerQueue:callDelayed(delay, func)
        local t = CreateTimer()
        TimerStart(t, delay, false, function()
            func()
            DestroyTimer(t)
        end)
    end
end

--- Ideas for things we don't save (mostly from MagiLogNLoad)
--- Destructables, Doodads (killed trees), Fog of war, short lived stuff (smoke, ground flares), ability CD, Groups, wc3 Hashtables
--- function wrappers - CreateDestructable, RemoveDestructable, KillDestructable, DestructableRestoreLife, ModifyGateBJ, SetDestructableInvulnerable, SetBlightRect, SetBlightPoint, SetBlight, SetBlightLoc

------------------------------- Helper functions -------------------------------

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

local function addFileExtension(StateFileName)
    StateFileName = SAVE_FOLDER_PATH .. StateFileName
    if StateFileName:sub(-4,-1) ~= '.pld' then
        StateFileName = StateFileName .. '.pld'
    end
    return StateFileName
end

------------------------------- Triggers to save data needed for state -------------------------------

---@param hook table? -- the hook to call after saving the research
---@param p player
---@param researchId integer
---@param level integer
function TechHook(hook, p, researchId, level)
    if researchId == 0 then return end
    local pid = GetPlayerId(p)
    table.insert(playersData[pid + 1].research, {id = researchId, level = level})
    if hook then hook.next(p, researchId, level) end
end

function SaveStateTriggers()
    for pid = 0, bj_MAX_PLAYER_SLOTS - 1 do
        table.insert(playersData, {
            id = pid,
            gold = 0,
            lumber = 0,
            research = {}
        })
    end
    local t = CreateTrigger()
    TriggerRegisterAnyUnitEventBJ(t, EVENT_PLAYER_UNIT_RESEARCH_FINISH)
    TriggerAddAction(t, (function()
        TechHook(nil, GetOwningPlayer(GetResearchingUnit()), GetResearched(), 1)
    end))
    Hook.add("AddPlayerTechResearched", TechHook)
    Hook.add("SetPlayerTechResearched", TechHook)
end

OnInit.trig(SaveStateTriggers)

------------------------------- Functions for loading -------------------------------

---@param stateData SaveStateData
---@return table<integer, integer>? -- Mapping between old player ids and the new one
local function GetPlayerMap(stateData)
    if stateData.playerNames == nil then
        debugPrint(false, "no player names found in state")
        return nil
    end
    -- Validate that all current players appear in the log
    for i = 0, MaxHumanPlayers - 1 do
        local name = curPlayerNames[i + 1]
        if name ~= "" and name ~= nil and ArrayFind(stateData.playerNames, name) == nil then
            debugPrint(false, 'Player name -', name, 'is not in the save file')
            return nil
        end
    end

    local unusedIndices = {}
    local nameToPlayerNamesIdx = {}
    local ret = {}

    for i = 1, MaxHumanPlayers do
        if stateData.playerNames[i] == nil or stateData.playerNames[i] == "" or ArrayFind(curPlayerNames, stateData.playerNames[i]) == nil then
            -- if player didn't exist in the saved state, or it existed but that player isn't playing now, we will set it as unused
            table.insert(unusedIndices, i)
        else
            nameToPlayerNamesIdx[stateData.playerNames[i]] = i
        end
    end
    local unusedPtr = 1
    for i = 0, MaxHumanPlayers - 1 do
        -- note that curPlayerNames is one based and PlayersArr is zero based
        local name = curPlayerNames[i + 1]
        local oldPlayerId = 0
        if name == nil or name == "" then
            oldPlayerId = unusedIndices[unusedPtr] - 1
            ret[oldPlayerId] = i
            unusedPtr = unusedPtr + 1
        else
            oldPlayerId = nameToPlayerNamesIdx[name] - 1
            ret[oldPlayerId] = i
        end
    end
    for i = MaxHumanPlayers, bj_MAX_PLAYER_SLOTS - 1 do
        ret[i] = i
    end
    debugPrint(false, "GetPlayerMap done", ret)
    return ret
end

--- gets the current player id from the saved player id
---@param savedPid integer
---@return player
local function PlayerMapped(savedPid)
    local map = SaveStateDatas[fileLoading].OldToNewPid
    if map ~= nil then
        return Player(map[savedPid])
    end
    return Player(savedPid)
end

---@param tbl string[]
--- Fills the table with all the player names. Note that the index in the table is the player index + 1
local function populatePlayerNames(tbl)
    for i = 0, bj_MAX_PLAYER_SLOTS - 1 do
        local name = GetPlayerName(Player(i)) or ""
        if name:match("^Player \x25d+$") then
            name = ""
        end
        table.insert(tbl, name)
    end
end

function populatePlayerIdxMap()
    debugPrint(false, "Creating player index map. ", os.clock())
    populatePlayerNames(curPlayerNames)

    for i = 1, 4 do
        local stateData = SaveStateDatas[i]
        if stateData ~= nil then
            local playerMap = GetPlayerMap(stateData)
            stateData.OldToNewPid = playerMap
            if playerMap ~= nil then
                debugPrint(false, "populatePlayerIdxMap", i, playerMap)
            else
                debugPrint(false, "populatePlayerIdxMap", i, "No mapping found")
            end
        end
    end
end

---@param u unit
---@param flyHeight integer
local function loadUnitFlyHeight(u, flyHeight)
    if BlzGetUnitMovementType(u) ~= 2 and GetUnitAbilityLevel(u, ABILITY_ID_CROW_FORM) <= 0 then
        UnitAddAbility(u, ABILITY_ID_CROW_FORM)
        UnitRemoveAbility(u, ABILITY_ID_CROW_FORM)
    end

    local isBuilding = BlzGetUnitBooleanField(u, UNIT_BF_IS_A_BUILDING)
    if isBuilding then
        BlzSetUnitBooleanField(u, UNIT_BF_IS_A_BUILDING, false)
    end

    SetUnitFlyHeight(u, flyHeight, 0)
    SetUnitPosition(u, GetUnitX(u), GetUnitY(u))

    if isBuilding then
        BlzSetUnitBooleanField(u, UNIT_BF_IS_A_BUILDING, true)
    end
end

---@param u unit
---@param itemData ItemDumpData
---@param unitId integer
local function loadUnitItem(u, itemData, unitId)
    if not UnitAddItemToSlotById(u, itemData.iid, itemData.slot) then
        debugPrint(true, 'Error!  0 Failed to add item:', itemData.iid, 'to unit:', u)
        return
    end

    local item = UnitItemInSlot(u, itemData.slot)
    if item == nil then
        debugPrint(true, 'Error! 1 Failed to add item:', itemData.iid, 'to unit:', u)
        return
    end

    debugPrint(false, "loading unit item. iid:", itemData.iid, ", uniqueId:", itemData.uniqueId, "saved with:", itemUniqueId, ", item:", item)
    UniqueIdToItem[itemData.uniqueId] = item
    ItemToUniqueId[item] = itemData.uniqueId

    if GetItemCharges(item) ~= itemData.charges then
        SetItemCharges(item, itemData.charges)
    end
end

---@param unitData UnitDumpData
local function loadUnit(unitData)
    local p = PlayerMapped(unitData.owner)
    local u = CreateUnit(p, unitData.uid, unitData.x, unitData.y, unitData.face)
    if not u then
        debugPrint(true, 'Error! Failed to create unit with id:', unitData.uid)
        return nil
    end
    UniqueIdToUnit[unitData.uniqueId] = u
    UnitToUniqueId[u] = unitData.uniqueId
    debugPrint(false, "loading unit. uid:", unitData.uid, ", uniqueId:", unitData.uniqueId, ", unit:", u)

    if unitData.killTime then
        UnitApplyTimedLife(u, unitData.buffId, unitData.killTime)
    end

    if unitData.flyHeight and unitData.flyHeight ~= 0 then
        loadUnitFlyHeight(u, unitData.flyHeight)
    end

    for _, itemData in ipairs(unitData.items) do
        loadUnitItem(u, itemData, unitData.uid)
    end

    if unitData.heroProperName then
        BlzSetHeroProperName(u, unitData.heroProperName)
		if GetPlayerId(GetOwningPlayer(u)) < MaxHumanPlayers then
			-- give player heroes short lived invulnerability
			SetUnitInvulnerable(u, true)
			TimerQueue:callDelayed(10, function()
				SetUnitInvulnerable(u, false)
			end)
		end
    end

    if unitData.heroXP then
        SetHeroXP(u, unitData.heroXP, false)
    end
end

---@param unitData UnitDumpData
local function LoadUnitState(unitData)
    local u = UniqueIdToUnit[unitData.uniqueId]
    if u == nil then return end
    if unitData.heroSkills then
        for _, skill in ipairs(unitData.heroSkills) do

            for _ = 1, skill.level do
                SelectHeroSkill(u, skill.id)
            end
            if skill.cd > 0 then
                BlzStartUnitAbilityCooldown(u, skill.id, skill.cd)
            end
        end
    end
    if unitData.skills then
        for _, skill in ipairs(unitData.skills) do

            local curLvl = GetUnitAbilityLevel(u, skill.id)
            if curLvl == 0 then
                UnitAddAbility(u, skill.id)
                curLvl = 1
            end
            for _ = curLvl + 1, skill.level do
                IncUnitAbilityLevel(u, skill.id)
            end
            if skill.cd > 0 then
                BlzStartUnitAbilityCooldown(u, skill.id, skill.cd)
            end
        end
    end
    if unitData.hookedFuncs then
        for _, hookFunc in ipairs(unitData.hookedFuncs) do
            if _G[hookFunc.name] then
                _G[hookFunc.name](u, table.unpack(hookFunc.args))
            end
        end
    end
    if unitData.strength then
        SetHeroStr(u, unitData.strength, true)
    end
    if unitData.agility then
        SetHeroAgi(u, unitData.agility, true)
    end
    if unitData.intelligence then
        SetHeroInt(u, unitData.intelligence, true)
    end
    if BlzGetUnitMaxHP(u) ~= unitData.maxHP then
    	BlzSetUnitMaxHP(u, unitData.maxHP)
    end

    SetUnitState(u, UNIT_STATE_LIFE, unitData.curHP)

    if unitData.maxMana > 0 then
        if BlzGetUnitMaxMana(u) ~= unitData.maxMana then
        	BlzSetUnitMaxMana(u, unitData.maxMana)
        end

        SetUnitState(u, UNIT_STATE_MANA, unitData.curMana)
    end

    if BlzGetUnitBaseDamage(u, 0) ~= unitData.baseDamage then
    	BlzSetUnitBaseDamage(u, unitData.baseDamage, 0)
    end
end

---@param packedUnitTable UnitDumpData[] -- the packed table returned from packUnits
local function LoadUnits(packedUnitTable)
    if packedUnitTable == nil then
        debugPrint(true, 'Error, Failed to load units')
        return
    end
    debugPrint(false, "LoadUnits. ", os.clock(), packedUnitTable)
    for _, unitData in ipairs(packedUnitTable) do
        loadUnit(unitData)
    end
end

---@param packedUnitTable UnitDumpData[] -- the packed table returned from packUnits
local function LoadUnitStates(packedUnitTable)
    for _, unitData in ipairs(packedUnitTable) do
        LoadUnitState(unitData)
    end
end

---@param itemData ItemDumpData
local function loadItem(itemData)
    local item = CreateItem(itemData.iid, itemData.x, itemData.y)

    if not item then
        debugPrint(true, 'ERROR:LoadCreateItem!', 'Failed to create item with id:',FourCC2Str(itemData.iid),'!')
        return nil
    end

    if GetItemCharges(item) ~= itemData.charges then
        SetItemCharges(item, itemData.charges)
    end

    debugPrint(false, "loading item. iid:", itemData.iid, ", uniqueId:", itemData.uniqueId, "saved with:", itemUniqueId, ", item:", item)
    UniqueIdToItem[itemData.uniqueId] = item
    ItemToUniqueId[item] = itemData.uniqueId
end

---@param packedItemTable ItemDumpData[] -- the packed table returned from packItems
local function LoadItems(packedItemTable)
    if packedItemTable == nil then
        debugPrint(true, 'Error, Failed to load items')
        return
    end
    debugPrint(false, "LoadItems. ", os.clock(), packedItemTable)
    for _, itemData in ipairs(packedItemTable) do
        loadItem(itemData)
    end
end

---@param playersData PlayerDumpData[]
local function loadPlayers(playersData)
    for _, data in ipairs(playersData) do
        local p = PlayerMapped(data.id)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, data.gold)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_LUMBER, data.lumber)
        for _, research in ipairs(data.research) do
            SetPlayerTechResearched(p, research.id, research.level)
        end
    end

end

---@param packedVariableTable string -- the packed table returned from packVariables
local function LoadVariables(packedVariableTable)
    local var = Serializer.loadVariable(packedVariableTable)
    for name, value in pairs(var) do
        if type(_G[name]) == "table" and GetClass(_G[name]) == SyncedTable then
            _G[name] = SyncedTable.FromIndexedTables(value)
        else
            _G[name] = value
        end
    end
end

------------------------------- Functions for packing/saving -------------------------------

---@param u unit
---@param skipSummonedCheck boolean -- if true, will not skip summoned units. That's needed due to wc adding the summoned flag when applying timed life
---@return boolean
local function IsUnitSaveable(u, skipSummonedCheck)
    if GetUnitTypeId(u) == 0 then return false end
    if IsUnitType(u, UNIT_TYPE_HERO) == true and GetPlayerId(GetOwningPlayer(u)) < MaxHumanPlayers then
        return true -- save human player heroes even if they are dead
    end
    if IsUnitType(u, UNIT_TYPE_DEAD) then return false end
    if not skipSummonedCheck and IsUnitType(u, UNIT_TYPE_SUMMONED) then return false end
    return true
end

---@param unitIterData UnitIndexerData
---@return UnitDumpData?
local function packUnit(unitIterData)
    local u = unitIterData.u
    if not IsUnitSaveable(u, unitIterData.expireTime ~= nil) then return nil end

    local uid = GetUnitTypeId(u)
    if filterUnits[uid] then
        -- debugPrint(false, "skipping filter unit ", uid)
        return nil
    end
    debugPrint(false, "packing unit. uid:", uid, ", uniqueId:", unitUniqueId, ", unit:", u)
    ---@type UnitDumpData
    local data = {
        uid = uid,
        uniqueId = unitUniqueId,
        owner = unitIterData.ownerId,
        x = Round(GetUnitX(u)),
        y = Round(GetUnitY(u)),
        face = Round(GetUnitFacing(u)),
        items = {},
        killTime = unitIterData.expireTime and unitIterData.expireTime - GetElapsedGameTime() or nil,
        buffId = unitIterData.buffId,
        hookedFuncs = unitIterData.hookedFuncs,

        -- Note that these properties must be loaded after loading XP and stats
        maxHP = BlzGetUnitMaxHP(u),
        curHP = math.floor(GetWidgetLife(u)),
        maxMana = BlzGetUnitMaxMana(u),
        curMana = math.floor(GetUnitState(u, UNIT_STATE_MANA)),
        baseDamage = BlzGetUnitBaseDamage(u, 0),
    }
    if unitIterData.hookedAbilityFuncs then
        data.hookedFuncs = data.hookedFuncs or {}
        for _, hookFuncs in pairs(unitIterData.hookedAbilityFuncs) do
            for _, hookFunc in ipairs(hookFuncs) do
                table.insert(data.hookedFuncs, hookFunc)
            end
        end
    end
    local flyHeight = Round(GetUnitFlyHeight(u))
    if flyHeight ~= 0 then data.flyHeight = flyHeight end

    UnitToUniqueId[u] = data.uniqueId
    UniqueIdToUnit[data.uniqueId] = u
    unitUniqueId = unitUniqueId + 1

    local invSize = UnitInventorySize(u)
    if invSize > 0 then
        for i = 0, invSize - 1 do
            local item = UnitItemInSlot(u, i)
            if not item then
                goto continue
            end
            local itemId = GetItemTypeId(item)
            if filterItems[itemId] then
                goto continue
            end
            if UniqueIdToItem[itemUniqueId] ~= nil then
                goto continue
            end

            table.insert(data.items, {
                iid = itemId,
                uniqueId = itemUniqueId,
                charges = GetItemCharges(item),
                slot = i
            })

            ItemToUniqueId[item] = itemUniqueId
            UniqueIdToItem[itemUniqueId] = item
            itemUniqueId = itemUniqueId + 1
            ::continue::
        end
    end

    if IsHeroUnitId(uid) then
        local str = GetHeroProperName(u)
        if str and str ~= '' then
            data.heroProperName = str
        end

        data.heroXP = GetHeroXP(u)

        data.heroSkills = {}
        data.skills = {}
        for i = 0, 255 do
            local abil = BlzGetUnitAbilityByIndex(u, i)
            if not abil then break end

            local abilid = BlzGetAbilityId(abil)
            if not filterSkills[abilid] then
                local cd = BlzGetUnitAbilityCooldownRemaining(u, abilid)
                local skill = {
                    id = abilid,
                    cd = cd,
                    level = GetUnitAbilityLevel(u, abilid)
                }
                if unitIterData.learnedSkills ~= nil and unitIterData.learnedSkills[skill.id] ~= nil then
                    table.insert(data.heroSkills, skill)
                else
                    table.insert(data.skills, skill)
                end
            end
        end

        data.strength = GetHeroStr(u, false)
        data.agility = GetHeroAgi(u, false)
        data.intelligence = GetHeroInt(u, false)
    end
    return data
end

---@return UnitDumpData[]
local function packUnits()
    debugPrint(false, "packing units ", os.clock())
    local out = {}
    IterFilterUnits(function(unitIterData)
        local unitData = packUnit(unitIterData)
        if unitData then
            table.insert(out, unitData)
        end
    end)
    return out
end

local function EnumLogItemOnGround()
    local item = GetEnumItem()
    local iid = GetItemTypeId(item)
    if not item or iid == 0 or GetWidgetLife(item) <= 0.405 then return false end
    if ItemToUniqueId[item] ~= nil then return false end -- item already logged
    ---@type ItemDumpData
    local itemData = {
        iid = iid,
        uniqueId = itemUniqueId,
        charges = GetItemCharges(item),
        x = Round(GetItemX(item)),
        y = Round(GetItemY(item))
    }

    ItemToUniqueId[item] = itemData.uniqueId
    UniqueIdToItem[itemData.uniqueId] = item
    itemUniqueId = itemUniqueId + 1

    table.insert(AllItems, itemData)
    return true
end

---@return ItemDumpData[]
local function packItems()
    debugPrint(false, "packing items ", os.clock())
    UniqueIdToItem = {}
    ItemToUniqueId = {}
    AllItems = {} ---@type ItemDumpData[]
    EnumItemsInRect(bj_mapInitialPlayableArea, nil, EnumLogItemOnGround)
    return AllItems
end

---@return PlayerDumpData[]
local function packPlayers()
    for pid = 0, bj_MAX_PLAYER_SLOTS - 1 do
        playersData[pid + 1].gold = GetPlayerState(Player(pid), PLAYER_STATE_RESOURCE_GOLD)
        playersData[pid + 1].lumber = GetPlayerState(Player(pid), PLAYER_STATE_RESOURCE_LUMBER)
        -- research already handled
    end
    return playersData
end

---@packs the current state of all the requested variables to a single table.
---@return string? -- a packed version of a table with the variable names as keys and their values as values
local function packVariables()
    debugPrint(false, "packing variables ", os.clock())
    local SavedVars = {}
    for _, value in ipairs(varsToSave) do
        if type(_G[value]) == "table" and GetClass(_G[value]) == SyncedTable then
            SavedVars[value] = SyncedTable.ToIndexedTables(_G[value])
        else
            SavedVars[value] = _G[value]
        end
    end
    -- pack it so the load of the variables will only happen after we finished loading all the units and items and fill their unique ids
    return Serializer.dumpVariable(SavedVars)
end

--- updates the values of some saving related global variables before saving them
local function updateGlobalVariables()
    itemUniqueId = 1
    ItemToUniqueId = {}
    UniqueIdToItem = {}

    unitUniqueId = 1
    UniqueIdToUnit = {}
    UnitToUniqueId = {}
end

------------------------------- API functions -------------------------------

--- Loads the state from the file at index fileIdx.
--- Note - LoadStateFiles must be called before each invocation of this function.
---@param fileIdx integer -- the index of the file to load in the state array.
---@param callback function? -- a function to call after loading everything besides hero skills and stats (this allows running things that might change those stats)
function StateSaver.LoadState(fileIdx, callback)
    fileLoading = fileIdx
    if SaveStateDatas[fileIdx] == nil then
        debugPrint(true, "Error! Requested file not loaded")
    end
    local state = SaveStateDatas[fileIdx]
    LoadUnits(state.units)
    debugPrint(false, "loaded units. ", os.clock())
    LoadItems(state.items)
    debugPrint(false, "loaded items. ", os.clock())
    LoadVariables(state.variables) -- must be unpacked after units and items so the mapping is correct
    debugPrint(false, "loaded variables. ", os.clock())
    loadPlayers(state.players)
    debugPrint(false, "loaded players. ", os.clock())
    if callback then callback() end
    debugPrint(false, "ran user callback. ", os.clock())
    LoadUnitStates(state.units)
    debugPrint(false, "loaded unit states. ", os.clock())
end

--- Loads a list of state files without unpacking them. A blocking function that can take a short while
--- Note - Must be called from a context where you can run TriggerSleepAction.
---@param whichPlayer player -- the player that requested the load
---@param StateFileNames string[] -- the name of the files to load the state from
function StateSaver.LoadStateFiles(whichPlayer, StateFileNames)
    debugPrint(false, "StateSaver.LoadState started ", os.clock())
    SaveStateDatas = {}
    local fixedNames = {}
    for _, StateFileName in ipairs(StateFileNames) do
        StateFileName = addFileExtension(StateFileName)
        table.insert(fixedNames, StateFileName)
    end
    Serializer.loadFile(whichPlayer, fixedNames, function(loadedTables)
        SaveStateDatas = loadedTables
        for i, stateData in ipairs(SaveStateDatas) do
            if stateData == "" then
                SaveStateDatas[i] = nil
            end
        end
        if next(SaveStateDatas) == nil then
            debugPrint(true, "No state data loaded.")
            SaveStateDatas[0] = "error" -- put something to free up the loop testing the states. Index 0 will not be checked
        end
        populatePlayerIdxMap()
        debugPrint(false, "stateSyncedCB state sync done.", os.clock())
    end, LibDeflate.DecompressDeflate, true)
end

---@param argName string
function StateSaver.RecordVariable(argName)
    table.insert(varsToSave, argName)
end

---@param StateFileName string -- the name of the file to save the state to
---@param stateId integer? -- a unique id for the state
function StateSaver.SaveState(StateFileName, stateId)
    debugPrint(false, "StateSaver.SaveState. ", os.clock())
    StateFileName = addFileExtension(StateFileName)
    updateGlobalVariables()
    local playerNames = {} ---@type string[]
    populatePlayerNames(playerNames)
    ---@type SaveStateData
    local stateData = {playerNames = playerNames, saveId = stateId, units = packUnits(), items = packItems(), players = packPlayers()}
    stateData.variables = packVariables() -- must be packed after units and items so the mapping is correct
    debugPrint(false, "about to save file", os.clock())
    Serializer.saveFile(GetLocalPlayer(), stateData, StateFileName, LibDeflate.CompressDeflate)
    debugPrint(false, "Serializer.saveFile done. ", os.clock())
end

OnInit.map(function()
end)
end
if Debug then Debug.endFile() end
