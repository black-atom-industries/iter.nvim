local document = require('iter.diff.document')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

--- A file diff stub on `side` with a header and `count` context rows.
---@param path string
---@param side IterSide
---@param count integer
---@return IterFileDiff
local function file(path, side, count)
    local rows = { { kind = 'header', text = path } }

    for i = 1, count do
        table.insert(
            rows,
            { kind = 'context', text = path .. i, old = i, new = i }
        )
    end

    return {
        path = path,
        side = side,
        code = 'M',
        raw = {},
        hunks = {},
        rows = rows,
        binary = false,
        stat = { add = 0, del = 0 },
    }
end

--- `a.txt` (2 rows after its header), `b.txt` (1) and `a.txt` staged (3).
---@return IterDocument
local function three()
    return document.build({
        { file = file('a.txt', 'unstaged', 2) },
        { file = file('b.txt', 'unstaged', 1), new_follows = true },
        { file = file('a.txt', 'staged', 3) },
    })
end

local T = new_set()

T['build()'] = new_set()

T['build()']['one file takes one line per row and no separator'] = function()
    local doc = document.build({ { file = file('a.txt', 'unstaged', 2) } })

    eq(#doc.rows, 3)
    eq(doc.rows[1].kind, 'header')
    eq(doc.sections[1].first, 1)
    eq(doc.sections[1].last, 3)
    eq(doc.sections[1].key, 'unstaged\0a.txt')
end

T['build()']['puts one blank line between files'] = function()
    local doc = three()

    eq(
        vim.tbl_map(function(row)
            return row.text
        end, doc.rows),
        {
            'a.txt',
            'a.txt1',
            'a.txt2',
            '',
            'b.txt',
            'b.txt1',
            '',
            'a.txt',
            'a.txt1',
            'a.txt2',
            'a.txt3',
        }
    )
    eq(doc.rows[4].kind, 'blank')
    eq(
        vim.tbl_map(function(section)
            return { section.first, section.last }
        end, doc.sections),
        { { 1, 3 }, { 5, 6 }, { 8, 11 } }
    )
    eq(doc.sections[2].new_follows, true)
end

T['build()']['the rows are the model rows themselves'] = function()
    local a = file('a.txt', 'unstaged', 2)
    local doc = document.build({
        { file = a },
        { file = file('b.txt', 'unstaged', 1) },
    })

    eq(rawequal(doc.rows[2], a.rows[2]), true)
    eq(rawequal(doc.sections[1].file, a), true)
end

T['build()']['no entries give an empty document'] = function()
    local doc = document.build({})

    eq(doc.sections, {})
    eq(doc.rows, {})
    eq(doc.lines, {})
end

T['at()'] = new_set()

T['at()']['maps a line to its section and model row'] = function()
    local doc = three()
    local section, row, index = document.at(doc, 9)

    eq(section and section.key, 'staged\0a.txt')
    eq(row, 2)
    eq(index, 3)

    section, row, index = document.at(doc, 5)
    eq({ section and section.file.path, row, index }, { 'b.txt', 1, 2 })
end

T['at()']['a separator belongs to the file above it, without a row'] = function()
    local section, row, index = document.at(three(), 7)

    eq(section and section.file.path, 'b.txt')
    eq(row, nil)
    eq(index, 2)
end

T['at()']['a line outside the document maps to nothing'] = function()
    eq({ document.at(three(), 12) }, {})
    eq({ document.at(three(), 0) }, {})
end

T['line_of()'] = new_set()

T['line_of()']['is the inverse of at()'] = function()
    local doc = three()

    for lnum, line in ipairs(doc.lines) do
        if line.row ~= nil then
            eq(document.line_of(doc, line.section, line.row), lnum)
        end
    end
end

T['line_of()']['a row outside its section has no line'] = function()
    local doc = three()

    eq(document.line_of(doc, 2, 3), nil)
    eq(document.line_of(doc, 2, 0), nil)
    eq(document.line_of(doc, 4, 1), nil)
end

T['find()'] = new_set()

T['find()']['tells the sides of one path apart'] = function()
    local doc = three()

    eq(document.find(doc, 'unstaged\0a.txt'), 1)
    eq(document.find(doc, 'staged\0a.txt'), 3)
    eq(
        document.find(doc, document.key({ side = 'staged', path = 'b.txt' })),
        nil
    )
end

T['sections_in()'] = new_set()

T['sections_in()']['lists the sections a line range touches'] = function()
    local doc = three()

    eq(document.sections_in(doc, 1, 11), { 1, 2, 3 })
    eq(document.sections_in(doc, 2, 3), { 1 })
    eq(document.sections_in(doc, 4, 4), { 1 })
    eq(document.sections_in(doc, 6, 8), { 2, 3 })
    eq(document.sections_in(doc, 12, 20), {})
end

--- A file diff stub with one hunk: a context line, `dels` deleted and
--- `adds` added lines, a context line.
---@param dels string[]
---@param adds string[]
---@return IterFileDiff
local function changed(dels, adds)
    local rows = {
        { kind = 'header', text = 'c.txt' },
        { kind = 'hunk', text = '@@', hunk = 1 },
        { kind = 'context', text = 'top', old = 1, new = 1, hunk = 1 },
    }

    for i, text in ipairs(dels) do
        table.insert(rows, { kind = 'del', text = text, old = i + 1, hunk = 1 })
    end

    for i, text in ipairs(adds) do
        table.insert(rows, { kind = 'add', text = text, new = i + 1, hunk = 1 })
    end

    table.insert(rows, {
        kind = 'context',
        text = 'bottom',
        old = #dels + 2,
        new = #adds + 2,
        hunk = 1,
    })

    return {
        path = 'c.txt',
        side = 'unstaged',
        code = 'M',
        raw = {},
        hunks = {},
        rows = rows,
        binary = false,
        stat = { add = #adds, del = #dels },
    }
end

--- Both sides of `doc` as `old | new` texts, `~` for a filler row.
---@param doc IterDocument
---@return string[]
local function sides(doc)
    local result = {}

    for lnum, row in ipairs(doc.rows) do
        local old = doc.old_rows[lnum]

        table.insert(
            result,
            (old.kind == 'filler' and '~' or old.text)
                .. ' | '
                .. (row.kind == 'filler' and '~' or row.text)
        )
    end

    return result
end

T['split_lines()'] = new_set()

T['split_lines()']['puts paired rows on one line, an unpaired one beside a filler'] = function()
    local file = changed(
        { 'local a = 1', 'local b = 1' },
        { 'local a = 2', 'local b = 2', 'c = 4' }
    )

    eq(document.split_lines(file.rows), {
        { old = 1, new = 1 },
        { old = 2, new = 2 },
        { old = 3, new = 3 },
        { old = 4, new = 6 },
        { old = 5, new = 7 },
        { new = 8 },
        { old = 9, new = 9 },
    })
end

T['split_lines()']['an add paired after unpaired adds keeps row order'] = function()
    local file = changed({ 'local b = 2' }, { 'print("x")', 'local b = 3' })

    eq(document.split_lines(file.rows), {
        { old = 1, new = 1 },
        { old = 2, new = 2 },
        { old = 3, new = 3 },
        { new = 5 },
        { old = 4, new = 6 },
        { old = 7, new = 7 },
    })
end

T['build() split'] = new_set()

T['build() split']['aligns both sides with filler rows'] = function()
    local doc = document.build({
        { file = changed({ 'x = 1', 'y = 1', 'gone' }, { 'x = 2', 'y = 2' }) },
    }, 'split')

    eq(doc.layout, 'split')
    eq(#doc.old_rows, #doc.rows)
    eq(sides(doc), {
        'c.txt | c.txt',
        '@@ | @@',
        'top | top',
        'x = 1 | x = 2',
        'y = 1 | y = 2',
        'gone | ~',
        'bottom | bottom',
    })
end

T['build() split']['more adds than dels put fillers on the old side'] = function()
    local doc = document.build({
        { file = changed({ 'x = 1' }, { 'x = 2', 'z = 3', 'w = 4' }) },
    }, 'split')

    eq(sides(doc), {
        'c.txt | c.txt',
        '@@ | @@',
        'top | top',
        'x = 1 | x = 2',
        '~ | z = 3',
        '~ | w = 4',
        'bottom | bottom',
    })
end

T['build() split']['every model row lands on one line and maps back'] = function()
    local a = changed({ 'x = 1', 'gone' }, { 'x = 2' })
    local b = changed({}, { 'new' })
    local doc = document.build({ { file = a }, { file = b } }, 'split')

    eq(#doc.old_rows, #doc.rows)
    eq(doc.rows[7].kind, 'blank')
    eq(doc.old_rows[7].kind, 'blank')

    for index, section in ipairs(doc.sections) do
        for row, model_row in ipairs(section.file.rows) do
            local lnum = assert(document.line_of(doc, index, row))
            local side = model_row.kind == 'del' and 'old' or 'new'
            local _, at_row, at_index = document.at(doc, lnum, side)

            eq({ at_index, at_row }, { index, row })
        end
    end

    eq({ doc.sections[2].first, doc.sections[2].last }, { 8, 12 })
end

T['build() split']['at() on a filler gives the row of the other side'] = function()
    local doc = document.build({
        { file = changed({ 'x = 1', 'gone' }, { 'x = 2' }) },
    }, 'split')
    local _, old_row = document.at(doc, 5, 'old')
    local _, new_row = document.at(doc, 5, 'new')
    local _, row = document.at(doc, 4)

    eq(doc.rows[5].kind, 'filler')
    eq({ old_row, new_row, row }, { 5, 5, 6 })
end

T['build() split']['a deleted line with word emphasis faces its pair'] = function()
    local file = changed(
        { 'print("start")', 'local b = 2', 'local c = 5' },
        { 'local b = 3', 'return b', 'local c = 6' }
    )

    require('iter.diff.words').annotate(file.rows)

    local doc = document.build({ { file = file } }, 'split')
    local faced = 0

    for _, line in ipairs(doc.lines) do
        local del = line.old and file.rows[line.old]

        if del and del.kind == 'del' and del.pair ~= nil then
            eq(line.new, del.pair)
            faced = faced + 1
        end
    end

    eq(faced, 2)
end

T['rows_in()'] = new_set()

T['rows_in()']['takes the rows of each line, of one side when given'] = function()
    local doc = document.build({
        { file = changed({ 'x = 1', 'y = 1' }, { 'x = 2', 'y = 2' }) },
    }, 'split')

    -- Line 5 holds the second del and the second add: no first add.
    eq(document.rows_in(doc, 5, 5), { 5, 7 })
    eq(document.rows_in(doc, 4, 5, 'old'), { 4, 5 })
    eq(document.rows_in(doc, 4, 6, 'new'), { 6, 7, 8 })
    eq(document.rows_in(doc, 3, 3, 'old'), { 3 })
end

T['rows_in()']['takes the rows of each line in the unified layout'] = function()
    local doc = three()

    eq(document.rows_in(doc, 2, 3), { 2, 3 })
    eq(document.rows_in(doc, 3, 4), { 3 })
    eq(document.rows_in(doc, 4, 4), {})
end

T['collapsed'] = new_set()

--- `three()` with `b.txt` collapsed, in `layout`.
---@param layout? IterDocLayout
---@return IterDocument
local function collapsed_b(layout)
    return document.build({
        { file = file('a.txt', 'unstaged', 2) },
        { file = file('b.txt', 'unstaged', 1), collapsed = true },
        { file = file('a.txt', 'staged', 3) },
    }, layout)
end

T['collapsed']['a collapsed section takes its header row alone'] = function()
    local doc = collapsed_b()

    eq(
        vim.tbl_map(function(row)
            return row.text
        end, doc.rows),
        {
            'a.txt',
            'a.txt1',
            'a.txt2',
            '',
            'b.txt',
            '',
            'a.txt',
            'a.txt1',
            'a.txt2',
            'a.txt3',
        }
    )
    eq(doc.sections[2].collapsed, true)
    eq({ doc.sections[2].first, doc.sections[2].last }, { 5, 5 })
    eq({ doc.sections[3].first, doc.sections[3].last }, { 7, 10 })
    eq(doc.sections[1].collapsed, nil)
end

T['collapsed']['at() and line_of() map the header only'] = function()
    local doc = collapsed_b()
    local section, row, index = document.at(doc, 5)

    eq({ section.key, row, index }, { 'unstaged\0b.txt', 1, 2 })
    eq(document.line_of(doc, 2, 1), 5)
    eq(document.line_of(doc, 2, 2), nil)
    eq(document.line_of(doc, 3, 2), 8)

    local _, _, sep = document.at(doc, 6)
    eq(sep, 2)
    eq(document.sections_in(doc, 5, 6), { 2 })
end

T['collapsed']['the split layout shows the header on both sides'] = function()
    local doc = collapsed_b('split')

    eq(#doc.old_rows, #doc.rows)
    eq(doc.rows[5].kind, 'header')
    eq(doc.old_rows[5].kind, 'header')
    eq(doc.lines[5], { section = 2, row = 1, old = 1, new = 1 })
    eq(document.line_of(doc, 2, 2), nil)
    eq(document.rows_in(doc, 5, 5), { 1 })
    eq(doc.sections[3].first, 7)
end

T['collapsed']['a document built from sections keeps them collapsed'] = function()
    local doc = collapsed_b()
    local split = document.build(doc.sections, 'split')
    local back = document.build(split.sections)

    eq(split.sections[2].collapsed, true)
    eq(#split.rows, 10)
    eq(back.sections[2].collapsed, true)
    eq(#back.rows, 10)
end

return T
