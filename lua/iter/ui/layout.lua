--- The drawer's lines from its columns and the width: titled columns side by
--- side above the breakpoint, stacked sections below it, cells cut to fit.
--- Pure: it builds render lines and touches no window or buffer.

local changes = require('iter.changes')
local render = require('iter.ui.render')

---@alias IterLayoutMode 'columns'|'stacked'

---@class IterLayoutColumn one list of the drawer
---@field id string key of the column's items in a row
---@field title string
---@field items any[]
---@field weight? number share of the width among the columns, 1 by default
---@field cell fun(line: IterRenderLine, item: any, first: integer, width: integer): string text of one item's cell, `width` cells wide, highlights added at byte column `first`

---@class IterLayoutCell byte columns of one cell on its line
---@field first integer
---@field last integer

---@class IterLayout
---@field lines IterRenderLine[]
---@field rows table<string, any>[] per line, the item of each column id on it
---@field cells table<string, IterLayoutCell>[] per line, the cell of each item

---@class IterLayoutDecor what a file row shows besides its code and path
---@field mark? [string, string] glyph and group after the code letter
---@field count? integer shown as `[n]` at the end of the cell above 0

local M = {}

M.SEPARATOR = '│'

---@param text string
---@param width integer
---@return string
local function pad(text, width)
    return text .. string.rep(' ', width - vim.fn.strdisplaywidth(text))
end

---@param item IterChange
---@return string
local function code_group(item)
    if item.code == '?' then
        return 'IterUntracked'
    elseif item.code == 'U' then
        return 'IterConflict'
    end

    return item.side == 'staged' and 'IterStage' or 'IterUnstage'
end

---@param chunks [string, string][]
---@return integer
local function chunks_width(chunks)
    local width = 0

    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
    end

    return width
end

---@param line IterRenderLine
---@param column IterLayoutColumn
---@param first integer
---@param width integer
---@return string
local function title_text(line, column, first, width)
    local text = string.format(' %s (%d)', column.title, #column.items)
    render.add_highlight(line, 'IterDrawerTitle', first, first + #text)

    return pad(text, width)
end

--- Columns side by side at `width` and wider, stacked below it.
---@param width integer
---@param breakpoint integer
---@return IterLayoutMode
function M.mode(width, breakpoint)
    return width >= breakpoint and 'columns' or 'stacked'
end

--- The display width of each column side by side in `width`, separators
--- left out: shares by weight, rounded down, the last column taking the
--- rest.
---@param width integer
---@param weights number[]
---@return integer[]
function M.widths(width, weights)
    local free = width - (#weights - 1) * vim.fn.strdisplaywidth(M.SEPARATOR)
    local total = 0

    for _, weight in ipairs(weights) do
        total = total + weight
    end

    local widths, used = {}, 0

    for i, weight in ipairs(weights) do
        if i == #weights then
            widths[i] = free - used
        else
            widths[i] = math.floor(free * weight / total)
            used = used + widths[i]
        end
    end

    return widths
end

--- The columns side by side, a title line on top and one item per line
--- below, separated by `SEPARATOR`.
---@param columns IterLayoutColumn[]
---@param width integer
---@return IterLayout
function M.columns(columns, width)
    local widths = M.widths(
        width,
        vim.tbl_map(function(column)
            return column.weight or 1
        end, columns)
    )
    local result = { lines = {}, rows = {}, cells = {} }
    local height = 0

    for _, column in ipairs(columns) do
        height = math.max(height, #column.items)
    end

    for index = 0, height do
        local line = render.line('')
        local row, cells, parts = {}, {}, {}
        local first = 0

        for i, column in ipairs(columns) do
            local text
            local item = column.items[index]

            if index == 0 then
                text = title_text(line, column, first, widths[i])
            elseif item ~= nil then
                text = column.cell(line, item, first, widths[i])
                row[column.id] = item
                cells[column.id] = { first = first, last = first + #text }
            else
                text = string.rep(' ', widths[i])
            end

            table.insert(parts, text)
            first = first + #text

            if i < #columns then
                table.insert(parts, M.SEPARATOR)
                render.add_highlight(
                    line,
                    'WinSeparator',
                    first,
                    first + #M.SEPARATOR
                )
                first = first + #M.SEPARATOR
            end
        end

        line.text = table.concat(parts)
        table.insert(result.lines, line)
        table.insert(result.rows, row)
        table.insert(result.cells, cells)
    end

    return result
end

--- The columns one below the other, each the full `width`: a title line,
--- its items, and a blank line before the next title.
---@param columns IterLayoutColumn[]
---@param width integer
---@return IterLayout
function M.stacked(columns, width)
    local result = { lines = {}, rows = {}, cells = {} }

    for i, column in ipairs(columns) do
        if i > 1 then
            table.insert(result.lines, render.line(''))
            table.insert(result.rows, {})
            table.insert(result.cells, {})
        end

        local title = render.line('')
        title.text = title_text(title, column, 0, width)
        table.insert(result.lines, title)
        table.insert(result.rows, {})
        table.insert(result.cells, {})

        for _, item in ipairs(column.items) do
            local line = render.line('')
            line.text = column.cell(line, item, 0, width)
            table.insert(result.lines, line)
            table.insert(result.rows, { [column.id] = item })
            table.insert(
                result.cells,
                { [column.id] = { first = 0, last = #line.text } }
            )
        end
    end

    return result
end

--- One hint line in place of the columns, such as when nothing changed.
---@param text string
---@return IterLayout
function M.message(text)
    local line = render.line(' ' .. text)
    render.add_highlight(line, 'IterDrawerHint', 0, #line.text)

    return { lines = { line }, rows = { {} }, cells = { {} } }
end

--- The cell of a file row: code letter and path, the path cut from the
--- left to fit. With `decor`, a mark slot follows the code letter, blank
--- without a mark, and a count above 0 ends the cell.
---@param line IterRenderLine
---@param item IterChange
---@param first integer byte column the cell starts at
---@param width integer
---@param decor? IterLayoutDecor
---@return string
function M.file_cell(line, item, first, width, decor)
    local indent = ' '
    local prefix = indent .. item.code .. ' '
    local mark = decor and decor.mark

    if decor ~= nil then
        prefix = prefix .. (mark and mark[1] or ' ') .. ' '
    end

    local count = decor and decor.count or 0
    local suffix = count > 0 and string.format(' [%d] ', count) or ''
    local text = prefix
        .. changes.truncate(
            item.path,
            width
                - vim.fn.strdisplaywidth(prefix)
                - vim.fn.strdisplaywidth(suffix)
        )

    render.add_highlight(line, code_group(item), first + #indent)

    if mark then
        local start = first + #indent + #item.code + 1

        render.add_highlight(line, mark[2], start, start + #mark[1])
    end

    if suffix == '' then
        return pad(text, width)
    end

    text = pad(text, width - #suffix)
    render.add_highlight(
        line,
        'IterDrawerCount',
        first + #text,
        first + #text + #suffix
    )

    return text .. suffix
end

--- Key hints `<lhs> <label>` for `actions`, in order, those without a bound
--- key left out, as many as fit in `width`; the last one stays.
---@param entries IterKeymapEntry[] bound keys by action
---@param actions [string, string][] action and label
---@param width integer
---@return [string, string][]
function M.hints(entries, actions, width)
    local lhs = {}

    for _, entry in ipairs(entries) do
        lhs[entry.action] = entry.lhs[1]
    end

    local items = {}

    for _, action in ipairs(actions) do
        if lhs[action[1]] ~= nil then
            table.insert(items, { lhs[action[1]], action[2] })
        end
    end

    local function build()
        ---@type [string, string][]
        local chunks = {}

        for i, item in ipairs(items) do
            table.insert(chunks, { item[1], 'IterDrawerKey' })
            table.insert(chunks, {
                ' ' .. item[2] .. (i < #items and '  ' or ''),
                'IterDrawerHint',
            })
        end

        return chunks
    end

    local chunks = build()

    while #items > 1 and chunks_width(chunks) > width do
        table.remove(items, #items - 1)
        chunks = build()
    end

    return chunks
end

return M
