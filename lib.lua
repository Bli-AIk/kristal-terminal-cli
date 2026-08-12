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

local function strip_console_modifiers(text)
    text = tostring(text)
    text = text:gsub("%[color:[^%]]*%]", "")
    text = text:gsub("%[nomods%]", "")
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
    text = strip_console_modifiers(text)
    if text:sub(-1) ~= "\n" then
        text = text .. "\n"
    end
    return self:write_raw(text)
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
    text = strip_console_modifiers(text)
    if self.raw_mode then
        for _, line in ipairs(split_lines(text)) do
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
    self.startup_banner = "\n[terminal-cli] Interactive debug console attached.\n"
        .. "[terminal-cli] Lua commands run in the game's main thread.\n"

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
                    self:append_output("[terminal-cli] VT sequences unavailable; use Windows Terminal or Win10+ conhost.")
                    self:stop()
                else
                    self:history_load()
                    self:append_output(self.startup_banner)
                    self.dirty = true
                end
            elseif message.kind == "plain" then
                self.raw_mode = false
                self:write_line(self.startup_banner)
                self:write_prompt()
            elseif message.kind == "status" then
                self.input_closed = true
                self:append_output("[terminal-cli] stdin " .. tostring(message.value) .. ".")
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
