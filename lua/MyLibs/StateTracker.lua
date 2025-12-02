if Debug then Debug.beginFile("StateTracker") end

--- Helper for StateSaver.lua - tracks game changes

---@class HookFunc
---@field name string -- name of the hooked function
---@field args any[] -- list of arguments that were used when calling the function without the unit id

-- -- Unit Indexer
---@class UnitIndexerData
---@field u unit
---@field uniqueId integer -- a monotonic index for the unit out of all units ever created
---@field ownerId integer -- the player id of the unit owner
---@field expireTime real? -- if the unit has timed life, the game time when it will expire. Needed for saving state data
---@field buffId integer? -- the buff id of the timed life buff. Needed for saving state data
---@field learnedSkills table<integer, boolean>? -- table with all the ability ids the hero learned. Value is always true
---@field hookedFuncs HookFunc[]? -- list of important functions that were used on the unit, and should be used again when loading state
---@field hookedAbilityFuncs SyncedTable<integer, HookFunc[]>? -- For each ability id, list of functions that were used on it

AllUnitIds = SyncedTable.create() ---@type table<unit, UnitIndexerData>
local allUnitCount = 0
-- saves the amount of units ever created of each type
local unitCounts = {} ---@type table<integer, integer>

--- Iterates all units and runs a function on them. Removes and any unit that was already removed from the game from AllUnitIds
---@param func fun(data:UnitIndexerData)
function IterFilterUnits(func)
    local filteredIds = SyncedTable.create()
    for unit, data in pairs(AllUnitIds) do
        if GetUnitTypeId(unit) ~= 0 then
            func(data)
            filteredIds[unit] = data
        end
    end
    AllUnitIds = filteredIds
end

---@param u unit
---@return boolean
function OnUnitCreated(u)
    local typeId = GetUnitTypeId(u)
    if typeId == 0 then return false end
    if AllUnitIds[u] ~= nil then
        return false
    end
    allUnitCount = allUnitCount + 1
    if unitCounts[typeId] == nil then
        unitCounts[typeId] = 1
    else
        unitCounts[typeId] = unitCounts[typeId] + 1
    end
    AllUnitIds[u] = {u = u, uniqueId = allUnitCount, ownerId = GetPlayerId(GetOwningPlayer(u))}
    return true
end

OnInit.trig(function()
    -- -- enum initial units
    -- local cond = Condition(function() return OnUnitCreated(GetEnumUnit()) end)
    -- GroupEnumUnitsInRect(udg_g, bj_mapInitialPlayableArea, cond)
    -- GroupClear(udg_g)
    -- DestroyCondition(cond)
    -- Unit created
    local t = CreateTrigger()
    TriggerRegisterEnterRectSimple(t, bj_mapInitialPlayableArea)
    TriggerAddCondition(t, Condition(function() return OnUnitCreated(GetTriggerUnit()) end))
    -- Unit leaves
    t = CreateTrigger()
    TriggerRegisterLeaveRectSimple(t, bj_mapInitialPlayableArea)
    TriggerAddAction(t, function()
        local u = GetTriggerUnit()
        RemoveUnit(u)
    end)
end)

--- Important functions that are used on a unit and we would like to reapply when loading state. Note that all those functions must get the unit as first argument.
--- Those functions are saved in the state, so we can't use actuall functions, and must just pass their names
local hookedUnitFuncs = {'SetUnitVertexColor', 'SetUnitTimeScale', 'SetUnitScale', 'SetUnitAnimation', 'SetUnitAnimationByIndex', 'SetUnitAnimationWithRarity', 'BlzSetUnitArmor', 'BlzSetUnitName', 'SetUnitMoveSpeed', 'BlzSetUnitSkin'}
    --'SetUnitColor' - removed since it's using playercolor which can't be saved in state file

--- We need to handle ability functions differently - we don't want to apply abilities that were later removed.
local hookedAbilityFuncs = {'UnitAddAbility', 'UnitMakeAbilityPermanent', 'SetUnitAbilityLevel', 'UnitRemoveAbility'}

local function addUnitFuncHook(funcName)
    Hook.add(funcName, function(hook, whichUnit, ...)
        hook.next(whichUnit, ...)
        if AllUnitIds[whichUnit] == nil then
            OnUnitCreated(whichUnit)
        end
        local data = AllUnitIds[whichUnit]
        if data == nil then
            LogWriteNoFlush("Error: no data for unit in hooked function", funcName, "unit:", FourCC2Str(GetUnitTypeId(whichUnit)), "trace:", Debug.traceback())
            return
        end
        if ArrayFind(hookedAbilityFuncs, funcName) then
            --- UnitMakeAbilityPermanent gets the arg in a different position
            local abilityIndex = funcName == "UnitMakeAbilityPermanent" and 2 or 1
            local abilityId = select(abilityIndex, ...)
            if filterSkills[abilityId] == true then
                return
            end
            if data.hookedAbilityFuncs == nil then data.hookedAbilityFuncs = SyncedTable.create() end
            if funcName == "UnitRemoveAbility" or data.hookedAbilityFuncs[abilityId] == nil then
                --- Ability was removed, so no need to track all the previous changes to the ability
                data.hookedAbilityFuncs[abilityId] = {}
            end
            table.insert(data.hookedAbilityFuncs[abilityId], {name = funcName, args = {...}})
        else
            if data.hookedFuncs == nil then data.hookedFuncs = {} end
            table.insert(data.hookedFuncs, {name = funcName, args = {...}})
        end
    end)
end

OnInit.global(function()
    -- Track important changes in the unit indexer
    for _, funcName in ipairs(hookedUnitFuncs) do
        addUnitFuncHook(funcName)
    end
    for _, funcName in ipairs(hookedAbilityFuncs) do
        addUnitFuncHook(funcName)
    end
    --update unit owner when needed
    Hook.add("SetUnitOwner", function(hook, u, newOwnerId, changeColor)
        -- I need the owner id to be up to date during the game (for non state related logic), so this is getting a special hook
        if AllUnitIds[u] == nil then
            OnUnitCreated(u)
        end
        AllUnitIds[u].ownerId = GetPlayerId(newOwnerId)
        hook.next(u, newOwnerId, changeColor)
    end)
    Hook.add("UnitApplyTimedLife", function(hook, whichUnit, buffId, duration)
        -- Duration of the life changes when you save state, so we have to track this function seperately
        hook.next(whichUnit, buffId, duration)
        if AllUnitIds[whichUnit] == nil then
            OnUnitCreated(whichUnit)
        end
        AllUnitIds[whichUnit].expireTime = GetElapsedGameTime() + duration
        AllUnitIds[whichUnit].buffId = buffId
    end)
end)

if Debug then Debug.endFile() end