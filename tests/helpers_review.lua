local helpers = dofile('tests/helpers.lua')

--- Drive the review tab from tests: the functions take the child Neovim.
---@class IterTestReviewHelpers
local M = {}

--- The open review, as an expression for the child.
M.R = [[require('iter').current_review]]

--- The window of the review's file tree, as an expression for the child.
M.LIST_WIN = M.R .. [[.panel.win]]

--- Run `:Iter review` (or `command`) and wait for the file tree.
---@param child table MiniTest child Neovim
---@param command? string
function M.open(child, command)
    child.cmd(command or 'Iter review')
    helpers.wait_until(
        child,
        M.R .. [[ ~= nil and ]] .. M.R .. [[.panel ~= nil]]
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

--- Put the tree's cursor on the file at `path` and show its diff; `side`
--- is ignored, a tree row is a path. Focus stays.
---@param child table MiniTest child Neovim
---@param _ string
---@param path string
function M.select(child, _, path)
    child.lua([[
        local path = ...
        local r = ]] .. M.R .. [[

        if not r:select_path(path) then
            error('no row for ' .. path)
        end

        r:show_selection(false)
    ]], { path })
end

--- The path of the tree's file under the cursor, nil on a directory or
--- without files.
---@param child table MiniTest child Neovim
---@return string?
function M.selected(child)
    return child.lua_get([[(function()
        local file = ]] .. M.R .. [[.tree:file()
        return file and file.path or vim.NIL
    end)()]])
end

--- Focus the file tree.
---@param child table MiniTest child Neovim
function M.focus_list(child)
    child.lua([[vim.api.nvim_set_current_win(]] .. M.LIST_WIN .. [[)]])
end

return M
