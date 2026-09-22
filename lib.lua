local lib = {}

local LIB_ID = "terminal-cli"
local INPUT_SCRIPT = "scripts/input.lua"
local PROMPT = "kristal> "
local SCROLLBACK_MAX = 500
local HISTORY_MAX = 200
local HISTORY_FILE = "terminal-cli-history.txt"

lib.PROMPT = PROMPT
lib.HISTORY_MAX = HISTORY_MAX
lib.HISTORY_FILE = HISTORY_FILE

local function config(key)
    return Kristal.getLibConfig(LIB_ID, key)
end

-- Selective localization: only when kristal-i18n is loaded -- it registers
-- itself in Mod.libs and installs Game:loc / Game:hasStr, and it merges
-- lang/<language>.json from every loaded library (which is why this library
-- ships lang/en.json and lang/zh_hans.json). Without i18n, or without the key,
-- the built-in English text below is used unchanged.
local function i18n_available()
    return Mod ~= nil
        and type(Mod.libs) == "table"
        and Mod.libs["kristalI18n"] ~= nil
        and Game ~= nil
        and type(Game.loc) == "function"
        and type(Game.hasStr) == "function"
end

local function localize(id, fallback, vars)
    if i18n_available() and Game:hasStr(id) then
        local ok, text = pcall(Game.loc, Game, id, vars)
        if ok and type(text) == "string" then
            return text
        end
    end
    return fallback
end

lib.localize = localize

local ANSI_RESET = "\27[0m"

-- Fallback for the engine's named console colors, for when the engine's global
-- COLORS table is not around (the headless unit tests). Values mirror
-- src/engine/vars.lua.
local FALLBACK_COLORS = {
    aqua = { 0, 1, 1, 1 },
    black = { 0, 0, 0, 1 },
    blue = { 0, 0, 1, 1 },
    dkgray = { 0.25, 0.25, 0.25, 1 },
    fuchsia = { 1, 0, 1, 1 },
    gray = { 0.5, 0.5, 0.5, 1 },
    green = { 0, 0.5, 0, 1 },
    lime = { 0, 1, 0, 1 },
    ltgray = { 0.75, 0.75, 0.75, 1 },
    maroon = { 0.5, 0, 0, 1 },
    navy = { 0, 0, 0.5, 1 },
    olive = { 0.5, 0.5, 0, 1 },
    orange = { 1, 0.625, 0.25, 1 },
    purple = { 0.5, 0, 0.5, 1 },
    red = { 1, 0, 0, 1 },
    silver = { 0.75, 0.75, 0.75, 1 },
    teal = { 0, 0.5, 0.5, 1 },
    white = { 1, 1, 1, 1 },
    yellow = { 1, 1, 0, 1 },
}

-- COLORS is an engine global, so it may only be touched once the engine is up;
-- keeping this a lookup rather than a cached table also keeps module loading
-- safe under the engine-less unit tests.
local function named_color(name)
    if name == "cyan" then
        -- The engine palette has no "cyan"; this is the value kristal-i18n
        -- resolves the name to.
        return { 0.5, 1, 1, 1 }
    end

    local hex = name:match("^#(%x%x%x%x%x%x)$")
    if hex then
        return {
            tonumber(hex:sub(1, 2), 16) / 255,
            tonumber(hex:sub(3, 4), 16) / 255,
            tonumber(hex:sub(5, 6), 16) / 255,
            1,
        }
    end

    local colors = rawget(_G, "COLORS")
    if colors and name ~= "reset" and colors[name] then
        return colors[name]
    end

    if name == "reset" then
        return FALLBACK_COLORS.white
    end
    return FALLBACK_COLORS[name] or FALLBACK_COLORS.white
end

local function channel(value)
    local scaled = math.floor((tonumber(value) or 1) * 255 + 0.5)
    if scaled < 0 then
        return 0
    end
    if scaled > 255 then
        return 255
    end
    return scaled
end

-- Enough of the engine's RGB color tables for the terminal to show them.
-- Alpha has no SGR equivalent and is dropped.
local function color_to_ansi(color)
    return "\27[38;2;" .. channel(color[1]) .. ";" .. channel(color[2]) .. ";" .. channel(color[3]) .. "m"
end

-- The engine's console takes [color:name] markup only in translations; the
-- TUI writes raw scrollback lines, so turn the markup into escape sequences
-- rather than deleting the color (which is what it used to do).
local function markup_to_ansi(text)
    text = tostring(text)
    text = text:gsub("%[color:([^%]]*)%]", function(name)
        return color_to_ansi(named_color(name))
    end)
    text = text:gsub("%[nomods%]", "")
    return text
end

-- Engine console lines arrive either as markup strings or as the console
-- history's segment array ({"text", {r,g,b,a}, "text", ...}) where a table
-- switches the color from that point on (src/engine/game/console.lua).
local function value_to_ansi(value)
    if value == nil then
        return ""
    end
    if type(value) ~= "table" then
        return markup_to_ansi(value)
    end

    local parts = {}
    for _, part in ipairs(value) do
        if type(part) == "table" then
            parts[#parts + 1] = color_to_ansi(part)
        else
            parts[#parts + 1] = tostring(part)
        end
    end
    return table.concat(parts)
end

local function strip_console_modifiers(text)
    text = tostring(text)
    text = text:gsub("%[color:[^%]]*%]", "")
    text = text:gsub("%[nomods%]", "")
    return text
end

local function console_value_to_text(value)
    if type(value) ~= "table" then
        return tostring(value or "")
    end
    local parts = {}
    for _, part in ipairs(value) do
        if type(part) == "string" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts)
end

-- Respects the engine's color support detection (which honors NO_COLOR), so a
-- dumb terminal or a redirected stdout keeps getting plain text.
local function colors_enabled()
    if Logging and Logging.getColorSupport then
        return Logging.getColorSupport()
    end
    return true
end

-- Renders one engine console value for this output, and closes the color off
-- at every line boundary so it cannot bleed into the following line or into
-- the TUI's input row. Text that carries no escapes is returned untouched.
local function render_console_text(value)
    if not colors_enabled() then
        return strip_console_modifiers(console_value_to_text(value))
    end

    local text = value_to_ansi(value)
    if not text:find("\27", 1, true) then
        return text
    end

    text = text:gsub("\n", ANSI_RESET .. "\n")
    if text:sub(-1) ~= "\n" then
        text = text .. ANSI_RESET
    end
    return text
end

local function make_session_id()
    return string.format(
        "%d-%d",
        os.time(),
        math.floor((love.timer.getTime() % 1) * 1000000)
    )
end

function lib:write_raw(text)
    if not self.output_enabled or not io or not io.stdout then
        return false
    end

    local ok = pcall(function()
        io.stdout:write(text)
        io.stdout:flush()
    end)
    if not ok then
        self.output_enabled = false
    end
    return ok
end

function lib:write_line(text)
    text = render_console_text(text)
    if text:sub(-1) ~= "\n" then
        text = text .. "\n"
    end
    return self:write_raw(text)
end

function lib:startup_banner()
    return "\n"
        .. localize("terminal_cli_banner_attached", "[terminal-cli] Interactive debug console attached.")
        .. "\n"
        .. localize("terminal_cli_banner_main_thread", "[terminal-cli] Lua commands run in the game's main thread.")
        .. "\n"
end

function lib:write_prompt()
    -- In raw (TUI) mode the input line is drawn by render().
    if self.running and not self.raw_mode then
        self:write_raw(PROMPT)
    end
end

function lib:write_console_text(text)
    if text == nil then
        return
    end
    -- append_output renders whichever shape this arrives in (markup string or
    -- segment array) for the output mode that is currently active.
    self:append_output(text)
end

local function split_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, (line:gsub("\r$", "")))
    end
    return lines
end

function lib:append_output(text)
    if self.raw_mode then
        for _, line in ipairs(split_lines(render_console_text(text))) do
            table.insert(self.scrollback, line)
        end
        while #self.scrollback > SCROLLBACK_MAX do
            table.remove(self.scrollback, 1)
        end
        self.dirty = true
    else
        self:write_line(text)
    end
end

function lib:clear_screen()
    if self.raw_mode then
        self.scrollback = {}
        self.dirty = true
    end
end

function lib:install_console_hooks()
    if self.hooks_installed or not Console then
        return
    end

    self.hooks_installed = true
    local owner = self

    -- Route engine output (print) into the console instead of raw stdout;
    -- otherwise it clobbers the TUI input line and gets erased by redraws.
    if not self.print_hooked then
        self.print_hooked = true
        _G.print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[i] = tostring((select(i, ...)))
            end
            local text = table.concat(parts, "\t")
            if owner._in_error_scope then
                text = "\27[38;5;210m" .. text .. "\27[0m"
            end
            owner:append_output(text)
        end
    end

    -- clear() in the console env should also clear the terminal scrollback.
    -- Kristal.Console is the instance (Console is the class); the env lives on the instance.
    if not self.clear_hooked then
        local console_env = Kristal.Console and Kristal.Console.env
        if console_env and console_env.clear then
            self.clear_hooked = true
            local orig_clear = console_env.clear
            console_env.clear = function()
                orig_clear()
                owner:clear_screen()
            end
        end
    end

    HookSystem.hook(Console, "push", function(orig, console, text)
        local result = orig(console, text)

        if owner._capture_run and not owner._suppress_push then
            table.insert(owner._capture_run, text)

            -- The terminal already echoes a line typed on stdin. Commands
            -- typed in the game still need their normal console history echo.
            local is_command_echo = #owner._capture_run == 1
            if not (owner._run_remote and is_command_echo) then
                owner:write_console_text(text)
            end
        elseif owner.running and not owner._suppress_push then
            owner:write_console_text(text)
            owner:write_prompt()
        end

        return result
    end)

    local function hook_logged_method(orig, console, text, is_error)
        local previous = owner._suppress_push
        owner._suppress_push = true
        -- Keep the flag through the current message batch: the raw error
        -- print in Console:run fires right after Console:error returns.
        if is_error then
            owner._in_error_scope = true
        end
        local ok, result = pcall(orig, console, text)
        owner._suppress_push = previous

        if not ok then
            error(result)
        end
        return result
    end

    HookSystem.hook(Console, "log", hook_logged_method)
    HookSystem.hook(Console, "warn", hook_logged_method)
    HookSystem.hook(Console, "error", function(orig, console, text)
        return hook_logged_method(orig, console, text, true)
    end)

    HookSystem.hook(Console, "run", function(orig, console, lines)
        local previous_capture = owner._capture_run
        local previous_remote = owner._run_remote

        owner._capture_run = {}
        owner._run_remote = (owner._remote_depth or 0) > 0

        local ok, result = pcall(orig, console, lines)

        owner._capture_run = previous_capture
        owner._run_remote = previous_remote

        if not ok then
            error(result)
        end

        owner:write_prompt()
        return result
    end)

    HookSystem.hook(love, "quit", function(orig, ...)
        owner:stop()
        return orig(...)
    end)
end

function lib:start()
    if self.running then
        return true
    end

    if not love.thread or not love.thread.newThread then
        print("[WARNING] terminal-cli requires Love thread support")
        return false
    end

    local script_path = self.info.path .. "/" .. INPUT_SCRIPT
    if not love.filesystem.getInfo(script_path) then
        print("[WARNING] terminal-cli input script not found: " .. script_path)
        return false
    end

    self.session_id = make_session_id()
    self.channel_name = "kristal_terminal_cli_" .. self.session_id
    self.control_name = self.channel_name .. "_control"
    self.input_channel = love.thread.getChannel(self.channel_name)
    self.control_channel = love.thread.getChannel(self.control_name)
    self.output_enabled = true

    local ok, thread_or_error = pcall(love.thread.newThread, script_path)
    if not ok then
        print("[WARNING] terminal-cli could not create input thread: " .. tostring(thread_or_error))
        return false
    end

    self.thread = thread_or_error
    self.running = true
    self.input_closed = false
    self.raw_mode = false
    self.scrollback = {}
    self.history = {}
    self.buffer = ""
    self.cursor = 0

    local start_ok, start_error = pcall(
        self.thread.start,
        self.thread,
        self.channel_name,
        self.control_name,
        self.session_id
    )
    if not start_ok then
        self.running = false
        self.thread = nil
        print("[WARNING] terminal-cli could not start input thread: " .. tostring(start_error))
        return false
    end
    return true
end

function lib:stop()
    if not self.running and not self.thread then
        return
    end

    self.running = false
    self.input_closed = true

    if self.control_channel then
        self.control_channel:push("stop")
    end

    self.thread = nil
    self.input_channel = nil
    self.control_channel = nil
end

function lib:process_input()
    if not self.running or not self.input_channel then
        return
    end

    local limit = self.max_commands_per_frame
    for _ = 1, limit do
        -- handle_key / the raw branch may call self:stop() mid-loop, which
        -- nils input_channel; bail out instead of indexing nil below.
        if not self.running or not self.input_channel then
            break
        end
        local message = self.input_channel:pop()
        if not message then
            break
        end

        if message.session == self.session_id then
            if message.kind == "command" then
                self._remote_depth = (self._remote_depth or 0) + 1
                local ok, err = pcall(function()
                    Kristal.Console:run({ message.value or "" })
                end)
                self._remote_depth = self._remote_depth - 1

                if not ok then
                    if Kristal.Console then
                        Kristal.Console:error(tostring(err))
                    else
                        print("[ERROR] " .. tostring(err))
                    end
                    self:write_prompt()
                end
            elseif message.kind == "key" then
                self:handle_key(message.value)
            elseif message.kind == "raw" then
                self.raw_mode = true
                if not self:enable_windows_vt() then
                    self.raw_mode = false
                    self:append_output(localize(
                        "terminal_cli_vt_unavailable",
                        "[terminal-cli] VT sequences unavailable; use Windows Terminal or Win10+ conhost."
                    ))
                    self:stop()
                else
                    self:history_load()
                    if Kristal.Console and Kristal.Console.history then
                        for _, line in ipairs(Kristal.Console.history) do
                            self:write_console_text(line)
                        end
                    end
                    self:append_output(self:startup_banner())
                    self.dirty = true
                end
            elseif message.kind == "plain" then
                self.raw_mode = false
                self:write_line(self:startup_banner())
                self:write_prompt()
            elseif message.kind == "status" then
                self.input_closed = true
                local status = tostring(message.value)
                self:append_output(localize(
                    "terminal_cli_stdin_status",
                    "[terminal-cli] stdin " .. status .. ".",
                    { value = status }
                ))
                self:stop()
                break
            end
        end
    end

    if self.dirty and self.raw_mode then
        self:render()
        self.dirty = false
    end
    self._in_error_scope = false
end

function lib:init()
    self.enabled = config("enabled") ~= false
    self.only_dev = config("only_dev") ~= false
    self.max_commands_per_frame = math.max(1, math.floor(tonumber(config("max_commands_per_frame")) or 8))

    if not self.enabled then
        return
    end
    if self.only_dev and (not Kristal.isDevMode or not Kristal.isDevMode()) then
        return
    end
    if not io or not io.stdin or not io.stdout then
        print("[WARNING] terminal-cli requires standard input and output")
        return
    end

    -- Announced through the engine's "System" logger; kristal-i18n keys off
    -- this exact English wording to translate it (see its localizeConsoleSegments).
    if Logging and Logging.info then
        Logging.info("Enabled library " .. self.info.id .. ".")
    end

    -- Load sub-modules (single responsibility per file).
    for _, name in ipairs({ "highlight", "editor", "tui" }) do
        local chunk, err = love.filesystem.load(self.info.path .. "/" .. name .. ".lua")
        if not chunk then
            error("[terminal-cli] cannot load module " .. name .. ": " .. tostring(err))
        end
        chunk()(self)
    end

    self:install_console_hooks()
    self:start()
end

function lib:preUpdate()
    self:process_input()
end

function lib:unload()
    self:stop()
end

function lib:cleanup()
    self:stop()
end

return lib
