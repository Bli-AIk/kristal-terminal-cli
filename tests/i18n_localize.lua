-- Regression test: the TUI text is only localized when a localization
-- library (kristal-i18n) is around, and the built-in English stays in sync
-- with lang/en.json.
--
-- kristal-i18n merges lang/<language>.json from every loaded library into its
-- tables and installs Game:loc / Game:hasStr. lib.localize() must:
--   * use Game:loc when the i18n API is present and the key exists,
--   * fall back to the built-in English otherwise (no i18n, missing key,
--     or a broken Game:loc), so the library still works standalone.
--
-- Run from the repo root:
--   luajit tests/i18n_localize.lua

local dir = (arg and arg[0]:match("^(.*[/\\])")) or ""
local root = dir .. ".." .. "/"
local lib = assert(loadfile(root .. "lib.lua"))()

local EN = "[terminal-cli] Interactive debug console attached."
local EN_MAIN_THREAD = "[terminal-cli] Lua commands run in the game's main thread."
local EN_VT = "[terminal-cli] VT sequences unavailable; use Windows Terminal or Win10+ conhost."
local EN_EOF = "[terminal-cli] stdin eof."

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

-- Minimal flat JSON reader: the lang files are flat key -> string maps.
local function read_lang(path)
    local content = read_file(path)
    local out = {}
    for key, value in content:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do
        out[key] = value
    end
    return out
end

local function with_game(game, fn)
    local previous_game, previous_mod = _G.Game, _G.Mod
    _G.Game = game
    _G.Mod = { libs = game ~= nil and { kristalI18n = {} } or {} }
    local ok, err = pcall(fn)
    _G.Game, _G.Mod = previous_game, previous_mod
    if not ok then
        error(err, 0)
    end
end

-- Case 1: no i18n library -> built-in English.
with_game(nil, function()
    local text = lib.localize("terminal_cli_banner_attached", EN)
    check("no i18n uses built-in English", text == EN, tostring(text))
end)

-- Case 2: i18n present, key translated -> localized text, vars forwarded.
with_game({
    langStr = {
        terminal_cli_banner_attached = "[terminal-cli] 交互式调试控制台已连接。",
        terminal_cli_stdin_status = "[terminal-cli] 标准输入：[var:value]。",
    },
    langBaseStr = {},
    loc = function(_, id, vars)
        local value = Game.langStr[id] or Game.langBaseStr[id]
        if value == nil then
            return id .. " is missing"
        end
        return (value:gsub("%[var:([%w_]+)%]", function(key)
            return tostring(vars and vars[key] or "")
        end))
    end,
    hasStr = function(_, id)
        return Game.langStr[id] ~= nil or Game.langBaseStr[id] ~= nil
    end,
}, function()
    local text = lib:startup_banner()
    check(
        "i18n present localizes the banner",
        text == "\n[terminal-cli] 交互式调试控制台已连接。\n[terminal-cli] Lua commands run in the game's main thread.\n",
        text
    )

    local status = lib.localize("terminal_cli_stdin_status", "[terminal-cli] stdin eof.", { value = "eof" })
    check("vars are forwarded to Game:loc", status == "[terminal-cli] 标准输入：eof。", status)
end)

-- Case 3: i18n present but the key is missing -> built-in English.
with_game({
    langStr = {},
    langBaseStr = {},
    loc = function(_, id)
        return id .. " is missing"
    end,
    hasStr = function(_, id)
        return Game.langStr[id] ~= nil or Game.langBaseStr[id] ~= nil
    end,
}, function()
    local text = lib.localize("terminal_cli_vt_unavailable", EN_VT)
    check("missing key falls back to English", text == EN_VT, text)
end)

-- Case 4: broken Game:loc must not break the TUI.
with_game({
    loc = function()
        error("boom")
    end,
    hasStr = function()
        return true
    end,
}, function()
    local text = lib.localize("terminal_cli_stdin_eof", EN_EOF)
    check("Game:loc error falls back to English", text == EN_EOF, text)
end)

-- Case 5: the i18n API alone is not enough -- the library must be loaded.
do
    local previous_game, previous_mod = _G.Game, _G.Mod
    _G.Game = {
        loc = function()
            return "translated"
        end,
        hasStr = function()
            return true
        end,
    }
    _G.Mod = { libs = {} }
    local ok, text = pcall(lib.localize, "terminal_cli_stdin_eof", EN_EOF)
    _G.Game, _G.Mod = previous_game, previous_mod
    check("Game:loc without the i18n library falls back", ok and text == EN_EOF, tostring(text))
end

-- Case 6: the status message path uses localize() too.
with_game(nil, function()
    local written = {}
    local terminal = {
        running = true,
        input_channel = {
            { session = "test-1", kind = "status", value = "eof" },
            pop = function(self)
                return table.remove(self, 1)
            end,
        },
        session_id = "test-1",
        max_commands_per_frame = 8,
        raw_mode = false,
        dirty = false,
        append_output = function(_, text)
            table.insert(written, text)
        end,
        stop = function(self)
            self.running = false
            self.input_closed = true
        end,
    }
    local ok, err = pcall(lib.process_input, terminal)
    check("status message path runs", ok, tostring(err))
    check("status message is localized/fallback", written[1] == "[terminal-cli] stdin eof.", tostring(written[1]))
end)

-- Case 7: lang/en.json mirrors the built-in English exactly.
do
    local en = read_lang(root .. "lang/en.json")
    local literals = {
        { "terminal_cli_banner_attached", EN },
        { "terminal_cli_banner_main_thread", EN_MAIN_THREAD },
        { "terminal_cli_vt_unavailable", EN_VT },
        { "terminal_cli_stdin_eof", EN_EOF },
    }
    for _, case in ipairs(literals) do
        local key, expected = case[1], case[2]
        check("en.json has " .. key, en[key] == expected, tostring(en[key]))
    end
    check(
        "en.json has terminal_cli_stdin_status",
        en.terminal_cli_stdin_status == "[terminal-cli] stdin [var:value].",
        tostring(en.terminal_cli_stdin_status)
    )
end

-- Case 8: translations cover the same keys as English.
do
    local en = read_lang(root .. "lang/en.json")
    local zh = read_lang(root .. "lang/zh_hans.json")
    local missing = {}
    for key in pairs(en) do
        if zh[key] == nil then
            table.insert(missing, key)
        end
    end
    table.sort(missing)
    check("zh_hans.json covers en.json keys", #missing == 0, table.concat(missing, ", "))

    local extra = {}
    for key in pairs(zh) do
        if en[key] == nil then
            table.insert(extra, key)
        end
    end
    table.sort(extra)
    check("zh_hans.json has no unknown keys", #extra == 0, table.concat(extra, ", "))
end

-- Case 9: every localized id used by the TUI has a lang/en.json entry.
do
    local en = read_lang(root .. "lang/en.json")
    for _, source in ipairs({ "lib.lua", "editor.lua" }) do
        local content = read_file(root .. source)
        local seen = 0
        for id in content:gmatch('localize%(?%s*"([%w_]+)"') do
            seen = seen + 1
            check(source .. " key " .. id .. " exists in en.json", en[id] ~= nil, "missing")
        end
        check(source .. " uses at least one localized id", seen > 0)
    end
end

if failures > 0 then
    print(failures .. " test(s) failed")
    os.exit(1)
end
print("all tests passed")
