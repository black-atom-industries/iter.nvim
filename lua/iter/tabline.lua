--- A 'tabline' like Neovim's default one, for `%!v:lua.require'iter'.tabline()`.
--- A tab with an `iter_label` tab variable shows that label; any other shows
--- its current window's buffer name, shortened, and the window the status
--- sidebar shows the diff in while the sidebar is the current one. The
--- window count leaves out floats and the status sidebar.

local uri = require('iter.uri')
local util = require('iter.util')

local M = {}

---@param tab integer
---@param status? IterStatus the status sidebar open in `tab`
---@return string
local function label(tab, status)
    local ok, value = pcall(vim.api.nvim_tabpage_get_var, tab, 'iter_label')

    if ok and type(value) == 'string' and value ~= '' then
        return value
    end

    local win = vim.api.nvim_tabpage_get_win(tab)

    if
        status ~= nil
        and win == status.panel.win
        and util.is_valid_win(status.pane)
    then
        win = status.pane
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    local target = name ~= uri.of('status') and uri.parse(name) or nil

    if target ~= nil and target.kind == 'status' then
        return target.path and vim.fn.pathshorten(target.path) or 'status'
    end

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
    local open = require('iter').drawer --[[@as IterStatus?]]

    if open == nil or open.panel == nil or not open:is_open() then
        open = nil
    end

    for number, tab in ipairs(tabs) do
        local hl = tab == current and '%#TabLineSel#' or '%#TabLine#'
        local count, modified = 0, false
        local status = open ~= nil and open.tab == tab and open or nil

        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if
                vim.api.nvim_win_get_config(win).relative == ''
                and not (status ~= nil and win == status.panel.win)
            then
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

        table.insert(parts, (label(tab, status):gsub('%%', '%%%%')) .. ' ')
    end

    table.insert(parts, '%#TabLineFill#%T')

    if #tabs > 1 then
        table.insert(parts, '%=%#TabLine#%999XX')
    end

    return table.concat(parts)
end

return M
