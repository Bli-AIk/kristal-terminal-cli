-- Lua syntax highlighting for the input line.

local LUA_KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true,
    ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true, ["while"] = true,
}

return function(lib)
    function lib:highlight_lua(text)
        local parts = {}
        local i = 1
        local n = #text
        while i <= n do
            local b = text:byte(i)
            if b == 45 and text:byte(i + 1) == 45 then
                -- comment: -- to end of line
                local j = text:find("\n", i, true) or (n + 1)
                parts[#parts + 1] = "\27[90m" .. text:sub(i, j - 1) .. "\27[0m"
                i = j
            elseif b == 34 or b == 39 then
                -- string: "..." / '...' with backslash escapes
                local q = b
                local j = i + 1
                while j <= n do
                    local c = text:byte(j)
                    if c == 92 then
                        j = j + 2
                    elseif c == q then
                        j = j + 1
                        break
                    else
                        j = j + 1
                    end
                end
                parts[#parts + 1] = "\27[33m" .. text:sub(i, j - 1) .. "\27[0m"
                i = j
            elseif (b >= 48 and b <= 57) or (b == 46 and text:byte(i + 1) and text:byte(i + 1) >= 48 and text:byte(i + 1) <= 57) then
                -- number: digits, hex digits, decimal point
                local j = i
                while j <= n do
                    local c = text:byte(j)
                    if (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)
                        or c == 46 or c == 120 or c == 88 then
                        j = j + 1
                    else
                        break
                    end
                end
                parts[#parts + 1] = "\27[35m" .. text:sub(i, j - 1) .. "\27[0m"
                i = j
            elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 then
                -- identifier / keyword
                local j = i
                while j <= n do
                    local c = text:byte(j)
                    if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 then
                        j = j + 1
                    else
                        break
                    end
                end
                local word = text:sub(i, j - 1)
                parts[#parts + 1] = (LUA_KEYWORDS[word] and "\27[36m" or "\27[0m") .. word .. "\27[0m"
                i = j
            else
                parts[#parts + 1] = text:sub(i, i)
                i = i + 1
            end
        end
        return table.concat(parts)
    end
end
