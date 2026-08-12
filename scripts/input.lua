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

local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40)
    )
end

-- ===== Windows backend (msvcrt console input) =====
if ffi.os == "Windows" then
    ffi.cdef[[
        int _kbhit(void);
        int _getwch(void);
        int _isatty(int fd);
        int _read(int fd, void *buf, unsigned int count);
        void Sleep(unsigned long dwMilliseconds);
    ]]
    local msvcrt = ffi.load("msvcrt")
    local kernel32 = ffi.load("kernel32")

    local function read_key()
        -- first call: 0xE0 = extended key, 0x00 = function key
        local c = msvcrt._getwch()
        if c == 0 or c == 0xE0 then
            local scan = msvcrt._getwch()
            if c == 0xE0 then
                if scan == 0x48 then return "up"
                elseif scan == 0x50 then return "down"
                elseif scan == 0x4B then return "left"
                elseif scan == 0x4D then return "right"
                elseif scan == 0x47 then return "home"
                elseif scan == 0x4F then return "end"
                elseif scan == 0x53 then return "delete"
                end
            end
            return nil
        end
        if c == 13 or c == 10 then return "enter" -- wine delivers \n for Enter
        elseif c == 3 then return "ctrl_c"
        elseif c == 4 then return "ctrl_d"
        elseif c == 8 then return "backspace"
        elseif c == 9 then return "tab"
        elseif c == 27 then return nil
        elseif c < 32 then return nil
        end
        -- printable: UTF-16 code units, handle surrogate pairs
        if c >= 0xD800 and c <= 0xDBFF then
            local low = msvcrt._getwch()
            if low >= 0xDC00 and low <= 0xDFFF then
                c = 0x10000 + (c - 0xD800) * 0x400 + (low - 0xDC00)
            else
                return nil
            end
        elseif c >= 0xDC00 and c <= 0xDFFF then
            return nil
        end
        return utf8char(c)
    end

    if msvcrt._isatty(0) == 0 then
        -- stdin is a pipe/file: plain line mode
        send("plain", true)
        local buf = ffi.new("char[4096]")
        local pending = ""
        while true do
            if control:pop() then
                break
            end
            local n = msvcrt._read(0, buf, 4096)
            if n <= 0 then
                if pending ~= "" then
                    send("command", pending)
                end
                send("status", "eof")
                break
            end
            pending = pending .. ffi.string(buf, n)
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
        return
    end

    send("raw", true)
    while true do
        if control:pop() then
            break
        end
        if msvcrt._kbhit() ~= 0 then
            local k = read_key()
            if k then
                send("key", k)
            end
        else
            kernel32.Sleep(20)
        end
    end
    return
end

-- ===== POSIX backend =====
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
        if bit.band(b, 0xC0) == 0x80 then
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
