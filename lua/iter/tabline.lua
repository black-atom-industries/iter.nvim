--- A 'tabline' like Neovim's default one, for `%!v:lua.require'iter'.tabline()`.
--- A tab with an `iter_label` tab variable shows that label; any other shows
--- its current window's buffer name, shortened. The window count leaves out
--- floats.

local M = {}

---@param tab integer
---@return string
local function label(tab)
    local ok, value = pcall(vim.api.nvim_tabpage_get_var, tab, 'iter_label')

    if ok and type(value) == 'string' and value ~= '' then
        return value
    end

    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))
    local name = vim.api.nvim_buf_get_name(buf)

    if name == '' then
        return vim.bo[buf].buftype == 'nofile' and '[Scratch]' or '[No Name]'
    end

    return vim.fn.pathshorten(vim.fn.fnamemodify(name, ':~:.'))
end

---@return string
function M.render()
    local current = vim.api.nvim_get_current_tabpage()
    local tabs = vim.api.nvim_list_tabpages()
    local parts = {}

    for number, tab in ipairs(tabs) do
        local hl = tab == current and '%#TabLineSel#' or '%#TabLine#'
        local count, modified = 0, false

        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if vim.api.nvim_win_get_config(win).relative == '' then
                count = count + 1
                modified = modified
                    or vim.bo[vim.api.nvim_win_get_buf(win)].modified
            end
        end

        local flags = (count > 1 and tostring(count) or '')
            .. (modified and '+' or '')

        table.insert(parts, hl .. '%' .. number .. 'T ')

        if flags ~= '' then
            table.insert(parts, '%#Title#' .. flags .. hl .. ' ')
        end

        table.insert(parts, (label(tab):gsub('%%', '%%%%')) .. ' ')
    end

    table.insert(parts, '%#TabLineFill#%T')

    if #tabs > 1 then
        table.insert(parts, '%=%#TabLine#%999XX')
    end

    return table.concat(parts)
end

return M
