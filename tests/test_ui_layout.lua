local layout = require('iter.ui.layout')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local T = new_set()

---@param path string
---@param side? string
---@param code? string
---@return IterChange
local function change(path, side, code)
    return { path = path, side = side or 'unstaged', code = code or 'M' }
end

--- A column of plain cells: the item's name padded to the width.
---@param id string
---@param title string
---@param items any[]
---@param weight? number
---@return IterLayoutColumn
local function column(id, title, items, weight)
    return {
        id = id,
        title = title,
        items = items,
        weight = weight,
        cell = function(_, item, _, width)
            return item .. string.rep(' ', width - #item)
        end,
    }
end

---@param line IterRenderLine
---@param group string
---@return [integer, integer][]
local function spans(line, group)
    local result = {}

    for _, span in ipairs(line.highlights) do
        if span.group == group then
            table.insert(result, { span.start_col, span.end_col })
        end
    end

    return result
end

T['mode()'] = function()
    eq(layout.mode(80, 80), 'columns')
    eq(layout.mode(120, 80), 'columns')
    eq(layout.mode(79, 80), 'stacked')
end

T['widths()'] = new_set()

T['widths()']['two equal columns split around the separator'] = function()
    eq(layout.widths(80, { 1, 1 }), { 39, 40 })
    eq(layout.widths(81, { 1, 1 }), { 40, 40 })
end

T['widths()']['N columns by weight, the last takes the rest'] = function()
    eq(layout.widths(100, { 1, 1, 1 }), { 32, 32, 34 })
    eq(layout.widths(61, { 2, 1 }), { 40, 20 })
    eq(layout.widths(40, { 1 }), { 40 })
end

T['columns()'] = new_set()

T['columns()']['lays titles and items side by side'] = function()
    local result = layout.columns({
        column('left', 'Left', { 'a', 'b' }),
        column('right', 'Right', { 'c' }),
    }, 21)

    eq(
        vim.tbl_map(function(line)
            return line.text
        end, result.lines),
        {
            ' Left (2) │ Right (1)',
            'a         │c         ',
            'b         │          ',
        }
    )
    eq(result.rows, { {}, { left = 'a', right = 'c' }, { left = 'b' } })
end

T['columns()']['cells and the separator sit at byte columns'] = function()
    local result = layout.columns({
        column('left', 'Left', { 'a' }),
        column('right', 'Right', { 'c' }),
    }, 21)

    eq(result.cells[1], {})
    eq(result.cells[2], {
        left = { first = 0, last = 10 },
        right = { first = 13, last = 23 },
    })
    eq(spans(result.lines[2], 'WinSeparator'), { { 10, 13 } })
    eq(spans(result.lines[1], 'IterDrawerTitle'), { { 0, 9 }, { 13, 23 } })
end

T['columns()']['takes any number of columns'] = function()
    local result = layout.columns({
        column('a', 'A', { 'x' }),
        column('b', 'B', {}),
        column('c', 'C', { 'y', 'z' }),
    }, 20)

    eq(#result.lines, 3)
    eq(result.rows[2], { a = 'x', c = 'y' })
    eq(result.rows[3], { c = 'z' })
    eq(#spans(result.lines[2], 'WinSeparator'), 2)
    eq(vim.fn.strdisplaywidth(result.lines[2].text), 20)
end

T['stacked()'] = function()
    local result = layout.stacked({
        column('left', 'Left', { 'a' }),
        column('right', 'Right', { 'c', 'd' }),
    }, 12)

    eq(
        vim.tbl_map(function(line)
            return line.text
        end, result.lines),
        {
            ' Left (1)   ',
            'a           ',
            '',
            ' Right (2)  ',
            'c           ',
            'd           ',
        }
    )
    eq(
        result.rows,
        { {}, { left = 'a' }, {}, {}, { right = 'c' }, { right = 'd' } }
    )
    eq(result.cells[5], { right = { first = 0, last = 12 } })
end

T['message()'] = function()
    local result = layout.message('Working tree clean')

    eq(result.lines[1].text, ' Working tree clean')
    eq(spans(result.lines[1], 'IterDrawerHint'), { { 0, 19 } })
    eq(result.rows, { {} })
    eq(result.cells, { {} })
end

T['file_cell()'] = new_set()

T['file_cell()']['code letter and path, padded to the width'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.file_cell(line, change('a.txt'), 4, 12)

    eq(text, ' M a.txt    ')
    eq(spans(line, 'IterUnstage'), { { 5, 6 } })
end

T['file_cell()']['cuts the path from the left'] = function()
    local line = { text = '', highlights = {} }

    eq(
        layout.file_cell(line, change('dir/long.txt', 'staged'), 0, 10),
        ' M …ng.txt'
    )
    eq(spans(line, 'IterStage'), { { 1, 2 } })
end

T['file_cell()']['colors untracked and conflicted codes'] = function()
    local line = { text = '', highlights = {} }

    layout.file_cell(line, change('u', 'unstaged', '?'), 0, 8)
    layout.file_cell(line, change('c', 'unstaged', 'U'), 0, 8)

    eq(spans(line, 'IterUntracked'), { { 1, 2 } })
    eq(spans(line, 'IterConflict'), { { 1, 2 } })
end

T['file_cell()']['a decor adds the mark slot and the count'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.file_cell(
        line,
        change('a.txt'),
        0,
        16,
        { mark = { '✓', 'IterViewed' }, count = 2 }
    )

    eq(text, ' M ✓ a.txt  [2] ')
    eq(vim.fn.strdisplaywidth(text), 16)
    eq(spans(line, 'IterViewed'), { { 3, 6 } })
    eq(spans(line, 'IterDrawerCount'), { { #text - 5, #text } })
end

T['file_cell()']['a decor without a mark keeps a blank slot'] = function()
    local line = { text = '', highlights = {} }

    eq(layout.file_cell(line, change('a.txt'), 0, 12, {}), ' M   a.txt  ')
end

T['hints()'] = new_set()

local ENTRIES = {
    { action = 'stage', lhs = { 's' } },
    { action = 'open', lhs = { '<CR>' } },
    { action = 'help', lhs = { 'g?' } },
}
local ACTIONS = {
    { 'stage', 'stage' },
    { 'discard', 'discard' },
    { 'open', 'open' },
    { 'help', 'help' },
}

---@param chunks [string, string][]
---@return string
local function joined(chunks)
    return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
    end, chunks))
end

T['hints()']['lists the bound actions in order'] = function()
    local chunks = layout.hints(ENTRIES, ACTIONS, 80)

    eq(joined(chunks), 's stage  <CR> open  g? help')
    eq(chunks[1], { 's', 'IterDrawerKey' })
    eq(chunks[2], { ' stage  ', 'IterDrawerHint' })
end

T['hints()']['drops hints before the last until they fit'] = function()
    eq(joined(layout.hints(ENTRIES, ACTIONS, 20)), 's stage  g? help')
    eq(joined(layout.hints(ENTRIES, ACTIONS, 3)), 'g? help')
end

return T
