if Debug then Debug.beginFile("PrettyString") end
do
--[[
PrettyString v1.0.0 by Tomotz
    Provides a PrettyString function that can convert tables and wc3 handles to a nice string representation.
    Useful for logging and debugging.

Optionaly requires:
    HandleType by Antares - https://www.hiveworkshop.com/threads/get-handle-type.354436/ - to parse the handles (Use my version to have GetObjectTypeId function).
    Hook by Bribe - https://www.hiveworkshop.com/threads/hook.339153/ - if you want to hook print and IngameConsole to use PrettyString automatically.
--]]
---@param num integer
---@return string
function FourCC2Str(num)
    return string.pack('>I4', num)
end

---@param tbl table
---@return string -- note that `pairs` is used, so the result is not synced between players
function TableToStr(tbl)
    local out = {}
    table.insert(out, "{")
    for k, v in pairs(tbl) do
        table.insert(out, PrettyString(k))
        table.insert(out, ": ")
        table.insert(out, PrettyString(v))
        if next(tbl, k) ~= nil then
            table.insert(out, ", ")
        end
    end
    table.insert(out, "}")
    return table.concat(out, "")
end

local initDone = false
OnInit.final(function() initDone = true end)

---@param arg any
---@return string -- returns a pretty string representation of the argument -- note that `pairs` is used, so the result is not synced between players
function PrettyString(arg)
    if type(arg) == "table" then
        return TableToStr(arg)
    elseif type(arg) == "userdata" then
        local type = HandleType and HandleType[arg] or ""
        if type == "" then
            return tostring(arg)
        end
        local id = GetObjectTypeId(arg)
        local name = initDone and GetObjectName(arg) or "" -- using GetObjectName during init can cause crashes
        return type .. ": " .. name .. "('" .. FourCC2Str(id) .. "')"
    end
    return tostring(arg)
end

OnInit.final(function()
    if Hook then
        Hook.add("print", function(hook, ...)
            local args = {...}
            for i = 1, #args do
                args[i] = PrettyString(args[i])
            end
            hook.next(table.unpack(args))
        end)

        -- Ingame console runs over the print function, so we need to hook it's functions
        if IngameConsole and IngameConsole.originalPrint ~= nil then
            IngameConsole.originalPrint = print
            Hook.add("out", function(hook, a, b, c, ...)
                local args = {...}
                for i = 1, #args do
                    args[i] = PrettyString(args[i])
                end
                hook.next(a, b, c, table.unpack(args))
            end, 0, IngameConsole)
        end
    end
end)
end
if Debug then Debug.endFile() end
