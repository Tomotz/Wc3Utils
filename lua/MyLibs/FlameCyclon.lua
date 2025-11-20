if Debug then Debug.beginFile("FlameCyclon") end

---@class rayData
---@field radius number
---@field angle number

---@param caster unit
---@param damage number
---@param maxRadius integer -- maximum distance where the fire dies out
---@param duration number -- total duration of the effect in seconds
---@param totalCycles number -- how many full rotations the effect makes around the caster
function CastFlameCyclone(caster, damage, maxRadius, duration, totalCycles)
    local minRadius = 100 -- distance from caster to start the effect at
    local density = 1 ---@type integer how often to shoot rays. The larger the number, the less rays you will send.

    local step = 25 -- distance the fire moves each update. Probably don't want to change this
    local updateRate = 0.03 -- in seconds
    local stepCount = math.ceil(duration / updateRate)
    local counter = 0
    local hitUnits = {} ---@type table<unit, boolean>
    local startFace = GetUnitFacing(caster)
    local rays = {} ---@type rayData[]
    local startX, startY = GetUnitX(caster), GetUnitY(caster)
    local timer = CreateTimer()

    TimerStart(timer, 0.03, true, function()
        counter = counter + 1
        if counter > stepCount then
            DestroyTimer(timer)
            return
        end
        local face = math.fmod(math.ceil(startFace + (counter / stepCount) * 360 * totalCycles), 360)
        BlzSetUnitFacingEx(caster, face)
        if math.fmod(counter, density) == 0 then
            table.insert(rays, {radius=minRadius, angle=face})
        end
        for _, ray in ipairs(rays) do
            local x = startX + ray.radius * Cos(ray.angle * bj_DEGTORAD)
            local y = startY + ray.radius * Sin(ray.angle * bj_DEGTORAD)
            DestroyEffect(AddSpecialEffect("Abilities\\Weapons\\FireBallMissile\\FireBallMissile.mdl", x, y))
            ray.radius = ray.radius + step
            -- damage nearby enemies
            local cond = Condition(function()
                local u = GetFilterUnit()
                if IsUnitEnemy(u, GetOwningPlayer(caster)) and hitUnits[u] ~= true then
                    UnitDamageTarget(caster, u, damage, true, false, ATTACK_TYPE_SIEGE, DAMAGE_TYPE_FIRE, WEAPON_TYPE_WHOKNOWS)
                    hitUnits[u] = true
                end
                return false
            end)
            local g = CreateGroup()
            GroupEnumUnitsInRange(g, x, y, 64, cond)
            DestroyCondition(cond)
            DestroyGroup(g)
        end
        for i = #rays, 1, -1 do
            if rays[i].radius > maxRadius then
                table.remove(rays, i)
            end
        end

    end)
end

OnInit.trig(function()
    local t = CreateTrigger()
    TriggerRegisterAnyUnitEventBJ(t, EVENT_PLAYER_UNIT_SPELL_CAST)
    TriggerAddAction(t, function()
        local u = GetTriggerUnit()
        local level = GetUnitAbilityLevel(u, GetSpellAbilityId())
        CastFlameCyclone(u, level * 300, level * 300, level, level)
    end)
end)

if Debug then Debug.endFile() end