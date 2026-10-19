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

T['columns()']['a title shows the count and a note, cut to the width'] = function()
    local spec = column('a', 'Notes', { 'x', 'y' })
    spec.count, spec.note = 1, '2 outdated'

    local result = layout.columns({ spec }, 22)

    eq(result.lines[1].text, ' Notes (1) · 2 outdat…')
    eq(spans(result.lines[1], 'IterDrawerTitle'), { { 0, 10 } })
    eq(
        spans(result.lines[1], 'IterDrawerHint'),
        { { 10, #result.lines[1].text } }
    )
end

T['columns()']['an item that is not selectable has no row entry'] = function()
    local spec = column('a', 'A', { 'head', 'x' })
    spec.selectable = function(item)
        return item ~= 'head'
    end

    local result = layout.columns({ spec }, 10)

    eq(result.lines[2].text, 'head      ')
    eq(result.rows, { {}, {}, { a = 'x' } })
    eq(result.cells[2], {})

    local stacked = layout.stacked({ spec }, 10)

    eq(stacked.rows, { {}, {}, { a = 'x' } })
    eq(stacked.cells[2], {})
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

T['age()'] = function()
    eq(layout.age(-5), 'now')
    eq(layout.age(59), 'now')
    eq(layout.age(60), '1m')
    eq(layout.age(3599), '59m')
    eq(layout.age(2 * 3600), '2h')
    eq(layout.age(86399), '23h')
    eq(layout.age(3 * 86400), '3d')
    eq(layout.age(7 * 86400), '1w')
    eq(layout.age(5 * 7 * 86400 + 86400), '5w')
    eq(layout.age(364 * 86400), '52w')
    eq(layout.age(800 * 86400), '2y')
end

T['commits()'] = new_set()

local NOW = 1767225600

---@param recent GitRecent
---@param width integer
---@return string[]
local function commit_texts(recent, width)
    return vim.tbl_map(function(line)
        return line.text
    end, layout.commits(recent, width, NOW).lines)
end

---@param upstream? string
---@param ahead integer
---@param behind integer
---@return GitRecent
local function recent(upstream, ahead, behind)
    return {
        key = '',
        upstream = upstream,
        ahead = ahead,
        behind = behind,
        commits = {
            {
                sha = '3f2a9c1',
                subject = 'refactor(drawer): split it',
                time = NOW - 2 * 3600,
                unpushed = ahead > 0,
            },
            {
                sha = '0aa4465',
                subject = 'fix: keep',
                time = NOW - 86400,
                unpushed = false,
            },
        },
    }
end

T['commits()']['title, markers, subjects and right-aligned ages'] = function()
    eq(commit_texts(recent('origin/main', 1, 2), 40), {
        ' Recent commits · ↑1 unpushed · ↓2 behind',
        ' ↑ 3f2a9c1  refactor(drawer): split… 2h ',
        '   0aa4465  fix: keep                1d ',
    })

    local result = layout.commits(recent('origin/main', 1, 0), 40, NOW)
    eq(result.rows, { {}, {}, {} })
    eq(result.cells, { {}, {}, {} })
    eq(spans(result.lines[2], 'IterUnpushed'), { { 1, 4 }, { 5, 12 } })
    eq(spans(result.lines[3], 'IterDrawerHint'), {
        { 3, 10 },
        { 12, 36 },
        { 36, 40 },
    })
end

T['commits()']['without an upstream no markers and no counts'] = function()
    eq(commit_texts(recent(nil, 0, 0), 30), {
        ' Recent commits',
        ' 3f2a9c1  refactor(drawer… 2h ',
        ' 0aa4465  fix: keep        1d ',
    })
end

T['commits()']['empty without commits'] = function()
    local none = recent(nil, 0, 0)
    none.commits = {}

    eq(layout.commits(none, 40, NOW).lines, {})
    eq(layout.commits(nil, 40, NOW).lines, {})
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

---@param scope string
---@param a table
---@param body? string
---@return IterAnnotation
local function annotation(scope, a, body)
    return { id = 'x', scope = scope, anchor = a, body = body or 'body' }
end

T['annotation_label()'] = function()
    local line =
        { path = 'lua/a.lua', side = 'new', start_line = 4, end_line = 4 }
    local range = { path = 'a.lua', side = 'new', start_line = 4, end_line = 6 }
    local old = { path = 'a.lua', side = 'old', start_line = 8, end_line = 8 }

    eq(layout.annotation_label(annotation('line', line)), 'a.lua:4')
    eq(layout.annotation_label(annotation('line', line), 10), 'a.lua:10')
    eq(layout.annotation_label(annotation('range', range)), 'a.lua:4–6')
    eq(layout.annotation_label(annotation('range', range), 7), 'a.lua:7–9')
    eq(layout.annotation_label(annotation('line', old)), 'a.lua:8 old')
    eq(
        layout.annotation_label(annotation('file', { path = 'd/README.md' })),
        'README.md'
    )
    eq(
        layout.annotation_label(annotation('review', { side = 'new' })),
        'review'
    )
end

T['annotation_cell()'] = new_set()

T['annotation_cell()']['label padded, then the first line of the body'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.annotation_cell(line, {
        annotation = annotation('file', { path = 'a.lua' }, 'Why\tthis\nmore'),
        outdated = false,
        label = 'a.lua',
    }, 4, 20, 8)

    eq(text, ' a.lua    Why this  ')
    eq(spans(line, 'IterDrawerKey'), { { 5, 10 } })
end

T['annotation_cell()']['cuts the body and a long label with …'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.annotation_cell(line, {
        annotation = annotation('review', {}, 'A long remark here'),
        outdated = false,
        label = 'a_long_name.lua:12',
    }, 0, 16, 6)

    eq(text, ' a_lon… A long …')
    eq(vim.fn.strdisplaywidth(text), 16)
end

T['annotation_cell()']['dims an outdated row'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.annotation_cell(line, {
        annotation = annotation('review', {}, 'gone'),
        outdated = true,
        label = 'a:1',
    }, 0, 12, 3)

    eq(spans(line, 'IterDiffAnnotationOutdated'), { { 0, #text } })
    eq(spans(line, 'IterDrawerKey'), {})
end

T['progress_cell()'] = new_set()

T['progress_cell()']['bar, counts and the changed files'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.progress_cell(
        line,
        { viewed = 3, changed = 1, total = 8 },
        0,
        32
    )

    eq(text, ' viewed ■■■□□□□□ 3 of 8 · ↻ 1   ')
    eq(spans(line, 'IterViewed'), { { 8, 17 } })
    eq(
        spans(line, 'IterViewedChanged'),
        { { #' viewed ■■■□□□□□ 3 of 8', #text - 3 } }
    )
end

T['progress_cell()']['fills by share, full only when all are viewed'] = function()
    local function bar(viewed, total)
        local text = layout.progress_cell(
            { text = '', highlights = {} },
            { viewed = viewed, changed = 0, total = total },
            0,
            40
        )

        return vim.trim(text):match('[■□]+')
    end

    eq(bar(0, 0), '□□□□□□□□')
    eq(bar(0, 5), '□□□□□□□□')
    eq(bar(1, 20), '■□□□□□□□')
    eq(bar(19, 20), '■■■■■■■□')
    eq(bar(4, 4), '■■■■■■■■')
end

T['progress_cell()']['drops the word when narrow'] = function()
    local text = layout.progress_cell(
        { text = '', highlights = {} },
        { viewed = 1, changed = 1, total = 4 },
        0,
        24
    )

    eq(text, ' ■■□□□□□□ 1 of 4 · ↻ 1  ')
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
