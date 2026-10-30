local layout = require('iter.ui.layout')
local render = require('iter.ui.render')

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

T['columns()']['a stack lays its sections below each other in one column'] = function()
    local result = layout.columns({
        {
            weight = 2,
            sections = {
                column('left', 'Left', { 'a', 'b' }),
                column('mid', 'Mid', { 'c' }),
            },
        },
        column('right', 'Right', { 'x' }),
    }, 31)

    eq(
        vim.tbl_map(function(line)
            return line.text
        end, result.lines),
        {
            ' Left (2)           │ Right (1)',
            'a                   │x         ',
            'b                   │          ',
            '                    │          ',
            ' Mid (1)            │          ',
            'c                   │          ',
        }
    )
    eq(result.rows, {
        {},
        { left = 'a', right = 'x' },
        { left = 'b' },
        {},
        {},
        { mid = 'c' },
    })
    eq(result.cells[6], { mid = { first = 0, last = 20 } })
    eq(spans(result.lines[5], 'IterDrawerTitle'), { { 0, 8 } })
end

T['split()'] = function()
    local result = layout.split({
        column('left', 'Left', { 'a', 'b', 'c' }),
        column('right', 'Right', { 'x' }),
    }, 21)

    eq(
        vim.tbl_map(function(line)
            return line.text
        end, result.left.lines),
        { ' Left (3) │', 'a         │', 'b         │', 'c         │' }
    )
    eq(
        vim.tbl_map(function(line)
            return line.text
        end, result.right.lines),
        { ' Right (1)', 'x         ', '          ', '          ' }
    )
    eq(result.col, 11)
    eq(result.left.rows[2], { left = 'a' })
    eq(result.right.rows[2], { right = 'x' })
    eq(result.right.cells[2], { right = { first = 0, last = 10 } })
    eq(spans(result.left.lines[2], 'WinSeparator'), { { 10, 13 } })
end

T['stacked()'] = new_set()

T['stacked()']['a stack stacks its sections with the other columns'] = function()
    local result = layout.stacked({
        {
            sections = {
                column('left', 'Left', { 'a' }),
                column('mid', 'Mid', {}),
            },
        },
        column('right', 'Right', { 'x' }),
    }, 10)

    eq(
        vim.tbl_map(function(line)
            return line.text
        end, result.lines),
        {
            ' Left (1) ',
            'a         ',
            '',
            ' Mid (0)  ',
            '',
            ' Right (1)',
            'x         ',
        }
    )
    eq(result.rows[7], { right = 'x' })
end

T['stacked()']['columns one below the other'] = function()
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

T['commit_chunks()'] = new_set()

---@param author string
---@param body string
---@return GitCommit
local function picker_commit(author, body)
    return {
        sha = 'a1b2c3d',
        full_sha = string.rep('a', 40),
        subject = 'fix the thing',
        body = body,
        author = author,
        time = 1767225600,
        unpushed = false,
    }
end

T['commit_chunks()']['sha, date, padded author, subject, dimmed body'] = function()
    local chunks = layout.commit_chunks(picker_commit('Nik', 'why it broke'), 5)

    eq(chunks, {
        { 'a1b2c3d', 'IterCommitSha' },
        { '  ' },
        { os.date('%Y-%m-%d %H:%M', 1767225600), 'IterCommitDate' },
        { '  ' },
        { 'Nik  ', 'IterCommitAuthor' },
        { '  fix the thing' },
        { '  why it broke', 'IterCommitBody' },
    })
end

T['commit_chunks()']['no body chunk without a body'] = function()
    local chunks = layout.commit_chunks(picker_commit('Nik', ''), 3)

    eq(#chunks, 6)
    eq(chunks[6], { '  fix the thing' })
end

T['commit_chunks()']['author_width() takes the widest author up to 20'] = function()
    eq(
        layout.author_width({
            picker_commit('Nik', ''),
            picker_commit('Someone Longer', ''),
        }),
        14
    )
    eq(layout.author_width({ picker_commit(string.rep('x', 30), '') }), 20)
end

T['commit_summary()'] = new_set()

T['commit_summary()']['messages, then the files with their counts'] = function()
    local lines = layout.commit_summary({
        {
            sha = 'a1b2c3d',
            time = 1767225600,
            author = 'Nik',
            message = { 'fix the thing', '', 'why it broke' },
        },
    }, {
        { path = 'a.lua', added = 12, deleted = 3 },
        { path = 'new.lua', orig_path = 'old.lua', added = 0, deleted = 0 },
        { path = 'logo.png' },
    })
    local date = os.date('%Y-%m-%d %H:%M', 1767225600)

    eq(render.text_lines(lines), {
        ' a1b2c3d  ' .. date .. '  Nik',
        '',
        ' fix the thing',
        '',
        ' why it broke',
        '',
        ' 3 files  +12 −3',
        ' +12 −3  a.lua',
        '  +0 −0  old.lua → new.lua',
        '   bin   logo.png',
    })

    local groups = vim.tbl_map(function(h)
        return h.group
    end, lines[1].highlights)

    eq(groups, { 'IterCommitSha', 'IterCommitDate', 'IterCommitAuthor' })
    eq(lines[3].highlights[1].group, 'IterDrawerTitle')
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

    local behind = layout.commits(recent('origin/main', 1, 2), 40, NOW)
    eq(spans(behind.lines[1], 'IterBehind'), { { 36, 47 } })

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

---@param width integer
---@param line? IterRenderLine
---@return string
local function rename_cell(width, line)
    local item = change('diff/parser.lua', 'staged', 'R')
    item.orig_path = 'ui/diff/parser.lua'

    return layout.file_cell(
        line or { text = '', highlights = {} },
        item,
        0,
        width
    )
end

T['file_cell()']['a rename reads old → new with a dimmed arrow'] = function()
    local line = { text = '', highlights = {} }

    eq(rename_cell(40, line), ' R ui/diff/parser.lua → diff/parser.lua ')
    eq(spans(line, 'IterDrawerHint'), { { 21, 21 + #' → ' } })
end

T['file_cell()']['a rename cuts the old path first, then drops it'] = function()
    eq(rename_cell(30), ' R …rser.lua → diff/parser.lua')
    eq(rename_cell(23), ' R …a → diff/parser.lua')
    eq(rename_cell(22), ' R diff/parser.lua    ')
    eq(rename_cell(20), ' R diff/parser.lua  ')
    eq(rename_cell(12), ' R …rser.lua')
end

T['file_cell()']['a decor adds the mark slot and the count'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.file_cell(
        line,
        change('a.txt'),
        0,
        16,
        { mark = { '✓', 'IterReviewed' }, count = 2 }
    )

    eq(text, ' M ✓ a.txt  [2] ')
    eq(vim.fn.strdisplaywidth(text), 16)
    eq(spans(line, 'IterReviewed'), { { 3, 6 } })
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
        layout.annotation_label(
            annotation('line', vim.tbl_extend('force', old, { base = 'HEAD' }))
        ),
        'a.lua:8 old'
    )
    eq(
        layout.annotation_label(
            annotation(
                'line',
                vim.tbl_extend('force', old, { base = string.rep('ab', 20) })
            )
        ),
        'a.lua:8 old abababa'
    )
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
        { reviewed = 3, changed = 1, total = 8 },
        0,
        32
    )

    eq(text, ' reviewed ▰▰▰▱▱▱▱▱ 3 of 8 · ↻ 1 ')
    eq(spans(line, 'IterReviewed'), { { 10, 19 } })
    eq(
        spans(line, 'IterReviewedChanged'),
        { { #' reviewed ▰▰▰▱▱▱▱▱ 3 of 8', #text - 1 } }
    )
end

T['progress_cell()']['fills by share, full only when all are reviewed'] = function()
    local function bar(reviewed, total)
        local text = layout.progress_cell(
            { text = '', highlights = {} },
            { reviewed = reviewed, changed = 0, total = total },
            0,
            40
        )

        return vim.trim(text):match('[▰▱]+')
    end

    eq(
        bar(0, 0),
        '▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱'
    )
    eq(
        bar(0, 5),
        '▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱'
    )
    eq(
        bar(1, 20),
        '▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱'
    )
    eq(
        bar(19, 20),
        '▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▱'
    )
    eq(
        bar(4, 4),
        '▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰'
    )
end

T['progress_cell()']['drops the word when narrow'] = function()
    local text = layout.progress_cell(
        { text = '', highlights = {} },
        { reviewed = 1, changed = 1, total = 4 },
        0,
        24
    )

    eq(text, ' ▰▰▱▱▱▱▱▱▱ 1 of 4 · ↻ 1 ')
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
