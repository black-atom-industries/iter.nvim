local M = {}

---@param win integer?
---@return boolean
function M.is_valid_win(win)
    return type(win) == 'number' and win > 0 and vim.api.nvim_win_is_valid(win)
end

--- A valid window that is not a float.
---@param win integer?
---@return boolean
function M.is_normal_win(win)
    return M.is_valid_win(win)
        and vim.api.nvim_win_get_config(win --[[@as integer]]).relative
            == ''
end

--- A key that changes whenever the file at `path` is written: mtime, ctime,
--- inode and size. A write through a rename changes the inode even within
--- one mtime tick.
---@param path string
---@return string? stat nil when the file is missing
function M.stat_key(path)
    local stat = vim.uv.fs_stat(path)

    if stat == nil then
        return nil
    end

    return string.format(
        '%d.%d:%d.%d:%d:%d',
        stat.mtime.sec,
        stat.mtime.nsec,
        stat.ctime.sec,
        stat.ctime.nsec,
        stat.ino,
        stat.size
    )
end

--- Name `buf` `name`, or `name/<buf>` when another buffer has that name.
--- The name only labels the buffer; nothing writes it.
---@param buf integer
---@param name string
function M.name_buf(buf, name)
    if vim.fn.bufexists(name) == 1 then
        name = name .. '/' .. buf
    end

    vim.api.nvim_buf_set_name(buf, name)
end

---@param message string
---@param level integer
function M.notify(message, level)
    vim.notify('[iter] ' .. message, level)
end

--- Fire the `User` autocmd `pattern` with `data`.
---@param pattern string
---@param data table
function M.emit(pattern, data)
    vim.api.nvim_exec_autocmds(
        'User',
        { pattern = pattern, data = data, modeline = false }
    )
end

---@param message string
function M.warn(message)
    M.notify(message, vim.log.levels.WARN)
end

---@param message string?
---@param fallback string
function M.error(message, fallback)
    if message == nil or message == '' then
        message = fallback
    end

    M.notify(message, vim.log.levels.ERROR)
end

--- With 'nohidden' a modified buffer can't leave its window (E37). False,
--- with a warning, when `buf` is such a buffer and `path` is not its file.
---@param buf? integer
---@param path? string file the window would switch to
---@return boolean
function M.can_leave(buf, path)
    if
        not vim.o.hidden
        and buf ~= nil
        and vim.api.nvim_buf_is_valid(buf)
        and vim.bo[buf].modified
        and vim.api.nvim_buf_get_name(buf) ~= path
    then
        M.warn('The pane has unsaved changes')
        return false
    end

    return true
end

--- Edit `path`, an absolute file path, in the current window, at `line`
--- when given. When the window already shows `path` only the cursor moves,
--- so a modified buffer stays as it is.
---@param path string
---@param line? integer
---@param name? string what the error names, the basename by default
---@return boolean ok
function M.edit_at(path, line, name)
    local current = vim.api.nvim_buf_get_name(0)
    local shown = current ~= ''
        and vim.fn.resolve(current) == vim.fn.resolve(path)
    local ok, err = true, nil

    if not shown then
        ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    end

    if not ok then
        M.error(
            tostring(err),
            'Cannot open ' .. (name or vim.fs.basename(path))
        )
        return false
    end

    if line ~= nil then
        vim.api.nvim_win_set_cursor(
            0,
            { math.max(1, math.min(line, vim.api.nvim_buf_line_count(0))), 0 }
        )
    end

    return true
end

return M
