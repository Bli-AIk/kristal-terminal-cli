local lib = {}

local LIB_ID = "terminal-cli"
local INPUT_SCRIPT = "scripts/input.lua"
local PROMPT = "kristal> "

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
    if self.running then
        self:write_raw(PROMPT)
    end
end

function lib:write_console_text(text)
    if text == nil then
        return
    end
    self:write_line(text)
end

function lib:install_console_hooks()
    if self.hooks_installed or not Console then
        return
    end

    self.hooks_installed = true
    local owner = self

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

    self:write_raw("\n[terminal-cli] Interactive debug console attached.\n")
    self:write_raw("[terminal-cli] Lua commands run in the game's main thread.\n")
    self:write_prompt()
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
            elseif message.kind == "status" then
                self.input_closed = true
                self:write_line("[terminal-cli] stdin " .. tostring(message.value) .. ".")
                self:stop()
                break
            end
        end
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
