--- A 'statuscolumn' that draws the annotation bar on every screen row of a
--- wrapped annotated line, where a sign shows on the first row only.

local M = {}

---@class IterBarCache
---@field tick integer changedtick the bars were read at
---@field bars table<integer, string> sign highlight group by line

---@type table<integer, IterBarCache>
local cache = {}

--- Forget the bars of `buf`; the next row reads them again.
---@param buf integer
function M.invalidate(buf)
    cache[buf] = nil
end

--- The bars of `buf`: read once per render and per text change, since the
--- signs move with edits.
---@param buf integer
---@return table<integer, string>
local function bars_of(buf)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local entry = cache[buf]

    if entry ~= nil and entry.tick == tick then
        return entry.bars
    end

    local bars = require('iter.annotations.marks').signs(buf)

    if next(bars) ~= nil then
        cache[buf] = { tick = tick, bars = bars }
    end

    return bars
end

--- What the default columns show, and on a wrapped row of an annotated line
--- the bar in place of the blank signs. The number column's trailing space
--- is there only when the window shows numbers.
---@return string
function M.get()
    local win = vim.g.statusline_winid
    local numbers = vim.wo[win].number or vim.wo[win].relativenumber
    local tail = numbers and '%=%l ' or ''

    if vim.v.virtnum <= 0 then
        return '%C%s' .. tail
    end

    tail = numbers and '%= ' or ''

    local group = bars_of(vim.api.nvim_win_get_buf(win))[vim.v.lnum]

    if group == nil then
        return '%C%s' .. tail
    end

    local width = vim.api.nvim_eval_statusline('%s', {
        winid = win,
        use_statuscol_lnum = vim.v.lnum,
    }).width

    if width == 0 then
        return '%C%s' .. tail
    end

    return string.format(
        '%%C%%#%s#%s%%*%s%s',
        group,
        require('iter.annotations.marks').SIGN,
        string.rep(' ', width - 1),
        tail
    )
end

return M
