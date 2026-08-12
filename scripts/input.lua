local channel_name, control_name, session_id = ...
local channel = love.thread.getChannel(channel_name)
local control = love.thread.getChannel(control_name)

local function send(kind, value)
    channel:push({
        kind = kind,
        session = session_id,
        value = value
    })
end

local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then
    send("status", "ffi_unavailable")
    return
end

if ffi.os == "Windows" then
    send("status", "unsupported_platform")
    return
end

ffi.cdef[[
    typedef struct pollfd {
        int fd;
        short events;
        short revents;
    } pollfd;

    int poll(pollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buffer, unsigned long count);
    int isatty(int fd);
    int tcgetattr(int fd, void *termios_p);
    int tcsetattr(int fd, int optional_actions, const void *termios_p);
    void cfmakeraw(void *termios_p);
]]

-- raw mode: disable kernel echo/line editing; restore on exit
local raw_mode = false
local restore_termios

if ffi.C.isatty(0) == 1 then
    local saved = ffi.new("char[128]")
    if ffi.C.tcgetattr(0, saved) == 0 then
        local raw = ffi.new("char[128]")
        ffi.copy(raw, saved, 128)
        ffi.C.cfmakeraw(raw)
        if ffi.C.tcsetattr(0, 0, raw) == 0 then
            raw_mode = true
            restore_termios = function()
                ffi.C.tcsetattr(0, 0, saved)
            end
            send("raw", true)
        else
            send("status", "tcsetattr_error")
            return
        end
    else
        send("status", "tcgetattr_error")
        return
    end
end
if not raw_mode then
    send("plain", true)
end

-- ===== key parsing =====
local esc = ""        -- pending escape sequence
local utf8_buf = ""   -- pending utf-8 character bytes
local utf8_need = 0   -- remaining utf-8 continuation bytes

local POLLIN = 0x001
local buffer = ffi.new("char[4096]")
local pending = ""
local poll_target = ffi.new("pollfd[1]")
poll_target[0].fd = 0
poll_target[0].events = POLLIN

local function emit(value)
    send("key", value)
end

local function handle_byte(b)
    if utf8_need > 0 then
        if (b & 0xC0) == 0x80 then
            utf8_buf = utf8_buf .. string.char(b)
            utf8_need = utf8_need - 1
            if utf8_need == 0 then
                emit(utf8_buf)
                utf8_buf = ""
            end
            return
        end
        utf8_need = 0
        utf8_buf = ""
    end

    if b == 0x1b then
        esc = "\27"
        return
    end
    if esc ~= "" then
        esc = esc .. string.char(b)
        if #esc == 2 then
            if b == 0x5B or b == 0x4F then
                return -- '[' / 'O': keep collecting
            end
            esc = "" -- unknown sequence
            return
        end
        if b >= 0x40 and b <= 0x7E then
            local seq = esc:sub(2)
            esc = ""
            if seq == "[A" then emit("up")
            elseif seq == "[B" then emit("down")
            elseif seq == "[C" then emit("right")
            elseif seq == "[D" then emit("left")
            elseif seq == "[H" or seq == "[1~" or seq == "[7~" then emit("home")
            elseif seq == "[F" or seq == "[4~" or seq == "[8~" then emit("end")
            elseif seq == "[3~" then emit("delete")
            elseif seq == "OH" then emit("home")
            elseif seq == "OF" then emit("end")
            end
        end
        return
    end

    if b == 0x0d or b == 0x0a then
        emit("enter")
    elseif b == 0x03 then
        emit("ctrl_c")
    elseif b == 0x04 then
        emit("ctrl_d")
    elseif b == 0x08 or b == 0x7f then
        emit("backspace")
    elseif b == 0x09 then
        emit("tab")
    elseif b >= 0x20 and b < 0x80 then
        emit(string.char(b))
    elseif b >= 0x80 then
        if b >= 0xF0 then
            utf8_need = 3
        elseif b >= 0xE0 then
            utf8_need = 2
        else
            utf8_need = 1
        end
        utf8_buf = string.char(b)
    end
end

local function parse_chunk(chunk)
    for i = 1, #chunk do
        handle_byte(chunk:byte(i))
    end
end

local ok, err = pcall(function()
    while true do
        if control:pop() then
            break
        end

        local ready = ffi.C.poll(poll_target, 1, 50)
        if ready < 0 then
            send("status", "poll_error")
            break
        elseif ready > 0 then
            local count = ffi.C.read(0, buffer, 4096)
            if count <= 0 then
                if not raw_mode and pending ~= "" then
                    send("command", pending)
                end
                send("status", "eof")
                break
            end

            local chunk = ffi.string(buffer, count)
            if raw_mode then
                parse_chunk(chunk)
            else
                pending = pending .. chunk
                while true do
                    local nl = pending:find("\n", 1, true)
                    if not nl then
                        break
                    end
                    local line = pending:sub(1, nl - 1)
                    pending = pending:sub(nl + 1)
                    if line:sub(-1) == "\r" then
                        line = line:sub(1, -2)
                    end
                    send("command", line)
                end
            end
        end
    end
end)

if restore_termios then
    restore_termios()
end
if not ok then
    send("status", "stdin_error: " .. tostring(err))
end
