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
]]

local POLLIN = 0x001
local buffer = ffi.new("char[4096]")
local pending = ""
local poll_target = ffi.new("pollfd[1]")
poll_target[0].fd = 0
poll_target[0].events = POLLIN

local function flush_lines()
    while true do
        local newline = pending:find("\n", 1, true)
        if not newline then
            return
        end

        local line = pending:sub(1, newline - 1)
        pending = pending:sub(newline + 1)

        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end

        send("command", line)
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
                if pending ~= "" then
                    send("command", pending)
                end
                send("status", "eof")
                break
            end

            pending = pending .. ffi.string(buffer, count)
            flush_lines()
        end
    end
end)

if not ok then
    send("status", "stdin_error: " .. tostring(err))
end
