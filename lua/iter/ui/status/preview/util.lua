local M = {}

---@param text string
---@return string
function M.winbar_text(text)
    return (text:gsub('%%', '%%%%'))
end

return M
