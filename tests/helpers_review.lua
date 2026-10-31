local helpers = dofile('tests/helpers.lua')

--- Drive the review tab from tests: the functions take the child Neovim.
---@class IterTestReviewHelpers
local M = {}

--- The open review, as an expression for the child.
M.R = [[require('iter').current_review]]

--- The window of the review's file list, as an expression for the child.
M.LIST_WIN = M.R .. [[.drawer.win]]

--- Run `:Iter review` (or `command`) and wait for the file list.
---@param child table MiniTest child Neovim
---@param command? string
function M.open(child, command)
    child.cmd(command or 'Iter review')
    helpers.wait_until(
        child,
        M.R .. [[ ~= nil and ]] .. M.LIST_WIN .. [[ ~= nil]]
    )
end

--- Wait until the review's diff window shows `expected` (`side path`).
---@param child table MiniTest child Neovim
---@param expected string
function M.wait_diff(child, expected)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local r = %s
                local f = r and r.view.files[1]
                return f ~= nil and f.side .. ' ' .. f.path == %q
                    and r.view:is_shown()
            end)()]],
            M.R,
            expected
        )
    )
end

--- Select the `side` item with `path` in the file list. Focus stays.
---@param child table MiniTest child Neovim
---@param side string
---@param path string
function M.select(child, side, path)
    child.lua([[
        local side, path = ...
        local d = ]] .. M.R .. [[.drawer
        for lnum, row in ipairs(d.rows) do
            if row[side] ~= nil and row[side].path == path then
                vim.api.nvim_win_set_cursor(d.win, { lnum, 0 })
                d:select(lnum, side)
                return
            end
        end
        error('no row for ' .. side .. ' ' .. path)
    ]], { side, path })
end

--- The selected file of the list as `side path`, nil without one.
---@param child table MiniTest child Neovim
---@return string?
function M.selected(child)
    return child.lua_get([[(function()
        local item = ]] .. M.R .. [[.drawer:selected()
        return item and (item.side .. ' ' .. item.path) or vim.NIL
    end)()]])
end

--- Focus the file list.
---@param child table MiniTest child Neovim
function M.focus_list(child)
    child.lua([[vim.api.nvim_set_current_win(]] .. M.LIST_WIN .. [[)]])
end

return M
