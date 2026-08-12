-- TUI rendering: split-view layout, terminal size, Windows VT setup.

return function(lib)
    function lib:enable_windows_vt()
        local ok, ffi = pcall(require, "ffi")
        if not ok or ffi.os ~= "Windows" then
            return true
        end
        local ok2, result = pcall(function()
            ffi.cdef[[
                typedef void *HANDLE;
                typedef unsigned long DWORD;
                HANDLE GetStdHandle(int nStdHandle);
                int GetConsoleMode(HANDLE hConsoleHandle, DWORD *lpMode);
                int SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
            ]]
            local h = ffi.C.GetStdHandle(-11) -- STD_OUTPUT_HANDLE
            local mode = ffi.new("unsigned long[1]")
            if ffi.C.GetConsoleMode(h, mode) == 0 then
                return false
            end
            return ffi.C.SetConsoleMode(h, bit.bor(mode[0], 0x0004)) ~= 0
        end)
        return ok2 and result
    end

    function lib:terminal_rows()
        local ok, ffi = pcall(require, "ffi")
        if not ok then
            return nil
        end
        if ffi.os == "Windows" then
            -- console window height via GetConsoleScreenBufferInfo
            local ok2, rows = pcall(function()
                ffi.cdef[[
                    typedef void *HANDLE;
                    typedef unsigned long DWORD;
                    typedef short SHORT;
                    typedef struct _COORD { SHORT X; SHORT Y; } COORD;
                    typedef struct _SMALL_RECT { SHORT Left; SHORT Top; SHORT Right; SHORT Bottom; } SMALL_RECT;
                    typedef struct _CONSOLE_SCREEN_BUFFER_INFO {
                        COORD dwSize;
                        COORD dwCursorPosition;
                        SHORT wAttributes;
                        SMALL_RECT srWindow;
                        COORD dwMaximumWindowSize;
                    } CONSOLE_SCREEN_BUFFER_INFO;
                    HANDLE GetStdHandle(int nStdHandle);
                    int GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO *lpConsoleScreenBufferInfo);
                ]]
                local h = ffi.C.GetStdHandle(-11) -- STD_OUTPUT_HANDLE
                local info = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
                if ffi.C.GetConsoleScreenBufferInfo(h, info) == 0 then
                    return nil
                end
                local rows = info.srWindow.Bottom - info.srWindow.Top + 1
                if rows > 0 then
                    return rows
                end
                return nil
            end)
            return ok2 and rows or nil
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
        parts[#parts + 1] = "\27[" .. rows .. ";1H" .. "\r\27[K" .. self.PROMPT .. self:highlight_lua(self.buffer)
        parts[#parts + 1] = "\27[" .. (self:cursor_column() + #self.PROMPT + 1) .. "G"
        self:write_raw(table.concat(parts))
    end
end
