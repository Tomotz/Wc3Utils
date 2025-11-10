if Debug then Debug.beginFile("StringEscape") end
do

--[[
    StringEscape by Tomotz

    Allows escaping unsupported characters in strings.
    Since most characters we want to escape are pretty useful, (textual characters or null terminator which are very common in strings)
    we rather replace those characters with some unprintable characters, and escape the unprintable characters.
    This allows us to avoid bloating up non-random strings, while keeping packing ratio the same for random strings.

    API:
    --- Add escaping to specific chars in a string.
    ---@param str string -- original string we want to escape
    ---@param unsupportedChars integer[] -- the characters that needs to be replaced
    ---@return string -- the escaped string
    function AddEscaping(str, unsupportedChars)

    --- Opens a string previosly escaped with AddEscaping
    ---@param str string -- the escaped string
    ---@param unsupportedChars integer[] -- the characters that were replaced
    ---@return string? -- the original string or nil on input error
    function RemoveEscaping(str, unsupportedChars)

    Requirements:
        DebugUtils by Eikonium                          @ https://www.hiveworkshop.com/threads/330758/
--]]

--- CONFIGURATION
-- ESCAPE_CHAR, and REPLACE_CHARS are charachters we can write to the result string, but are not very
-- useful, and so we take the more useful characters and replace them with these. These characters will have to be escaped if
-- we ever want to use them in the result string.
local ESCAPE_CHAR = 247
-- the characters that will replace the unsupported characters. I recommand not extending this set to 254/255 as these are pretty usefull characters.
-- If you want to extand, change escape_char to be lower, and add more smaller replace chars
local REPLACE_CHARS = {248, 249, 250, 251, 252, 253}
--- CONFIGURATION END

---@param t table -- table of key, value. Note that values must be unique
---@return table -- returns a table with the keys and values swapped
local function getReversedTable(t)
    local out = {}
    for k, v in pairs(t) do
        out[v] = k
    end
    return out
end

--- Add escaping to specific chars in a string.
--- We assume most chars that needs escaping are very useful chars, so to avoid wasting space, we replace them with less useful
--- chars, and then escape the less useful chars (since escaped chars takes 2 bytes instead of 1).
---@param str string -- original string we want to escape
---@param unsupportedChars integer[] -- the characters that needs to be replaced
---@return string -- the escaped string
function AddEscaping(str, unsupportedChars)
    Debug.assert(#unsupportedChars <= #REPLACE_CHARS, "too many unsupported chars to replace. You can extend REPLACE_CHARS to avoid the issue")
    -- note that move function copies elements, it doens't remove them from the original function
    local replaceChars = {}
    table.move(REPLACE_CHARS, 1, #unsupportedChars, 1, replaceChars)
    local newStr = ""
    for i=1, #str do
        local char = str:byte(i)
        if char == ESCAPE_CHAR then
            newStr = newStr .. string.rep(string.char(ESCAPE_CHAR), 2)
            goto continue
        end
        for j, v in ipairs(unsupportedChars) do
            if char == v then
                newStr = newStr .. string.char(replaceChars[j])
                goto continue
            end
        end
        for j, v in ipairs(replaceChars) do
            if char == v then
                newStr = newStr .. string.char(ESCAPE_CHAR) .. string.char(v)
                goto continue
            end
        end
        newStr = newStr .. string.char(char)
        ::continue::
    end
    return newStr
end

--- Opens a string previosly escaped with AddEscaping
---@param str string -- the escaped string
---@param unsupportedChars integer[] -- the characters that were replaced
---@return string? -- the escaped string or nil on input error
function RemoveEscaping(str, unsupportedChars)
    Debug.assert(#unsupportedChars <= #REPLACE_CHARS, "too many unsupported chars to replace. You can extend REPLACE_CHARS to avoid the issue")
    local replaceChars = {}
    table.move(REPLACE_CHARS, 1, #unsupportedChars, 1, replaceChars)
    local reversedReplaceableChars = getReversedTable(replaceChars)
    local newStr = ""
    local i = 1
    while i <= #str do
        local char = str:byte(i)
        i = i + 1
        if char == ESCAPE_CHAR then
            if i <= #str then
                char = str:byte(i)
            else
                Debug.throwError("escaped character at the end of the string")
                return nil
            end
            i = i + 1
            -- either we have 2 escape chars, which we should merge to one,
            -- or we have an escaped char and then a replaceable char which should turn to the
            -- replaceable char
            newStr = newStr .. string.char(char)
        elseif reversedReplaceableChars[char] then
            newStr = newStr .. string.char(unsupportedChars[reversedReplaceableChars[char]])
        else
            newStr = newStr .. string.char(char)
        end
    end
    return newStr
end

end
if Debug then Debug.endFile() end