-- Regression test: process_input must not crash when stop() nils
-- input_channel in the middle of its loop.
--
-- editor.lua's ctrl_d handler at an empty buffer calls self:stop(), which
-- sets running=false and input_channel=nil while process_input's for-loop is
-- still iterating. The next iteration used to call input_channel:pop() on nil
-- ("attempt to index field 'input_channel' (a nil value)", lib.lua:288).
--
-- Run from the repo root:
--   luajit tests/input_channel_nil.lua

local dir = (arg and arg[0]:match("^(.*[/\\])")) or ""
local lib = assert(loadfile(dir .. ".." .. "/lib.lua"))()

local function make_channel(messages)
    local c = {}
    for _, m in ipairs(messages) do
        table.insert(c, m)
    end
    function c:pop()
        return table.remove(self, 1)
    end
    return c
end

local function make_terminal(messages, opts)
    opts = opts or {}
    return {
        running = true,
        input_channel = make_channel(messages),
        control_channel = { push = function() end },
        thread = {},
        session_id = "test-1",
        max_commands_per_frame = 8,
        raw_mode = false,
        dirty = false,
        _remote_depth = 0,
        _in_error_scope = false,
        -- editor.lua: ctrl_d at an empty buffer ends the session.
        handle_key = function(self, value)
            if value == "ctrl_d" then
                self:stop()
            end
        end,
        enable_windows_vt = function()
            return opts.vt_ok ~= false
        end,
        append_output = function() end,
        write_prompt = function() end,
        write_line = function() end,
        render = function() end,
        history_load = function() end,
        stop = function(self)
            self.running = false
            self.input_closed = true
            self.thread = nil
            self.input_channel = nil
            self.control_channel = nil
        end,
    }
end

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

-- Case 1: ctrl_d (empty buffer) calls stop() mid-loop, with more queued
-- messages behind it. Used to crash on input_channel:pop().
do
    local t = make_terminal({
        { session = "test-1", kind = "key", value = "ctrl_d" },
        { session = "test-1", kind = "key", value = "x" },
    })
    local ok, err = pcall(lib.process_input, t)
    check("ctrl_d-empty-buffer mid-loop stop", ok, tostring(err))
    check("  input_channel nil after stop", t.input_channel == nil)
    check("  running false after stop", t.running == false)
end

-- Case 2: raw message with VT unavailable calls stop() mid-loop too.
do
    local t = make_terminal({
        { session = "test-1", kind = "raw", value = "" },
        { session = "test-1", kind = "key", value = "x" },
    }, { vt_ok = false })
    local ok, err = pcall(lib.process_input, t)
    check("raw-VT-unavailable mid-loop stop", ok, tostring(err))
end

-- Case 3: normal key processing still drains the queue without stopping.
do
    local t = make_terminal({
        { session = "test-1", kind = "key", value = "a" },
        { session = "test-1", kind = "key", value = "b" },
    })
    local ok, err = pcall(lib.process_input, t)
    check("normal processing ok", ok, tostring(err))
    check("  queue drained", #t.input_channel == 0)
end

if failures > 0 then
    print(failures .. " test(s) failed")
    os.exit(1)
end
print("all tests passed")
