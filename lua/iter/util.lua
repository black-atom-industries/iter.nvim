local M = {}

---@param win integer?
---@return boolean
function M.is_valid_win(win)
    return type(win) == 'number' and win > 0 and vim.api.nvim_win_is_valid(win)
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

return M
