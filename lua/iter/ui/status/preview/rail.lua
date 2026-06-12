--- Line-number rail for the stacked diff preview, mirroring the rail of
--- diffs.nvim's own `:Diff` views (change bar, old/new numbers, separator).
--- Rendered via 'statuscolumn' so the buffer keeps the raw unified diff
--- that diffs.nvim parses; colored with diffs.nvim's documented rail
--- highlight groups (:h diffs.nvim-highlights).

local parser = require('iter.ui.diff.parser')

local M = {}

local CHANGE_BAR = '▏'
local SEPARATOR = '│'

---@class IterRailRow
---@field old integer?
---@field new integer?
---@field kind 'header'|'hunk'|'context'|'added'|'removed'

---@class IterRailState
---@field rows table<integer, IterRailRow>
---@field width integer

---@type table<integer, IterRailState>
local states = {}

---@type table<integer, boolean>
local wipe_autocmds = {}

---@param value integer?
---@param width integer
---@return string
local function format_number(value, width)
    if value == nil then
        return string.rep(' ', width)
    end

    return string.format('%' .. width .. 'd', value)
end

---@param buf integer
---@param lines string[]
---@return IterRailState
local function build_state(buf, lines)
    local rows = {}
    local max_number = 0

    for _, line in ipairs(parser.parse_lines(lines)) do
        rows[line.raw_row] = {
            old = line.old_number,
            new = line.new_number,
            kind = line.kind,
        }
        max_number =
            math.max(max_number, line.old_number or 0, line.new_number or 0)
    end

    local state = {
        rows = rows,
        width = math.max(1, #tostring(max_number)),
    }

    states[buf] = state

    if not wipe_autocmds[buf] then
        wipe_autocmds[buf] = true
        vim.api.nvim_create_autocmd('BufWipeout', {
            buffer = buf,
            callback = function()
                states[buf] = nil
                wipe_autocmds[buf] = nil
            end,
        })
    end

    return state
end

--- Build rail data for the buffer and point the window's statuscolumn at
--- M.statuscolumn(). Call after the buffer content was (re)written.
---@param win integer
---@param buf integer
---@param lines string[]
function M.set(win, buf, lines)
    build_state(buf, lines)
    vim.wo[win].statuscolumn =
        "%!v:lua.require'iter.ui.status.preview.rail'.statuscolumn()"
end

--- Evaluated by Neovim for every rendered line ('statusline' semantics:
--- g:statusline_winid is the target window, v:lnum the buffer line).
---@return string
function M.statuscolumn()
    local win = vim.g.statusline_winid
    local buf = vim.api.nvim_win_get_buf(win)
    local state = states[buf]

    if state == nil then
        return ''
    end

    local row = state.rows[vim.v.lnum]
    local kind = row ~= nil and row.kind or nil
    local blank = string.rep(' ', state.width)

    local bar = '  '
    if kind == 'added' then
        bar = '%#DiffsAddBar#' .. CHANGE_BAR .. ' '
    elseif kind == 'removed' then
        bar = '%#DiffsDeleteBar#' .. CHANGE_BAR .. ' '
    end

    local old = '%#DiffsRail#' .. blank
    local new = '%#DiffsRail#' .. blank

    if kind == 'removed' then
        old = '%#DiffsDeleteRailNr#' .. format_number(row.old, state.width)
    elseif kind == 'added' then
        new = '%#DiffsAddRailNr#' .. format_number(row.new, state.width)
    elseif kind == 'context' then
        old = '%#DiffsRailNr#' .. format_number(row.old, state.width)
        new = '%#DiffsRailNr#' .. format_number(row.new, state.width)
    end

    return bar
        .. old
        .. '%#DiffsRail# '
        .. new
        .. '%#DiffsRail# '
        .. SEPARATOR
        .. ' '
end

return M
