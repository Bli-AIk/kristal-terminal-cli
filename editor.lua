-- Line editor: buffer/cursor/history and key handling.

return function(lib)
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
        local content = love.filesystem.read(self.HISTORY_FILE)
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
            table.insert(self.scrollback, self.PROMPT .. self:highlight_lua(text))
            table.insert(self.history, text)
            while #self.history > self.HISTORY_MAX do
                table.remove(self.history, 1)
            end
            love.filesystem.write(self.HISTORY_FILE, table.concat(self.history, "\n") .. "\n")

            self._remote_depth = (self._remote_depth or 0) + 1
            self._in_error_scope = false
            local ok, err = pcall(function()
                Kristal.Console:run({ text })
            end)
            self._remote_depth = self._remote_depth - 1
            if self._in_error_scope then
                -- the command failed: mark the committed line pale red
                self.scrollback[#self.scrollback] = "\27[38;5;210m" .. self.scrollback[#self.scrollback] .. "\27[0m"
            end
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
end
