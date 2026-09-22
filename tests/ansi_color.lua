-- Regression test: the TUI (and plain stdout) keeps the engine console's
-- colors instead of deleting them.
--
-- Engine console lines reach this library as either a
-- "[color:name]"-markup string (translations) or the console history's
-- segment array ({"text", {r,g,b,a}, ...}). Both used to be flattened down to
-- plain text; they must now become ANSI escapes the terminal can render, with
-- the color closed off at every line boundary so it cannot bleed into the
-- next line or into the TUI's input row.
--
-- Run from the repo root:
--   luajit tests/ansi_color.lua

local dir = (arg and arg[0]:match("^(.*[/\\])")) or ""
local root = dir .. ".." .. "/"
local lib = assert(loadfile(root .. "lib.lua"))()

local RESET = "\27[0m"

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local function escape(text)
    return (text:gsub("%\27", "\\27"))
end

-- Runs one value through the real output path and returns the scrollback the
-- TUI would draw (one entry per line).
local function tui_lines(value)
    local target = setmetatable({ raw_mode = true, scrollback = {}, dirty = false }, { __index = lib })
    lib.append_output(target, value)
    return target.scrollback
end

-- Runs one value through the non-TUI path and returns what hit stdout.
local function stdout_text(value)
    local written = {}
    local target = setmetatable({
        raw_mode = false,
        write_raw = function(_, text)
            written[#written + 1] = text
            return true
        end,
    }, { __index = lib })
    lib.append_output(target, value)
    return table.concat(written)
end

-- Engine palette, mirrored in the library for the engine-less case.
local CYAN = "\27[38;2;128;255;255m"
local WHITE = "\27[38;2;255;255;255m"
local RED = "\27[38;2;255;0;0m"
local LTGRAY = "\27[38;2;191;191;191m"

-- 1. Named markup turns into SGR instead of vanishing.
local welcome = tui_lines("[color:cyan]KRISTAL[color:reset]!")
check("markup: cyan becomes an escape", welcome[1]:find(CYAN, 1, true) ~= nil, escape(welcome[1]))
check("markup: reset becomes the default color", welcome[1]:find(WHITE, 1, true) ~= nil, escape(welcome[1]))
check("markup: text survives", welcome[1]:find("KRISTAL", 1, true) ~= nil, escape(welcome[1]))
check("markup: no literal markup left", welcome[1]:find("[color:", 1, true) == nil, escape(welcome[1]))
check("markup: color is closed off", welcome[1]:sub(-#RESET) == RESET, escape(welcome[1]))

-- 2. The segment array shape the engine's Logger produces.
local segments = tui_lines({ "Welcome to ", { 0.5, 1, 1, 1 }, "KRISTAL", { 1, 1, 1, 1 }, "!" })
check("segments: color table becomes an escape", segments[1]:find(CYAN, 1, true) ~= nil, escape(segments[1]))
check("segments: switch back is kept", segments[1]:find(WHITE, 1, true) ~= nil, escape(segments[1]))
check(
    "segments: text is unchanged",
    segments[1]:gsub("\27%[[%d;]*m", "") == "Welcome to KRISTAL!",
    escape(segments[1])
)

-- 3. Text with no color is passed through untouched, so plain output stays
--    free of stray escapes.
local plain = tui_lines("just a line")
check("plain: untouched", plain[1] == "just a line", escape(plain[1]))
check("plain: stdout untouched", stdout_text("just a line") == "just a line\n")

-- 4. [nomods] is a directive, not a color: it is removed either way.
check("nomods: removed", tui_lines("[nomods]plain")[1] == "plain", escape(tui_lines("[nomods]plain")[1]))

-- 5. Hex colors, matching the engine's legacy markup parser.
local hex = tui_lines("[color:#ff0000]x")
check("hex: #rrggbb becomes an escape", hex[1]:find(RED, 1, true) ~= nil, escape(hex[1]))

-- 6. Unknown names fall back to white rather than dropping the text.
local unknown = tui_lines("[color:nosuchcolor]x")
check("unknown: falls back to white", unknown[1]:find(WHITE, 1, true) ~= nil, escape(unknown[1]))

-- 7. Multi-line input: every line has to close its own color, or the next
--    line (and the prompt below it) inherits it.
local multiline = tui_lines("[color:#ff0000]first\nsecond")
check("multiline: split into two lines", #multiline == 2, tostring(#multiline))
check("multiline: first line sealed", multiline[1]:sub(-#RESET) == RESET, escape(multiline[1]))
check("multiline: second line sealed", multiline[2]:sub(-#RESET) == RESET, escape(multiline[2]))
check("multiline: second line keeps its text", multiline[2] == "second" .. RESET, escape(multiline[2]))

-- 8. The engine's COLORS global wins when it is around.
local custom = tui_lines("[color:ltgray]x")
check("fallback: engine-less ltgray", custom[1]:find(LTGRAY, 1, true) ~= nil, escape(custom[1]))

local previous_colors = rawget(_G, "COLORS")
_G.COLORS = { ltgray = { 1, 0, 0, 1 } }
local overridden = tui_lines("[color:ltgray]x")
check("engine palette: COLORS is preferred", overridden[1]:find(RED, 1, true) ~= nil, escape(overridden[1]))
rawset(_G, "COLORS", previous_colors)

-- 9. When the engine reports no color support (NO_COLOR, dumb terminal, or a
--    redirected stdout), the markup is stripped exactly as it used to be.
local previous_logging = rawget(_G, "Logging")
_G.Logging = { getColorSupport = function() return false end }
local plain_mode = tui_lines("[color:cyan]KRISTAL[color:reset]!")
check("no color support: markup stripped", plain_mode[1] == "KRISTAL!", escape(plain_mode[1]))
check("no color support: no escapes", plain_mode[1]:find("\27", 1, true) == nil)
rawset(_G, "Logging", previous_logging)

if failures > 0 then
    print(("\n%d check(s) failed"):format(failures))
    os.exit(1)
end

print("\nall checks passed")
