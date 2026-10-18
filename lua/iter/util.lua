local M = {}

---@param win integer?
---@return boolean
function M.is_valid_win(win)
    return type(win) == 'number' and win > 0 and vim.api.nvim_win_is_valid(win)
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
