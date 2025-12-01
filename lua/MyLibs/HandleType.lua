if Debug then Debug.beginFile("HandleType") end
do
    --[[
    https://www.hiveworkshop.com/threads/get-handle-type.354436/
    ===============================================================================================================================================================
                                                                        Handle Type
                                                                        by Antares
    ===============================================================================================================================================================

    Determine the type of a Wacraft 3 object (handle). The result is stored in a table on the first execution to increase performance.

    HandleType[whichHandle]     -> string           Returns an empty string if variable is not a handle.
    IsHandle[whichHandle]       -> boolean
    IsWidget[whichHandle]       -> boolean
    IsUnit[whichHandle]         -> boolean

    These can also be called as a function, which has a nil-check, but is slower than the table-lookup

    ===============================================================================================================================================================
    ]]

    local widgetTypes = {
        unit = true,
        destructable = true,
        item = true
    }

    HandleType = setmetatable({}, {
        __mode = "k",
        __index = function(self, key)
            if type(key) == "userdata" then
                local str = tostring(key)
                self[key] = str:sub(1, (str:find(":", nil, true) or 0) - 1)
                return self[key]
            else
                self[key] = ""
                return ""
            end
        end,
        __call = function(self, key)
            if key then
                return self[key]
            else
                return ""
            end
        end
    })

    IsHandle = setmetatable({}, {
        __mode = "k",
        __index = function(self, key)
            self[key] = HandleType[key] ~= ""
            return self[key]
        end,
        __call = function(self, key)
            if key then
                return self[key]
            else
                return false
            end
        end
    })

    IsWidget = setmetatable({}, {
        __mode = "k",
        __index = function(self, key)
            self[key] = widgetTypes[HandleType[key]] == true
            return self[key]
        end,
        __call = function(self, key)
            if key then
                return self[key]
            else
                return false
            end
        end
    })

    IsUnit = setmetatable({}, {
        __mode = "k",
        __index = function(self, key)
            self[key] = HandleType[key] == "unit"
            return self[key]
        end,
        __call = function(self, key)
            if key then
                return self[key]
            else
                return false
            end
        end
    })

    local typeIdFuncs = {unit=GetUnitTypeId, item=GetItemTypeId, destructable=GetDestructableTypeId, ability=BlzGetAbilityId}
    ---@param handle userdata
    ---@return integer
    function GetObjectTypeId(handle)
        local handleType = HandleType[handle]
        local func = typeIdFuncs[handleType]
        if func then
            return func(handle)
        else
            return 0
        end
    end

end
if Debug then Debug.endFile() end