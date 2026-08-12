local lib = {}

local LIB_ID = "terminal-cli"
local INPUT_SCRIPT = "scripts/input.lua"
local PROMPT = "kristal> "
local SCROLLBACK_MAX = 500
local HISTORY_MAX = 200
local HISTORY_FILE = "terminal-cli-history.txt"

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
            owner:append_output(table.concat(parts, "\t"))
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

    local function hook_logged_method(orig, console, text)
        local previous = owner._suppress_push
        owner._suppress_push = true
        local ok, result = pcall(orig, console, text)
        owner._suppress_push = previous

        if not ok then
            error(result)
        end
        return result
    end

    HookSystem.hook(Console, "log", hook_logged_method)
    HookSystem.hook(Console, "warn", hook_logged_method)
    HookSystem.hook(Console, "error", hook_logged_method)

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

-- ===== TUI editor =====

function lib:char_len_at(c)
    local b = self.buffer
    if c < 1 or c > #b then
        return 0
    end
    local byte = b:byte(c)
    if byte < 0x80 then
        return 1
    elseif byte >= 0xF0 then
        return 4
    elseif byte >= 0xE0 then
        return 3
    elseif byte >= 0xC0 then
        return 2
    end
    return 1
end

function lib:char_end_before(c)
    -- start byte of the character whose last byte is at c; 0 if none
    if c <= 0 then
        return 0
    end
    local b = self.buffer
    local i = c
    while i > 0 do
        local byte = b:byte(i)
        if byte < 0x80 or byte >= 0xC0 then
            return i
        end
        i = i - 1
    end
    return 0
end

function lib:cursor_column()
    local col = 0
    local i = 1
    while i <= self.cursor do
        local len = self:char_len_at(i)
        col = col + (len == 1 and 1 or 2) -- CJK chars count as width 2
        i = i + len
    end
    return col
end

function lib:history_load()
    local content = love.filesystem.read(HISTORY_FILE)
    if content then
        for line in content:gmatch("[^\r\n]+") do
            table.insert(self.history, line)
        end
    end
    self.history_pos = nil
end

function lib:history_up()
    if #self.history == 0 then
        return
    end
    if self.history_pos == nil then
        self.history_pos = #self.history
    elseif self.history_pos > 1 then
        self.history_pos = self.history_pos - 1
    end
    self.buffer = self.history[self.history_pos] or ""
    self.cursor = #self.buffer
end

function lib:history_down()
    if self.history_pos == nil then
        return
    end
    if self.history_pos < #self.history then
        self.history_pos = self.history_pos + 1
        self.buffer = self.history[self.history_pos] or ""
    else
        self.history_pos = nil
        self.buffer = ""
    end
    self.cursor = #self.buffer
end

function lib:commit_line()
    local text = self.buffer
    self.buffer = ""
    self.cursor = 0
    self.history_pos = nil

    if text ~= "" then
        table.insert(self.scrollback, PROMPT .. text)
        table.insert(self.history, text)
        while #self.history > HISTORY_MAX do
            table.remove(self.history, 1)
        end
        love.filesystem.write(HISTORY_FILE, table.concat(self.history, "\n") .. "\n")

        self._remote_depth = (self._remote_depth or 0) + 1
        local ok, err = pcall(function()
            Kristal.Console:run({ text })
        end)
        self._remote_depth = self._remote_depth - 1
        if not ok then
            if Kristal.Console then
                Kristal.Console:error(tostring(err))
            else
                print("[ERROR] " .. tostring(err))
            end
        end
    end
    self.dirty = true
end

function lib:handle_key(value)
    local b = self.buffer
    local c = self.cursor

    if value == "left" then
        c = self:char_end_before(c - 1)
    elseif value == "right" then
        c = c + self:char_len_at(c + 1)
    elseif value == "backspace" then
        local s = self:char_end_before(c)
        if s > 0 then
            b = b:sub(1, s - 1) .. b:sub(c + 1)
            c = s - 1
        end
    elseif value == "delete" then
        local len = self:char_len_at(c + 1)
        if len > 0 then
            b = b:sub(1, c) .. b:sub(c + 1 + len)
        end
    elseif value == "home" then
        c = 0
    elseif value == "end" then
        c = #b
    elseif value == "up" then
        self:history_up()
        b = self.buffer
        c = self.cursor
    elseif value == "down" then
        self:history_down()
        b = self.buffer
        c = self.cursor
    elseif value == "ctrl_c" then
        b = ""
        c = 0
        self.history_pos = nil
    elseif value == "ctrl_d" then
        if #b == 0 then
            self:append_output("[terminal-cli] stdin eof.")
            self:stop()
            return
        end
        local len = self:char_len_at(c + 1)
        if len > 0 then
            b = b:sub(1, c) .. b:sub(c + 1 + len)
        end
    elseif value == "enter" then
        self:commit_line()
        return
    elseif value == "tab" then
        -- completion not implemented
    else
        b = b:sub(1, c) .. value .. b:sub(c + 1)
        c = c + #value
    end

    self.buffer = b
    self.cursor = c
    self.dirty = true
end

function lib:terminal_rows()
    local ok, ffi = pcall(require, "ffi")
    if not ok then
        return nil
    end
    if not self._ws_ffi then
        ffi.cdef[[
            struct winsize {
                unsigned short ws_row;
                unsigned short ws_col;
                unsigned short ws_xpixel;
                unsigned short ws_ypixel;
            };
            int ioctl(int fd, unsigned long request, void *arg);
        ]]
        self._ws_ffi = ffi
        self._ws_tiocgwinsz = (ffi.os == "Linux") and 0x5413 or 0x40087468
    end
    local ws = self._ws_ffi.new("struct winsize")
    if self._ws_ffi.C.ioctl(1, self._ws_tiocgwinsz, ws) == 0 then
        local rows = ws.ws_row
        if rows > 0 then
            return rows
        end
    end
    return nil
end

function lib:render()
    if not self.raw_mode then
        return
    end
    local rows = self:terminal_rows() or 24
    local parts = { "\27[2J\27[H" }
    local start = math.max(1, #self.scrollback - rows + 3)
    for i = start, #self.scrollback do
        parts[#parts + 1] = self.scrollback[i]
        parts[#parts + 1] = "\r\n"
    end
    parts[#parts + 1] = "\27[" .. rows .. ";1H" .. "\r\27[K" .. PROMPT .. self.buffer
    parts[#parts + 1] = "\27[" .. (self:cursor_column() + #PROMPT + 1) .. "G"
    self:write_raw(table.concat(parts))
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
                self:history_load()
                self:append_output(self.startup_banner)
                self.dirty = true
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
